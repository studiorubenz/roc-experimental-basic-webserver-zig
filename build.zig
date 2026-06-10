const std = @import("std");
const builtin = @import("builtin");

/// Roc target definitions
const RocTarget = enum {
    x64mac,
    x64musl,
    x64glibc,
    arm64mac,
    arm64musl,

    fn toZigTarget(self: RocTarget) std.Target.Query {
        return switch (self) {
            .x64mac => .{ .cpu_arch = .x86_64, .os_tag = .macos },
            .x64musl => .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
            .x64glibc => .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
            .arm64mac => .{ .cpu_arch = .aarch64, .os_tag = .macos },
            .arm64musl => .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
        };
    }

    fn targetDir(self: RocTarget) []const u8 {
        return switch (self) {
            .x64mac => "x64mac",
            .x64musl => "x64musl",
            .x64glibc => "x64glibc",
            .arm64mac => "arm64mac",
            .arm64musl => "arm64musl",
        };
    }

    fn libFilename(self: RocTarget) []const u8 {
        _ = self;
        return "libhost.a";
    }
};

/// All cross-compilation targets
const all_targets = [_]RocTarget{
    .x64mac,
    .x64musl,
    .x64glibc,
    .arm64mac,
    .arm64musl,
};

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // Construct the roc builtins module directly from the pinned worktree
    // instead of via b.dependency: roc's build.zig reads files relative to
    // the cwd and panics when executed as a dependency. The module graph is
    // tiny anyway: builtins <- tracy <- build_options (tracy disabled).
    const roc_path = "../roc-48b28c07";

    const tracy_options = b.addOptions();
    tracy_options.addOption(bool, "enable_tracy", false);
    tracy_options.addOption(bool, "enable_tracy_callstack", false);
    tracy_options.addOption(bool, "enable_tracy_allocation", false);
    tracy_options.addOption(u32, "tracy_callstack_depth", 0);

    const tracy_module = b.createModule(.{
        .root_source_file = .{ .cwd_relative = roc_path ++ "/src/build/tracy.zig" },
    });
    tracy_module.addOptions("build_options", tracy_options);

    const builtins_module = b.createModule(.{
        .root_source_file = .{ .cwd_relative = roc_path ++ "/src/builtins/mod.zig" },
    });
    builtins_module.addImport("tracy", tracy_module);

    // Cleanup step
    const cleanup_step = b.step("clean", "Remove all built library files");
    for (all_targets) |roc_target| {
        cleanup_step.dependOn(&CleanupStep.create(b, b.path(
            b.pathJoin(&.{ "platform", "targets", roc_target.targetDir(), roc_target.libFilename() }),
        )).step);
    }
    cleanup_step.dependOn(&CleanupStep.create(b, b.path("platform/libhost.a")).step);

    // Default step: build for all targets
    const all_step = b.getInstallStep();
    all_step.dependOn(cleanup_step);

    const copy_all = b.addUpdateSourceFiles();
    all_step.dependOn(&copy_all.step);

    // Build for each Roc target
    for (all_targets) |roc_target| {
        const target_step_name = @tagName(roc_target);
        const target_step = b.step(target_step_name, b.fmt("Build host library for {s} target only", .{target_step_name}));
        target_step.dependOn(cleanup_step);

        const target = b.resolveTargetQuery(roc_target.toZigTarget());
        const host_lib = buildHostLib(b, target, optimize, builtins_module);

        const copy_target = b.addUpdateSourceFiles();
        copy_target.addCopyFileToSource(
            host_lib.getEmittedBin(),
            b.pathJoin(&.{ "platform", "targets", roc_target.targetDir(), roc_target.libFilename() }),
        );
        target_step.dependOn(&copy_target.step);

        copy_all.addCopyFileToSource(
            host_lib.getEmittedBin(),
            b.pathJoin(&.{ "platform", "targets", roc_target.targetDir(), roc_target.libFilename() }),
        );
    }

    // Native step: build only for the current platform
    const native_step = b.step("native", "Build host library for native platform only");
    native_step.dependOn(cleanup_step);

    const native_target = b.standardTargetOptions(.{});

    const native_roc_target = detectNativeRocTarget(native_target.result) orelse {
        std.debug.print("Unsupported native platform\n", .{});
        return;
    };

    const native_lib = buildHostLib(b, native_target, optimize, builtins_module);
    b.installArtifact(native_lib);

    const copy_native = b.addUpdateSourceFiles();
    copy_native.addCopyFileToSource(
        native_lib.getEmittedBin(),
        b.pathJoin(&.{ "platform", "targets", native_roc_target.targetDir(), native_roc_target.libFilename() }),
    );
    native_step.dependOn(&copy_native.step);
    native_step.dependOn(&native_lib.step);

    // Test step
    const test_step = b.step("test", "Run all tests");

    const host_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("platform/host.zig"),
            .target = native_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "builtins", .module = builtins_module },
            },
            .link_libc = native_target.result.os.tag != .windows and native_target.result.os.tag != .wasi,
        }),
    });

    const run_host_tests = b.addRunArtifact(host_tests);
    test_step.dependOn(&run_host_tests.step);
}

fn detectNativeRocTarget(target: std.Target) ?RocTarget {
    return switch (target.os.tag) {
        .macos => switch (target.cpu.arch) {
            .x86_64 => .x64mac,
            .aarch64 => .arm64mac,
            else => null,
        },
        .linux => switch (target.cpu.arch) {
            .x86_64 => .x64glibc,
            .aarch64 => .arm64musl,
            else => null,
        },
        else => null,
    };
}

const CleanupStep = struct {
    step: std.Build.Step,
    path: std.Build.LazyPath,

    fn create(b: *std.Build, path: std.Build.LazyPath) *CleanupStep {
        const self = b.allocator.create(CleanupStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "cleanup",
                .owner = b,
                .makeFn = make,
            }),
            .path = path,
        };
        return self;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
        _ = options;
        const self: *CleanupStep = @fieldParentPtr("step", step);
        const path = self.path.getPath2(step.owner, null);
        std.Io.Dir.cwd().deleteFile(step.owner.graph.io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
};

fn buildHostLib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    builtins_module: *std.Build.Module,
) *std.Build.Step.Compile {
    const host_lib = b.addLibrary(.{
        .name = "host",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("platform/host.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .Debug,
            .pic = true,
            .imports = &.{
                .{ .name = "builtins", .module = builtins_module },
            },
            .link_libc = target.result.os.tag != .windows and target.result.os.tag != .wasi,
        }),
    });
    host_lib.bundle_compiler_rt = true;

    return host_lib;
}
