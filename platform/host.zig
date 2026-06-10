//! HTTP server host for the experimental basic-webserver platform.
//!
//! Handler-inversion architecture: the host owns the TCP listener and the
//! accept loop. For every incoming request it parses method/path/body,
//! builds a Roc record, and calls the app's exported handler
//! (`roc__handle : Request => Response`), then writes the response.
//!
//! Concurrency model: a pool of worker threads handles connections in
//! parallel, and calls into compiled Roc code run in parallel too — the
//! built artifact has no shared mutable interpreter state and refcounts
//! are atomic (verified: 500-request parallel battery incl. File/Dir/Cmd
//! effects, 0 leaks, WS suites green). Handlers are therefore genuinely
//! concurrent: apps must not assume two requests can't interleave (e.g.
//! file read-modify-write is racy; prefer unique paths per request).
//!
//! Zig 0.16 port note: sockets and console output use libc (std.c) and raw
//! fds directly — std.net was replaced by the std.Io overhaul in 0.16, and
//! the explicit Io-instance plumbing buys a simple blocking host nothing.
const std = @import("std");
const builtins = @import("builtins");

const RocStr = builtins.str.RocStr;
const RocList = builtins.list.RocList;
const RocOps = builtins.host_abi.RocOps;

const c_allocator = std.heap.c_allocator;
const Fd = std.posix.fd_t;

const DEFAULT_PORT: u16 = 8000;
const QUEUE_CAP: usize = 64;
const MAX_WORKERS: usize = 16;
const SOCKET_TIMEOUT_SECONDS: i64 = 10;
const MAX_HEADER_BYTES: usize = 16 * 1024;
const MAX_BODY_BYTES: usize = 1024 * 1024;
const MAX_HEADERS: usize = 64;

fn lockMutex(mutex: *std.c.pthread_mutex_t) void {
    _ = std.c.pthread_mutex_lock(mutex);
}

fn unlockMutex(mutex: *std.c.pthread_mutex_t) void {
    _ = std.c.pthread_mutex_unlock(mutex);
}

/// Set by the SIGINT/SIGTERM handler; checked by the polling acceptor loop
/// and by the keep-alive loop in workers.
var shutting_down = std.atomic.Value(bool).init(false);

// libc getenv: std.posix.getenv relies on std.os.environ, which is not
// populated when the host exports its own C main.
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;

/// Write all bytes to a raw fd, best effort (used for console and sockets).
fn writeAllFd(fd: Fd, bytes: []const u8) void {
    var index: usize = 0;
    while (index < bytes.len) {
        const written = std.c.write(fd, bytes.ptr + index, bytes.len - index);
        if (written <= 0) return;
        index += @intCast(written);
    }
}

fn printStdout(bytes: []const u8) void {
    writeAllFd(1, bytes);
}

fn printStderr(bytes: []const u8) void {
    writeAllFd(2, bytes);
}

/// One header entry: Roc record { name : Str, value : Str } — two RocStr,
/// sorted alphabetically (name, value).
const RocHeader = extern struct {
    name: RocStr,
    value: RocStr,
};

/// Request record passed to the Roc handler:
/// { body : List(U8), headers : List({ name : Str, value : Str }), method : Str, uri : Str }.
/// Roc record layout: fields sorted by alignment descending, then name
/// alphabetically (see roc test/int/platform/main.roc). RocStr and RocList
/// are both 24 bytes / align 8, so the order is purely alphabetical.
const RocRequest = extern struct {
    body: RocList,
    headers: RocList,
    method: RocStr,
    uri: RocStr,
};

/// Response record returned by the Roc handler:
/// { body : List(U8), headers : List({ name : Str, value : Str }), status : U16 }.
const RocResponse = extern struct {
    body: RocList,
    headers: RocList,
    status: u16,
};

// ============================================================================
// RocOps callbacks
// ============================================================================

// Allocations carry a size header so that realloc knows how many bytes to
// copy out of the old block (the Roc runtime does not pass the old length).
// Layout: [header (max(alignment, usize))] [user data ...]
//                          ^ total size stored in the last usize of the header

fn headerSize(alignment: usize) usize {
    return @max(alignment, @alignOf(usize));
}

fn rocAllocFn(roc_alloc: *builtins.host_abi.RocAlloc, env: *anyopaque) callconv(.c) void {
    _ = env;
    const align_enum = std.mem.Alignment.fromByteUnits(@max(roc_alloc.alignment, @alignOf(usize)));
    const header = headerSize(roc_alloc.alignment);
    const total_size = roc_alloc.length + header;

    const base_ptr = c_allocator.rawAlloc(total_size, align_enum, @returnAddress()) orelse {
        printStderr("Host error: allocation failed, out of memory\n");
        std.process.exit(1);
    };

    const size_ptr: *usize = @ptrFromInt(@intFromPtr(base_ptr) + header - @sizeOf(usize));
    size_ptr.* = total_size;
    roc_alloc.answer = @ptrFromInt(@intFromPtr(base_ptr) + header);
}

fn rocDeallocFn(roc_dealloc: *builtins.host_abi.RocDealloc, env: *anyopaque) callconv(.c) void {
    _ = env;
    const align_enum = std.mem.Alignment.fromByteUnits(@max(roc_dealloc.alignment, @alignOf(usize)));
    const header = headerSize(roc_dealloc.alignment);
    const size_ptr: *const usize = @ptrFromInt(@intFromPtr(roc_dealloc.ptr) - @sizeOf(usize));
    const total_size = size_ptr.*;
    const base_ptr: [*]u8 = @ptrFromInt(@intFromPtr(roc_dealloc.ptr) - header);
    c_allocator.rawFree(base_ptr[0..total_size], align_enum, @returnAddress());
}

fn rocReallocFn(roc_realloc: *builtins.host_abi.RocRealloc, env: *anyopaque) callconv(.c) void {
    _ = env;
    const align_enum = std.mem.Alignment.fromByteUnits(@max(roc_realloc.alignment, @alignOf(usize)));
    const header = headerSize(roc_realloc.alignment);

    const old_size_ptr: *const usize = @ptrFromInt(@intFromPtr(roc_realloc.answer) - @sizeOf(usize));
    const old_total_size = old_size_ptr.*;
    const old_base_ptr: [*]u8 = @ptrFromInt(@intFromPtr(roc_realloc.answer) - header);

    const new_total_size = roc_realloc.new_length + header;
    const new_base_ptr = c_allocator.rawAlloc(new_total_size, align_enum, @returnAddress()) orelse {
        printStderr("Host error: reallocation failed, out of memory\n");
        std.process.exit(1);
    };

    // Copy the user data only (the header is rewritten below); matches
    // lukewilliamboswell/roc-platform-template-zig.
    const old_user_size = old_total_size - header;
    const copy_size = @min(old_user_size, roc_realloc.new_length);
    const new_user_ptr: [*]u8 = @ptrFromInt(@intFromPtr(new_base_ptr) + header);
    const old_user_ptr: [*]const u8 = @ptrCast(roc_realloc.answer);
    @memcpy(new_user_ptr[0..copy_size], old_user_ptr[0..copy_size]);
    c_allocator.rawFree(old_base_ptr[0..old_total_size], align_enum, @returnAddress());

    const new_size_ptr: *usize = @ptrFromInt(@intFromPtr(new_base_ptr) + header - @sizeOf(usize));
    new_size_ptr.* = new_total_size;
    roc_realloc.answer = @ptrFromInt(@intFromPtr(new_base_ptr) + header);
}

fn rocDbgFn(roc_dbg: *const builtins.host_abi.RocDbg, env: *anyopaque) callconv(.c) void {
    _ = env;
    printStderr("dbg: ");
    printStderr(roc_dbg.utf8_bytes[0..roc_dbg.len]);
    printStderr("\n");
}

fn rocExpectFailedFn(roc_expect: *const builtins.host_abi.RocExpectFailed, env: *anyopaque) callconv(.c) void {
    _ = env;
    const source_bytes = roc_expect.utf8_bytes[0..roc_expect.len];
    const trimmed = std.mem.trim(u8, source_bytes, " \t\n\r");
    printStderr("expect failed: ");
    printStderr(trimmed);
    printStderr("\n");
}

fn rocCrashedFn(roc_crashed: *const builtins.host_abi.RocCrashed, env: *anyopaque) callconv(.c) noreturn {
    _ = env;
    printStderr("\nRoc crashed: ");
    printStderr(roc_crashed.utf8_bytes[0..roc_crashed.len]);
    printStderr("\n");
    std.process.exit(1);
}

// ============================================================================
// Hosted functions
// ============================================================================

// Per the host ABI at 48b28c07: Roc transfers ownership of refcounted
// arguments to hosted functions, which must decref them when done.

// --- Env / Utc / Sleep / Random (Phase 1; APIs vendored from basic-cli) ----
//
// Tag-union return layouts verified by the Phase 0 probe (see IO-PORT-PLAN.md):
// Try payload at offset 0, discriminant byte AFTER the max payload, tags
// alphabetical (Err=0, Ok=1); single-tag wrappers like [VarNotFound(Str)]
// are transparent.

extern "c" fn getcwd(buf: [*]u8, size: usize) ?[*:0]u8;
extern "c" fn _NSGetExecutablePath(buf: [*]u8, bufsize: *u32) c_int;
extern "c" fn arc4random_buf(buf: *anyopaque, nbytes: usize) void;

/// Env.cwd! : {} => Try(Str, [CwdUnavailable])
/// 32 bytes: payload Str@0, disc u8@24 (Err=0, Ok=1).
fn hostedEnvCwd(ops: *RocOps, ret_ptr: *anyopaque, _: *anyopaque) callconv(.c) void {
    const out: [*]u8 = @ptrCast(ret_ptr);
    @memset(out[0..32], 0);
    var buf: [4096]u8 = undefined;
    if (getcwd(&buf, buf.len)) |path| {
        const str_ptr: *align(1) RocStr = @ptrCast(out);
        str_ptr.* = RocStr.fromSlice(std.mem.span(path), ops);
        out[24] = 1; // Ok
    } // else: zeroed payload + disc 0 = Err(CwdUnavailable)
}

/// Env.exe_path! : {} => Try(Str, [ExePathUnavailable])
/// Same 32-byte shape as cwd!.
fn hostedEnvExePath(ops: *RocOps, ret_ptr: *anyopaque, _: *anyopaque) callconv(.c) void {
    const out: [*]u8 = @ptrCast(ret_ptr);
    @memset(out[0..32], 0);
    var buf: [4096]u8 = undefined;
    var size: u32 = buf.len;
    if (_NSGetExecutablePath(&buf, &size) == 0) {
        const str_ptr: *align(1) RocStr = @ptrCast(out);
        str_ptr.* = RocStr.fromSlice(std.mem.span(@as([*:0]u8, @ptrCast(&buf))), ops);
        out[24] = 1; // Ok
    }
}

/// Env.var! : Str => Try(Str, [VarNotFound(Str)])
/// 32 bytes: payload Str@0 (value on Ok, the queried name on Err), disc u8@24.
fn hostedEnvVar(ops: *RocOps, ret_ptr: *anyopaque, args: *const extern struct { name: RocStr }) callconv(.c) void {
    const out: [*]u8 = @ptrCast(ret_ptr);
    @memset(out[0..32], 0);
    const str_ptr: *align(1) RocStr = @ptrCast(out);

    const name = args.name.asSlice();
    var name_z: [1024]u8 = undefined;
    if (name.len < name_z.len) {
        @memcpy(name_z[0..name.len], name);
        name_z[name.len] = 0;
        if (getenv(@ptrCast(&name_z))) |value| {
            str_ptr.* = RocStr.fromSlice(std.mem.span(value), ops);
            out[24] = 1; // Ok
            args.name.decref(ops);
            return;
        }
    }
    // Err(VarNotFound(name)): the argument string moves into the error
    // payload, transferring ownership — no decref.
    str_ptr.* = args.name;
    out[24] = 0; // Err
}

// --- Cmd (Phase 3) ----------------------------------------------------------

/// The Cmd record crossing the boundary:
/// { args : List(Str), clear_envs : Bool, envs : List(Str), program : Str }
/// (align-8 fields alphabetical, then the Bool).
const RocCmd = extern struct {
    args: RocList,
    envs: RocList,
    program: RocStr,
    clear_envs: u8,
};

/// Element destructor for lists of RocStr.
fn decStrElement(context: ?*anyopaque, element: ?[*]u8) callconv(.c) void {
    const ops: *RocOps = @ptrCast(@alignCast(context.?));
    const str: *RocStr = @ptrCast(@alignCast(element.?));
    str.decref(ops);
}

fn decrefCmd(cmd: *const RocCmd, ops: *RocOps) void {
    cmd.program.decref(ops);
    const ctx = @as(*anyopaque, @ptrCast(ops));
    cmd.args.decref(@alignOf(RocStr), @sizeOf(RocStr), true, ctx, decStrElement, ops);
    cmd.envs.decref(@alignOf(RocStr), @sizeOf(RocStr), true, ctx, decStrElement, ops);
}

fn listStrItems(list: RocList) []const RocStr {
    const ptr = list.bytes orelse return &.{};
    const elems: [*]const RocStr = @ptrCast(@alignCast(ptr));
    return elems[0..list.len()];
}

const NullStrArray = [*:null]const ?[*:0]const u8;

/// argv = [program, args..., null], all NUL-terminated arena copies.
fn buildArgv(arena: std.mem.Allocator, cmd: *const RocCmd) !NullStrArray {
    const args = listStrItems(cmd.args);
    const argv = try arena.allocSentinel(?[*:0]const u8, args.len + 1, null);
    argv[0] = try arena.dupeZ(u8, cmd.program.asSlice());
    for (args, 0..) |arg, i| argv[i + 1] = try arena.dupeZ(u8, arg.asSlice());
    return argv;
}

/// envp: the parent environment (unless clear_envs) plus "key=value" pairs
/// from the flattened envs list [k1, v1, k2, v2, ...].
fn buildEnvp(arena: std.mem.Allocator, cmd: *const RocCmd) !NullStrArray {
    const flat = listStrItems(cmd.envs);
    var inherited: usize = 0;
    if (cmd.clear_envs == 0) {
        while (std.c.environ[inherited] != null) inherited += 1;
    }
    const envp = try arena.allocSentinel(?[*:0]const u8, inherited + flat.len / 2, null);
    for (0..inherited) |i| envp[i] = std.c.environ[i];
    var slot = inherited;
    var i: usize = 0;
    while (i + 1 < flat.len) : (i += 2) {
        envp[slot] = try std.fmt.allocPrintSentinel(arena, "{s}={s}", .{ flat[i].asSlice(), flat[i + 1].asSlice() }, 0);
        slot += 1;
    }
    return envp;
}

/// Wait for a child; returns its exit code, or the IOErr already written.
const WaitResult = union(enum) { exited: i32, signaled: i32, err: c_int };

fn waitForChild(pid: std.c.pid_t) WaitResult {
    var status: c_int = 0;
    while (true) {
        const rc = std.c.waitpid(pid, &status, 0);
        if (rc >= 0) break;
        if (std.c._errno().* != @intFromEnum(std.c.E.INTR)) return .{ .err = std.c._errno().* };
    }
    const ustatus: u32 = @bitCast(status);
    if (std.c.W.IFEXITED(ustatus)) return .{ .exited = @intCast(std.c.W.EXITSTATUS(ustatus)) };
    if (std.c.W.IFSIGNALED(ustatus)) return .{ .signaled = @intCast(@intFromEnum(std.c.W.TERMSIG(ustatus))) };
    return .{ .err = @intFromEnum(std.c.E.INVAL) };
}

/// Cmd.host_exec_exit_code! : Cmd => Try(I32, IOErr)
/// 40 bytes: payload@0 (I32 or IOErr), Try disc u8@32. The child inherits
/// stdin/stdout/stderr.
fn hostedCmdHostExecExitCode(ops: *RocOps, ret_ptr: *anyopaque, args: *const RocCmd) callconv(.c) void {
    defer decrefCmd(args, ops);
    const out: [*]u8 = @ptrCast(ret_ptr);
    @memset(out[0..40], 0);

    var arena_state = std.heap.ArenaAllocator.init(c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const argv = buildArgv(arena, args) catch return writeFileErr(out, @intFromEnum(std.c.E.NOMEM), ops);
    const envp = buildEnvp(arena, args) catch return writeFileErr(out, @intFromEnum(std.c.E.NOMEM), ops);

    var pid: std.c.pid_t = undefined;
    const rc = std.c.posix_spawnp(&pid, argv[0].?, null, null, @ptrCast(argv), @ptrCast(envp));
    if (rc != 0) return writeFileErr(out, rc, ops); // posix_spawn returns the errno

    switch (waitForChild(pid)) {
        .exited => |code| {
            const code_ptr: *align(1) i32 = @ptrCast(out);
            code_ptr.* = code;
            out[32] = 1; // Ok
        },
        .signaled => |sig| {
            var msg_buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "terminated by signal {d}", .{sig}) catch "terminated by signal";
            writeOtherPayload(out, msg, ops);
            out[32] = 0; // Err
        },
        .err => |errnum| writeFileErr(out, errnum, ops),
    }
}

/// Cmd.host_exec_output! : Cmd =>
///   Try({ stderr_bytes : List(U8), stdout_bytes : List(U8) },          -- 48B
///       Try({ stderr_bytes, stdout_bytes, exit_code : I32 }, IOErr))   -- 64B
/// Outer: payload@0 = max(48, inner 64) = 64, outer disc u8@64, total 72.
/// Inner: payload@0 = max(failure 56, IOErr 32) = 56, inner disc u8@56.
/// Failure record: stderr_bytes@0, stdout_bytes@24, exit_code i32@48.
fn hostedCmdHostExecOutput(ops: *RocOps, ret_ptr: *anyopaque, args: *const RocCmd) callconv(.c) void {
    defer decrefCmd(args, ops);
    const out: [*]u8 = @ptrCast(ret_ptr);
    @memset(out[0..72], 0);

    var arena_state = std.heap.ArenaAllocator.init(c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const spawn_err = struct {
        fn write(o: [*]u8, errnum: c_int, roc_ops: *RocOps) void {
            writeIOErrPayload(o, errnum, roc_ops);
            o[56] = 0; // inner Try: Err(IOErr)
            o[64] = 0; // outer Try: Err
        }
    }.write;
    const argv = buildArgv(arena, args) catch return spawn_err(out, @intFromEnum(std.c.E.NOMEM), ops);
    const envp = buildEnvp(arena, args) catch return spawn_err(out, @intFromEnum(std.c.E.NOMEM), ops);

    var stdout_pipe: [2]Fd = undefined;
    var stderr_pipe: [2]Fd = undefined;
    if (std.c.pipe(&stdout_pipe) != 0) return spawn_err(out, std.c._errno().*, ops);
    if (std.c.pipe(&stderr_pipe) != 0) {
        _ = std.c.close(stdout_pipe[0]);
        _ = std.c.close(stdout_pipe[1]);
        return spawn_err(out, std.c._errno().*, ops);
    }

    var actions: std.c.posix_spawn_file_actions_t = undefined;
    _ = std.c.posix_spawn_file_actions_init(&actions);
    defer _ = std.c.posix_spawn_file_actions_destroy(&actions);
    _ = std.c.posix_spawn_file_actions_adddup2(&actions, stdout_pipe[1], 1);
    _ = std.c.posix_spawn_file_actions_adddup2(&actions, stderr_pipe[1], 2);
    _ = std.c.posix_spawn_file_actions_addclose(&actions, stdout_pipe[0]);
    _ = std.c.posix_spawn_file_actions_addclose(&actions, stderr_pipe[0]);

    var pid: std.c.pid_t = undefined;
    const rc = std.c.posix_spawnp(&pid, argv[0].?, &actions, null, @ptrCast(argv), @ptrCast(envp));
    _ = std.c.close(stdout_pipe[1]);
    _ = std.c.close(stderr_pipe[1]);
    if (rc != 0) {
        _ = std.c.close(stdout_pipe[0]);
        _ = std.c.close(stderr_pipe[0]);
        return spawn_err(out, rc, ops);
    }

    // Drain both pipes until EOF (poll prevents a deadlock when the child
    // fills one pipe while we block on the other).
    var stdout_bytes: std.ArrayList(u8) = .empty;
    defer stdout_bytes.deinit(c_allocator);
    var stderr_bytes: std.ArrayList(u8) = .empty;
    defer stderr_bytes.deinit(c_allocator);
    var fds = [2]std.c.pollfd{
        .{ .fd = stdout_pipe[0], .events = std.c.POLL.IN, .revents = 0 },
        .{ .fd = stderr_pipe[0], .events = std.c.POLL.IN, .revents = 0 },
    };
    var bufs = [2]*std.ArrayList(u8){ &stdout_bytes, &stderr_bytes };
    var chunk: [16384]u8 = undefined;
    while (fds[0].fd >= 0 or fds[1].fd >= 0) {
        if (std.c.poll(&fds, 2, -1) < 0) {
            if (std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
            break;
        }
        for (&fds, 0..) |*pfd, i| {
            if (pfd.fd < 0 or pfd.revents == 0) continue;
            const n = std.c.read(pfd.fd, &chunk, chunk.len);
            if (n > 0) {
                bufs[i].appendSlice(c_allocator, chunk[0..@intCast(n)]) catch {};
            } else {
                _ = std.c.close(pfd.fd);
                pfd.fd = -1;
            }
        }
    }

    switch (waitForChild(pid)) {
        .exited => |code| if (code == 0) {
            // Ok(Success): stderr_bytes@0, stdout_bytes@24, outer disc 1.
            const stderr_ptr: *align(1) RocList = @ptrCast(out);
            stderr_ptr.* = RocList.fromSlice(u8, stderr_bytes.items, false, ops);
            const stdout_ptr: *align(1) RocList = @ptrCast(out + 24);
            stdout_ptr.* = RocList.fromSlice(u8, stdout_bytes.items, false, ops);
            out[64] = 1;
        } else {
            // Err(Ok(Failure)): lists + exit code, inner disc 1, outer 0.
            const stderr_ptr: *align(1) RocList = @ptrCast(out);
            stderr_ptr.* = RocList.fromSlice(u8, stderr_bytes.items, false, ops);
            const stdout_ptr: *align(1) RocList = @ptrCast(out + 24);
            stdout_ptr.* = RocList.fromSlice(u8, stdout_bytes.items, false, ops);
            const code_ptr: *align(1) i32 = @ptrCast(out + 48);
            code_ptr.* = code;
            out[56] = 1;
            out[64] = 0;
        },
        .signaled => |sig| {
            var msg_buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "terminated by signal {d}", .{sig}) catch "terminated by signal";
            writeOtherPayload(out, msg, ops);
            out[56] = 0;
            out[64] = 0;
        },
        .err => |errnum| spawn_err(out, errnum, ops),
    }
}

// --- Dir (Phase 3) ----------------------------------------------------------
//
// Same Try(T, [DirErr(IOErr)]) 40-byte shape as the File functions.

extern "c" fn closedir(dir: *std.c.DIR) c_int;

/// Dir.create! : Str => Try({}, [DirErr(IOErr)])
fn hostedDirCreate(ops: *RocOps, ret_ptr: *anyopaque, args: *const extern struct { path: RocStr }) callconv(.c) void {
    defer args.path.decref(ops);
    const out: [*]u8 = @ptrCast(ret_ptr);
    @memset(out[0..40], 0);
    var buf: [1024]u8 = undefined;
    const p = pathZ(args.path, &buf) orelse return writeFileErr(out, ENAMETOOLONG, ops);
    if (std.c.mkdir(p, 0o755) != 0) return writeFileErr(out, std.c._errno().*, ops);
    out[32] = 1; // Ok({})
}

/// Dir.create_all! : Str => Try({}, [DirErr(IOErr)])
/// mkdir every prefix, ignoring EEXIST (an existing directory is success).
fn hostedDirCreateAll(ops: *RocOps, ret_ptr: *anyopaque, args: *const extern struct { path: RocStr }) callconv(.c) void {
    defer args.path.decref(ops);
    const out: [*]u8 = @ptrCast(ret_ptr);
    @memset(out[0..40], 0);
    const path = args.path.asSlice();
    var buf: [1024]u8 = undefined;
    if (path.len >= buf.len) return writeFileErr(out, ENAMETOOLONG, ops);
    var i: usize = 1; // a leading '/' is not a directory to create
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            @memcpy(buf[0..i], path[0..i]);
            buf[i] = 0;
            if (std.c.mkdir(@ptrCast(&buf), 0o755) != 0) {
                const errnum = std.c._errno().*;
                if (errnum != @intFromEnum(std.c.E.EXIST)) return writeFileErr(out, errnum, ops);
            }
        }
    }
    out[32] = 1; // Ok({})
}

/// Recursively delete a directory tree. Returns 0 or an errno.
/// Symlinks are unlinked, not followed.
fn deleteTree(path: [*:0]const u8) c_int {
    const dir = std.c.opendir(path) orelse return std.c._errno().*;
    var failed: c_int = 0;
    while (std.c.readdir(dir)) |entry| {
        const name = entry.name[0..entry.namlen];
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        var child_buf: [1024]u8 = undefined;
        const child = std.fmt.bufPrintZ(&child_buf, "{s}/{s}", .{ std.mem.span(path), name }) catch {
            failed = ENAMETOOLONG;
            break;
        };
        failed = if (entry.type == std.c.DT.DIR)
            deleteTree(child)
        else if (unlink(child) != 0)
            std.c._errno().*
        else
            0;
        if (failed != 0) break;
    }
    _ = closedir(dir);
    if (failed != 0) return failed;
    if (std.c.rmdir(path) != 0) return std.c._errno().*;
    return 0;
}

/// Dir.delete_all! : Str => Try({}, [DirErr(IOErr)])
fn hostedDirDeleteAll(ops: *RocOps, ret_ptr: *anyopaque, args: *const extern struct { path: RocStr }) callconv(.c) void {
    defer args.path.decref(ops);
    const out: [*]u8 = @ptrCast(ret_ptr);
    @memset(out[0..40], 0);
    var buf: [1024]u8 = undefined;
    const p = pathZ(args.path, &buf) orelse return writeFileErr(out, ENAMETOOLONG, ops);
    const errnum = deleteTree(p);
    if (errnum != 0) return writeFileErr(out, errnum, ops);
    out[32] = 1; // Ok({})
}

/// Dir.delete_empty! : Str => Try({}, [DirErr(IOErr)])
fn hostedDirDeleteEmpty(ops: *RocOps, ret_ptr: *anyopaque, args: *const extern struct { path: RocStr }) callconv(.c) void {
    defer args.path.decref(ops);
    const out: [*]u8 = @ptrCast(ret_ptr);
    @memset(out[0..40], 0);
    var buf: [1024]u8 = undefined;
    const p = pathZ(args.path, &buf) orelse return writeFileErr(out, ENAMETOOLONG, ops);
    if (std.c.rmdir(p) != 0) return writeFileErr(out, std.c._errno().*, ops);
    out[32] = 1; // Ok({})
}

/// Dir.list! : Str => Try(List(Str), [DirErr(IOErr)])
/// Returns "dir/name" paths, like basic-cli (which returns prefixed paths).
fn hostedDirList(ops: *RocOps, ret_ptr: *anyopaque, args: *const extern struct { path: RocStr }) callconv(.c) void {
    defer args.path.decref(ops);
    const out: [*]u8 = @ptrCast(ret_ptr);
    @memset(out[0..40], 0);
    var buf: [1024]u8 = undefined;
    const p = pathZ(args.path, &buf) orelse return writeFileErr(out, ENAMETOOLONG, ops);
    const dir = std.c.opendir(p) orelse return writeFileErr(out, std.c._errno().*, ops);
    defer _ = closedir(dir);

    var paths: std.ArrayList(RocStr) = .empty;
    defer paths.deinit(c_allocator);
    while (std.c.readdir(dir)) |entry| {
        const name = entry.name[0..entry.namlen];
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        var child_buf: [1024]u8 = undefined;
        const child = std.fmt.bufPrint(&child_buf, "{s}/{s}", .{ args.path.asSlice(), name }) catch continue;
        paths.append(c_allocator, RocStr.fromSlice(child, ops)) catch break;
    }

    const list_ptr: *align(1) RocList = @ptrCast(out);
    if (paths.items.len == 0) {
        list_ptr.* = RocList.empty();
    } else {
        // elements_refcounted = true: the elements are RocStrs.
        const list = RocList.list_allocate(@alignOf(RocStr), paths.items.len, @sizeOf(RocStr), true, ops);
        const elems: [*]RocStr = @ptrCast(@alignCast(list.bytes));
        for (paths.items, 0..) |path_str, i| elems[i] = path_str;
        list_ptr.* = list;
    }
    out[32] = 1; // Ok
}

// --- File (Phase 2) --------------------------------------------------------
//
// All five return Try(T, [FileErr(IOErr)]): 40 bytes, payload@0 (T or IOErr),
// IOErr's own disc u8@24 (tags alphabetical), Try disc u8@32 (Err=0, Ok=1).
// IOErr := [AlreadyExists, BrokenPipe, Interrupted, NotFound, Other(Str),
// OutOfMemory, PermissionDenied, Unsupported].

extern "c" fn strerror(errnum: c_int) [*:0]u8;
extern "c" fn unlink(path: [*:0]const u8) c_int;

/// Write Err(FileErr(IOErr)) for the given errno into a (zeroed) 40-byte
/// Try return slot. Unmapped errnos become Other(strerror text).
fn writeFileErr(out: [*]u8, errnum: c_int, ops: *RocOps) void {
    writeIOErrPayload(out, errnum, ops);
    out[32] = 0; // Try disc: Err
}

/// Write just an IOErr value (32 bytes: payload@0, disc u8@24) for an errno.
fn writeIOErrPayload(out: [*]u8, errnum: c_int, ops: *RocOps) void {
    out[24] = switch (@as(std.c.E, @enumFromInt(errnum))) {
        .EXIST => 0, // AlreadyExists
        .PIPE => 1, // BrokenPipe
        .INTR => 2, // Interrupted
        .NOENT => 3, // NotFound
        .NOMEM => 5, // OutOfMemory
        .ACCES, .PERM => 6, // PermissionDenied
        .OPNOTSUPP => 7, // Unsupported (same code as ENOTSUP on darwin)
        else => blk: {
            const str_ptr: *align(1) RocStr = @ptrCast(out);
            str_ptr.* = RocStr.fromSlice(std.mem.span(strerror(errnum)), ops);
            break :blk 4; // Other(Str)
        },
    };
}

/// Write an IOErr of Other(message) (32 bytes: Str@0, disc 4 @24).
fn writeOtherPayload(out: [*]u8, message: []const u8, ops: *RocOps) void {
    const str_ptr: *align(1) RocStr = @ptrCast(out);
    str_ptr.* = RocStr.fromSlice(message, ops);
    out[24] = 4; // Other
}

/// Copy a RocStr path into a NUL-terminated buffer for libc calls.
fn pathZ(path: RocStr, buf: *[1024]u8) ?[*:0]const u8 {
    const slice = path.asSlice();
    if (slice.len >= buf.len) return null;
    @memcpy(buf[0..slice.len], slice);
    buf[slice.len] = 0;
    return @ptrCast(buf);
}

const ENAMETOOLONG: c_int = @intFromEnum(std.c.E.NAMETOOLONG);

/// Read a whole file into a c_allocator buffer. Returns the bytes or the
/// errno to report. Caller frees.
fn readWholeFile(path: RocStr) union(enum) { ok: std.ArrayList(u8), err: c_int } {
    var buf: [1024]u8 = undefined;
    const p = pathZ(path, &buf) orelse return .{ .err = ENAMETOOLONG };
    const fd = std.c.open(p, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return .{ .err = std.c._errno().* };
    defer _ = std.c.close(fd);

    var data: std.ArrayList(u8) = .empty;
    var chunk: [16384]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &chunk, chunk.len);
        if (n == 0) break;
        if (n < 0) {
            const errnum = std.c._errno().*;
            if (errnum == @intFromEnum(std.c.E.INTR)) continue;
            data.deinit(c_allocator);
            return .{ .err = errnum };
        }
        data.appendSlice(c_allocator, chunk[0..@intCast(n)]) catch {
            data.deinit(c_allocator);
            return .{ .err = @intFromEnum(std.c.E.NOMEM) };
        };
    }
    return .{ .ok = data };
}

/// Write bytes to a file (create/truncate). Returns 0 or the errno.
fn writeWholeFile(path: RocStr, bytes: []const u8) c_int {
    var buf: [1024]u8 = undefined;
    const p = pathZ(path, &buf) orelse return ENAMETOOLONG;
    const fd = std.c.open(
        p,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        @as(std.c.mode_t, 0o644),
    );
    if (fd < 0) return std.c._errno().*;
    defer _ = std.c.close(fd);

    var index: usize = 0;
    while (index < bytes.len) {
        const n = std.c.write(fd, bytes.ptr + index, bytes.len - index);
        if (n < 0) {
            const errnum = std.c._errno().*;
            if (errnum == @intFromEnum(std.c.E.INTR)) continue;
            return errnum;
        }
        index += @intCast(n);
    }
    return 0;
}

/// File.delete! : Str => Try({}, [FileErr(IOErr)])
fn hostedFileDelete(ops: *RocOps, ret_ptr: *anyopaque, args: *const extern struct { path: RocStr }) callconv(.c) void {
    defer args.path.decref(ops);
    const out: [*]u8 = @ptrCast(ret_ptr);
    @memset(out[0..40], 0);
    var buf: [1024]u8 = undefined;
    const p = pathZ(args.path, &buf) orelse return writeFileErr(out, ENAMETOOLONG, ops);
    if (unlink(p) != 0) return writeFileErr(out, std.c._errno().*, ops);
    out[32] = 1; // Ok({})
}

/// File.read_bytes! : Str => Try(List(U8), [FileErr(IOErr)])
fn hostedFileReadBytes(ops: *RocOps, ret_ptr: *anyopaque, args: *const extern struct { path: RocStr }) callconv(.c) void {
    defer args.path.decref(ops);
    const out: [*]u8 = @ptrCast(ret_ptr);
    @memset(out[0..40], 0);
    switch (readWholeFile(args.path)) {
        .err => |errnum| writeFileErr(out, errnum, ops),
        .ok => |data| {
            var list = data;
            defer list.deinit(c_allocator);
            const list_ptr: *align(1) RocList = @ptrCast(out);
            list_ptr.* = RocList.fromSlice(u8, list.items, false, ops);
            out[32] = 1; // Ok
        },
    }
}

/// File.read_utf8! : Str => Try(Str, [FileErr(IOErr)])
/// Invalid UTF-8 is replaced with U+FFFD (builtins fromUtf8Lossy).
fn hostedFileReadUtf8(ops: *RocOps, ret_ptr: *anyopaque, args: *const extern struct { path: RocStr }) callconv(.c) void {
    defer args.path.decref(ops);
    const out: [*]u8 = @ptrCast(ret_ptr);
    @memset(out[0..40], 0);
    switch (readWholeFile(args.path)) {
        .err => |errnum| writeFileErr(out, errnum, ops),
        .ok => |data| {
            var list = data;
            defer list.deinit(c_allocator);
            const str_ptr: *align(1) RocStr = @ptrCast(out);
            if (std.unicode.utf8ValidateSlice(list.items)) {
                str_ptr.* = RocStr.fromSlice(list.items, ops);
            } else {
                const roc_bytes = RocList.fromSlice(u8, list.items, false, ops);
                str_ptr.* = builtins.str.fromUtf8Lossy(roc_bytes, ops);
                roc_bytes.decref(@alignOf(u8), @sizeOf(u8), false, null, decNoop, ops);
            }
            out[32] = 1; // Ok
        },
    }
}

/// File.write_bytes! : Str, List(U8) => Try({}, [FileErr(IOErr)])
fn hostedFileWriteBytes(ops: *RocOps, ret_ptr: *anyopaque, args: *const extern struct { path: RocStr, bytes: RocList }) callconv(.c) void {
    defer args.path.decref(ops);
    defer args.bytes.decref(@alignOf(u8), @sizeOf(u8), false, null, decNoop, ops);
    const out: [*]u8 = @ptrCast(ret_ptr);
    @memset(out[0..40], 0);
    const bytes: []const u8 = if (args.bytes.bytes) |ptr| ptr[0..args.bytes.len()] else &.{};
    const errnum = writeWholeFile(args.path, bytes);
    if (errnum != 0) return writeFileErr(out, errnum, ops);
    out[32] = 1; // Ok({})
}

/// File.write_utf8! : Str, Str => Try({}, [FileErr(IOErr)])
fn hostedFileWriteUtf8(ops: *RocOps, ret_ptr: *anyopaque, args: *const extern struct { path: RocStr, content: RocStr }) callconv(.c) void {
    defer args.path.decref(ops);
    defer args.content.decref(ops);
    const out: [*]u8 = @ptrCast(ret_ptr);
    @memset(out[0..40], 0);
    const errnum = writeWholeFile(args.path, args.content.asSlice());
    if (errnum != 0) return writeFileErr(out, errnum, ops);
    out[32] = 1; // Ok({})
}

/// Random.seed_u32! : {} => Try(U32, [RandomErr(IOErr)])
/// 40 bytes: payload@0 = max(U32, IOErr 32) = 32, Try disc u8@32.
/// arc4random never fails, so this always returns Ok.
fn hostedRandomSeedU32(_: *RocOps, ret_ptr: *anyopaque, _: *anyopaque) callconv(.c) void {
    const out: [*]u8 = @ptrCast(ret_ptr);
    @memset(out[0..40], 0);
    arc4random_buf(out, 4);
    out[32] = 1; // Ok
}

/// Random.seed_u64! : {} => Try(U64, [RandomErr(IOErr)])
/// Same 40-byte shape, U64 payload.
fn hostedRandomSeedU64(_: *RocOps, ret_ptr: *anyopaque, _: *anyopaque) callconv(.c) void {
    const out: [*]u8 = @ptrCast(ret_ptr);
    @memset(out[0..40], 0);
    arc4random_buf(out, 8);
    out[32] = 1; // Ok
}

/// Sleep.millis! : U64 => {}
/// A sleeping handler occupies its worker thread for the duration; with
/// every worker sleeping, further connections queue. Documented in Sleep.roc.
fn hostedSleepMillis(_: *RocOps, _: *anyopaque, args: *const extern struct { ms: u64 }) callconv(.c) void {
    var req: std.c.timespec = .{
        .sec = @intCast(args.ms / 1000),
        .nsec = @intCast((args.ms % 1000) * 1_000_000),
    };
    // Retry on signal interrupt; rem is updated with the remaining time.
    while (std.c.nanosleep(&req, &req) != 0 and std.c._errno().* == @intFromEnum(std.c.E.INTR)) {}
}

/// Utc.now! : {} => U128 (nanoseconds since the Unix epoch)
fn hostedUtcNow(_: *RocOps, ret_ptr: *anyopaque, _: *anyopaque) callconv(.c) void {
    const out: *align(1) u128 = @ptrCast(ret_ptr);
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) {
        out.* = 0;
        return;
    }
    out.* = @as(u128, @intCast(ts.sec)) * 1_000_000_000 + @as(u128, @intCast(ts.nsec));
}

/// Stderr.line! : Str => {}
fn hostedStderrLine(ops: *RocOps, _: *anyopaque, args: *const extern struct { str: RocStr }) callconv(.c) void {
    defer args.str.decref(ops);
    printStderr(args.str.asSlice());
    printStderr("\n");
}

/// Stdout.line! : Str => {}
fn hostedStdoutLine(ops: *RocOps, _: *anyopaque, args: *const extern struct { str: RocStr }) callconv(.c) void {
    defer args.str.decref(ops);
    printStdout(args.str.asSlice());
    printStdout("\n");
}

/// Hosted functions sorted alphabetically by fully-qualified name
/// (module.function with the `!` stripped), matching the index order
/// assigned by the compiler during canonicalization.
const hosted_function_ptrs = [_]builtins.host_abi.HostedFn{
    builtins.host_abi.hostedFn(&hostedCmdHostExecExitCode), // Cmd.host_exec_exit_code! (index 0)
    builtins.host_abi.hostedFn(&hostedCmdHostExecOutput), // Cmd.host_exec_output! (index 1)
    builtins.host_abi.hostedFn(&hostedDirCreate), // Dir.create! (index 2)
    builtins.host_abi.hostedFn(&hostedDirCreateAll), // Dir.create_all! (index 1)
    builtins.host_abi.hostedFn(&hostedDirDeleteAll), // Dir.delete_all! (index 2)
    builtins.host_abi.hostedFn(&hostedDirDeleteEmpty), // Dir.delete_empty! (index 3)
    builtins.host_abi.hostedFn(&hostedDirList), // Dir.list! (index 4)
    builtins.host_abi.hostedFn(&hostedEnvCwd), // Env.cwd! (index 5)
    builtins.host_abi.hostedFn(&hostedEnvExePath), // Env.exe_path! (index 6)
    builtins.host_abi.hostedFn(&hostedEnvVar), // Env.var! (index 7)
    builtins.host_abi.hostedFn(&hostedFileDelete), // File.delete! (index 8)
    builtins.host_abi.hostedFn(&hostedFileReadBytes), // File.read_bytes! (index 9)
    builtins.host_abi.hostedFn(&hostedFileReadUtf8), // File.read_utf8! (index 10)
    builtins.host_abi.hostedFn(&hostedFileWriteBytes), // File.write_bytes! (index 11)
    builtins.host_abi.hostedFn(&hostedFileWriteUtf8), // File.write_utf8! (index 12)
    builtins.host_abi.hostedFn(&hostedRandomSeedU32), // Random.seed_u32! (index 13)
    builtins.host_abi.hostedFn(&hostedRandomSeedU64), // Random.seed_u64! (index 14)
    builtins.host_abi.hostedFn(&hostedSleepMillis), // Sleep.millis! (index 15)
    builtins.host_abi.hostedFn(&hostedStderrLine), // Stderr.line! (index 16)
    builtins.host_abi.hostedFn(&hostedStdoutLine), // Stdout.line! (index 17)
    builtins.host_abi.hostedFn(&hostedUtcNow), // Utc.now! (index 18)
};

// ============================================================================
// HTTP server
// ============================================================================

fn statusText(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        413 => "Content Too Large",
        500 => "Internal Server Error",
        else => "Status",
    };
}

/// Read from a socket; returns 0 on EOF, error, or timeout.
fn readFd(fd: Fd, buf: []u8) usize {
    const n = std.posix.read(fd, buf) catch return 0;
    return n;
}

const ParsedHeader = struct {
    name: []const u8,
    value: []const u8,
};

const ParsedHead = struct {
    method: []const u8,
    path: []const u8,
    headers: [MAX_HEADERS]ParsedHeader,
    header_count: usize,
    content_length: usize,
    connection_close: bool,
};

/// Parse the request line and header block (everything before \r\n\r\n).
fn parseHead(head: []const u8) ParsedHead {
    var parsed = ParsedHead{
        .method = "",
        .path = "",
        .headers = undefined,
        .header_count = 0,
        .content_length = 0,
        .connection_close = false,
    };

    var lines = std.mem.splitSequence(u8, head, "\r\n");

    const request_line = lines.next() orelse return parsed;
    var parts = std.mem.splitScalar(u8, request_line, ' ');
    parsed.method = parts.next() orelse "";
    parsed.path = parts.next() orelse "";

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            parsed.content_length = std.fmt.parseInt(usize, value, 10) catch 0;
        }
        if (std.ascii.eqlIgnoreCase(name, "connection") and std.ascii.eqlIgnoreCase(value, "close")) {
            parsed.connection_close = true;
        }

        if (parsed.header_count < MAX_HEADERS) {
            parsed.headers[parsed.header_count] = .{ .name = name, .value = value };
            parsed.header_count += 1;
        }
    }

    return parsed;
}

/// Build the Roc List({ name : Str, value : Str }) from parsed headers.
/// Same construction as buildArgsList in roc test/fx-open/platform/host.zig.
fn buildHeadersList(ops: *RocOps, headers: []const ParsedHeader) RocList {
    if (headers.len == 0) return RocList.empty();

    // elements_refcounted = true: the element records contain RocStrs.
    const list = RocList.list_allocate(@alignOf(RocHeader), headers.len, @sizeOf(RocHeader), true, ops);
    const elems: [*]RocHeader = @ptrCast(@alignCast(list.bytes));
    for (headers, 0..) |header, i| {
        elems[i] = .{
            .name = RocStr.fromSlice(header.name, ops),
            .value = RocStr.fromSlice(header.value, ops),
        };
    }
    return list;
}

/// No-op element destructor for lists of non-refcounted elements (U8 body).
fn decNoop(_: ?*anyopaque, _: ?[*]u8) callconv(.c) void {}

/// Element destructor for the response headers list.
fn decHeaderElement(context: ?*anyopaque, element: ?[*]u8) callconv(.c) void {
    const ops: *RocOps = @ptrCast(@alignCast(context.?));
    const header: *RocHeader = @ptrCast(@alignCast(element.?));
    header.name.decref(ops);
    header.value.decref(ops);
}

const STATIC_413 = "HTTP/1.1 413 Content Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";

// ============================================================================
// WebSocket support (RFC 6455, server side)
// ============================================================================
//
// The host owns handshake and framing; for every complete text frame it
// calls roc__ws_message with { message, path } and sends the returned Str
// back as a text frame. Limitations (fine for a demo): no fragmented
// messages, text frames only, 64 KiB max payload.

const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const WS_MAX_PAYLOAD: usize = 64 * 1024;
/// Read timeout per wait on an upgraded socket. On expiry at a frame
/// boundary the host pings once; a client that answers pings stays
/// connected indefinitely, a dead one is dropped after ~2x this value.
/// Also bounds graceful-shutdown drain for idle WS connections.
const WS_IDLE_TIMEOUT_SECONDS: i64 = 5;

/// WebSocket message record passed to roc__ws_message:
/// { message : Str, path : Str } — alphabetical, both RocStr.
const RocWsFrame = extern struct {
    message: RocStr,
    path: RocStr,
};

/// Returned by roc__ws_message: { broadcast : Str, reply : Str }.
const RocWsReply = extern struct {
    broadcast: RocStr,
    reply: RocStr,
};

extern fn roc__ws_message(ops: *RocOps, ret_ptr: *anyopaque, arg_ptr: ?*anyopaque) callconv(.c) void;

/// Registry of connected WebSocket clients plus a write lock. One mutex
/// covers both membership and ALL websocket frame writes: workers handling
/// different clients would otherwise interleave frame bytes on a shared
/// destination during broadcasts.
const MAX_WS_CLIENTS: usize = 32;

const WsClients = struct {
    mutex: std.c.pthread_mutex_t = .{},
    fds: [MAX_WS_CLIENTS]Fd = [_]Fd{-1} ** MAX_WS_CLIENTS,

    fn register(self: *WsClients, fd: Fd) bool {
        lockMutex(&self.mutex);
        defer unlockMutex(&self.mutex);
        for (&self.fds) |*slot| {
            if (slot.* == -1) {
                slot.* = fd;
                return true;
            }
        }
        return false; // full
    }

    fn unregister(self: *WsClients, fd: Fd) void {
        lockMutex(&self.mutex);
        defer unlockMutex(&self.mutex);
        for (&self.fds) |*slot| {
            if (slot.* == fd) slot.* = -1;
        }
    }

    /// Send a text frame to the given client, serialized with all other
    /// websocket writes.
    fn send(self: *WsClients, fd: Fd, opcode: u8, payload: []const u8) void {
        lockMutex(&self.mutex);
        defer unlockMutex(&self.mutex);
        writeWsFrameUnlocked(fd, opcode, payload);
    }

    /// Send a text frame to every connected client.
    fn broadcast(self: *WsClients, payload: []const u8) void {
        lockMutex(&self.mutex);
        defer unlockMutex(&self.mutex);
        for (self.fds) |fd| {
            if (fd != -1) writeWsFrameUnlocked(fd, 0x1, payload);
        }
    }
};

var ws_clients = WsClients{};

/// Returns the Sec-WebSocket-Key if this request is a websocket upgrade.
fn websocketKey(parsed: *const ParsedHead) ?[]const u8 {
    var upgrade_ok = false;
    var key: ?[]const u8 = null;
    for (parsed.headers[0..parsed.header_count]) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "upgrade") and std.ascii.eqlIgnoreCase(header.value, "websocket")) {
            upgrade_ok = true;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-key")) {
            key = header.value;
        }
    }
    return if (upgrade_ok) key else null;
}

/// Perform the RFC 6455 handshake response for the given key.
fn writeWsHandshake(fd: Fd, key: []const u8) void {
    var sha_input_buf: [128]u8 = undefined;
    const sha_input = std.fmt.bufPrint(&sha_input_buf, "{s}{s}", .{ key, WS_GUID }) catch return;

    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(sha_input, &digest, .{});

    var accept_buf: [28]u8 = undefined;
    const accept = std.base64.standard.Encoder.encode(&accept_buf, &digest);

    var response_buf: [256]u8 = undefined;
    const response = std.fmt.bufPrint(
        &response_buf,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n",
        .{accept},
    ) catch return;
    writeAllFd(fd, response);
}

/// Send a server->client frame (unmasked) with the given opcode.
/// Callers must hold ws_clients.mutex (or be the only writer, i.e. before
/// the connection is registered).
fn writeWsFrameUnlocked(fd: Fd, opcode: u8, payload: []const u8) void {
    var header_buf: [10]u8 = undefined;
    var header_len: usize = 2;
    header_buf[0] = 0x80 | opcode; // FIN + opcode
    if (payload.len < 126) {
        header_buf[1] = @intCast(payload.len);
    } else if (payload.len <= 0xFFFF) {
        header_buf[1] = 126;
        std.mem.writeInt(u16, header_buf[2..4], @intCast(payload.len), .big);
        header_len = 4;
    } else {
        header_buf[1] = 127;
        std.mem.writeInt(u64, header_buf[2..10], payload.len, .big);
        header_len = 10;
    }
    writeAllFd(fd, header_buf[0..header_len]);
    writeAllFd(fd, payload);
}

fn writeWsClose(fd: Fd, code: u16) void {
    var payload: [2]u8 = undefined;
    std.mem.writeInt(u16, &payload, code, .big);
    ws_clients.send(fd, 0x8, &payload);
}

const WsReadResult = enum { ok, timeout, closed };

/// Buffered reader over the socket; seeded with any bytes that arrived
/// together with the handshake request.
const WsReader = struct {
    fd: Fd,
    buf: [4096]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    fn fill(self: *WsReader) WsReadResult {
        if (self.start == self.end) {
            self.start = 0;
            self.end = 0;
        }
        const n = std.posix.read(self.fd, self.buf[self.end..]) catch |err| switch (err) {
            error.WouldBlock => return .timeout, // SO_RCVTIMEO expired
            else => return .closed,
        };
        if (n == 0) return .closed;
        self.end += n;
        return .ok;
    }

    /// Read exactly out.len bytes. allow_idle is true only at a frame
    /// boundary: a timeout there pings the client once before giving up.
    fn readExact(self: *WsReader, out: []u8, allow_idle: bool) WsReadResult {
        var got: usize = 0;
        var pinged = false;
        while (got < out.len) {
            const available = self.end - self.start;
            if (available > 0) {
                const take = @min(available, out.len - got);
                @memcpy(out[got .. got + take], self.buf[self.start .. self.start + take]);
                self.start += take;
                got += take;
                continue;
            }
            switch (self.fill()) {
                .ok => {},
                .closed => return .closed,
                .timeout => {
                    if (shutting_down.load(.acquire)) return .timeout;
                    if (allow_idle and got == 0 and !pinged) {
                        ws_clients.send(self.fd, 0x9, "keepalive");
                        pinged = true;
                        continue;
                    }
                    return .timeout;
                },
            }
        }
        return .ok;
    }
};

/// Frame loop for an upgraded connection. `path` is the request path of the
/// upgrade request; `initial` holds bytes already read past the handshake.
fn wsLoop(ops: *RocOps, fd: Fd, path: []const u8, initial: []const u8) void {
    // Long-lived connection: relax the socket timeout to the idle interval.
    const timeout = std.c.timeval{ .sec = WS_IDLE_TIMEOUT_SECONDS, .usec = 0 };
    std.posix.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

    if (!ws_clients.register(fd)) {
        writeWsFrameUnlocked(fd, 0x8, &[2]u8{ 0x03, 0xF5 }); // 1013 try again later
        return;
    }
    defer ws_clients.unregister(fd);

    var reader = WsReader{ .fd = fd };
    if (initial.len > 0 and initial.len <= reader.buf.len) {
        @memcpy(reader.buf[0..initial.len], initial);
        reader.end = initial.len;
    }

    while (true) {
        if (shutting_down.load(.acquire)) {
            writeWsClose(fd, 1001); // going away
            return;
        }

        var head: [2]u8 = undefined;
        switch (reader.readExact(&head, true)) {
            .ok => {},
            .timeout => {
                writeWsClose(fd, 1001);
                return;
            },
            .closed => return,
        }

        const fin = head[0] & 0x80 != 0;
        const opcode = head[0] & 0x0F;
        const masked = head[1] & 0x80 != 0;
        var payload_len: u64 = head[1] & 0x7F;

        if (payload_len == 126) {
            var ext: [2]u8 = undefined;
            if (reader.readExact(&ext, false) != .ok) return;
            payload_len = std.mem.readInt(u16, &ext, .big);
        } else if (payload_len == 127) {
            var ext: [8]u8 = undefined;
            if (reader.readExact(&ext, false) != .ok) return;
            payload_len = std.mem.readInt(u64, &ext, .big);
        }

        if (!masked) {
            writeWsClose(fd, 1002); // protocol error: client frames must be masked
            return;
        }
        if (payload_len > WS_MAX_PAYLOAD) {
            writeWsClose(fd, 1009); // message too big
            return;
        }

        var mask: [4]u8 = undefined;
        if (reader.readExact(&mask, false) != .ok) return;

        const len: usize = @intCast(payload_len);
        const payload = c_allocator.alloc(u8, @max(len, 1)) catch return;
        defer c_allocator.free(payload);
        if (len > 0) {
            if (reader.readExact(payload[0..len], false) != .ok) return;
            for (payload[0..len], 0..) |*byte, i| {
                byte.* ^= mask[i % 4];
            }
        }

        switch (opcode) {
            0x1 => { // text
                if (!fin) {
                    writeWsClose(fd, 1009); // fragmentation unsupported
                    return;
                }
                const frame = RocWsFrame{
                    .message = RocStr.fromSlice(payload[0..len], ops),
                    .path = RocStr.fromSlice(path, ops),
                };
                var result: RocWsReply = undefined;
                {
                    roc__ws_message(ops, @ptrCast(&result), @constCast(@ptrCast(&frame)));
                }
                if (result.reply.asSlice().len > 0) {
                    ws_clients.send(fd, 0x1, result.reply.asSlice());
                }
                if (result.broadcast.asSlice().len > 0) {
                    ws_clients.broadcast(result.broadcast.asSlice());
                }
                result.reply.decref(ops);
                result.broadcast.decref(ops);
            },
            0x2 => { // binary: unsupported in this platform
                writeWsClose(fd, 1003);
                return;
            },
            0x8 => { // close: echo and finish
                ws_clients.send(fd, 0x8, payload[0..@min(len, 2)]);
                return;
            },
            0x9 => { // ping -> pong
                ws_clients.send(fd, 0xA, payload[0..len]);
            },
            0xA => {}, // pong (reply to our keepalive): ignore
            else => {
                writeWsClose(fd, 1002);
                return;
            },
        }
    }
}

/// Apply read/write timeouts so a silent or slow client cannot occupy a
/// worker thread forever.
fn setSocketTimeouts(fd: Fd) void {
    const timeout = std.c.timeval{ .sec = SOCKET_TIMEOUT_SECONDS, .usec = 0 };
    std.posix.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};
    std.posix.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch {};
}

/// Handle one connection: read, parse, call the Roc handler, respond.
/// Runs on a worker thread; the roc__handle call runs in parallel with
/// other workers' calls.
fn handleConnection(ops: *RocOps, fd: Fd) void {
    defer _ = std.c.close(fd);

    setSocketTimeouts(fd);

    var head_buf: [MAX_HEADER_BYTES]u8 = undefined;
    var have: usize = 0;

    // Keep-alive loop: handle requests on this connection until the client
    // closes, asks for Connection: close, or idles past the socket timeout.
    while (true) {
        // Read until the header block is complete (\r\n\r\n).
        var head_end: usize = 0;
        while (true) {
            if (std.mem.indexOf(u8, head_buf[0..have], "\r\n\r\n")) |idx| {
                head_end = idx + 4;
                break;
            }
            if (have == head_buf.len) return; // header block too large
            const n = readFd(fd, head_buf[have..]);
            if (n == 0) return; // EOF or timeout
            have += n;
        }

        const parsed = parseHead(head_buf[0 .. head_end - 4]);

        // WebSocket upgrade: hand the connection to the frame loop.
        if (websocketKey(&parsed)) |key| {
            writeWsHandshake(fd, key);
            wsLoop(ops, fd, parsed.path, head_buf[head_end..have]);
            return;
        }

        if (parsed.content_length > MAX_BODY_BYTES) {
            writeAllFd(fd, STATIC_413);
            return;
        }

        // Assemble the body: bytes already read past the headers, then keep
        // reading until Content-Length is satisfied (no Content-Length -> no body).
        const already = @min(have - head_end, parsed.content_length);
        var body: []const u8 = head_buf[head_end .. head_end + already];
        var body_alloc: ?[]u8 = null;
        defer if (body_alloc) |b| c_allocator.free(b);

        if (parsed.content_length > already) {
            const buf = c_allocator.alloc(u8, parsed.content_length) catch return;
            body_alloc = buf;
            @memcpy(buf[0..already], body);
            var filled: usize = already;
            while (filled < parsed.content_length) {
                const n = readFd(fd, buf[filled..]);
                if (n == 0) return; // EOF or timeout mid-body
                filled += n;
            }
            body = buf;
        }

        // Bytes of a pipelined next request that we already read.
        const consumed = head_end + already;
        const leftover = have - consumed;

        // Build the Roc Request record. The handler takes ownership of the
        // values (the generated code decrefs its arguments).
        const request = RocRequest{
            .body = RocList.fromSlice(u8, body, false, ops),
            .headers = buildHeadersList(ops, parsed.headers[0..parsed.header_count]),
            .method = RocStr.fromSlice(parsed.method, ops),
            .uri = RocStr.fromSlice(parsed.path, ops),
        };

        var response: RocResponse = undefined;
        {
            roc__handle(ops, @ptrCast(&response), @constCast(@ptrCast(&request)));
        }

        const keep_alive = !parsed.connection_close and !shutting_down.load(.acquire);
        const suppress_body = std.mem.eql(u8, parsed.method, "HEAD");
        writeResponse(fd, &response, keep_alive, suppress_body);

        // The host owns the returned response; release its values.
        response.body.decref(@alignOf(u8), @sizeOf(u8), false, null, decNoop, ops);
        response.headers.decref(
            @alignOf(RocHeader),
            @sizeOf(RocHeader),
            true,
            @as(*anyopaque, @ptrCast(ops)),
            decHeaderElement,
            ops,
        );

        if (!keep_alive) return;

        // Shift any pipelined bytes to the front and continue.
        std.mem.copyForwards(u8, head_buf[0..leftover], head_buf[consumed .. consumed + leftover]);
        have = leftover;
    }
}

/// Write status line, app-provided headers, Content-Length, Connection and
/// the body. For HEAD requests the body is suppressed but Content-Length
/// still reflects it (RFC 9110).
fn writeResponse(fd: Fd, response: *const RocResponse, keep_alive: bool, suppress_body: bool) void {
    const body: []const u8 = if (response.body.bytes) |bytes|
        bytes[0..response.body.length]
    else
        "";

    var line_buf: [1024]u8 = undefined;
    const status_line = std.fmt.bufPrint(
        &line_buf,
        "HTTP/1.1 {d} {s}\r\nContent-Length: {d}\r\nConnection: {s}\r\n",
        .{
            response.status,
            statusText(response.status),
            body.len,
            if (keep_alive) @as([]const u8, "keep-alive") else "close",
        },
    ) catch return;
    writeAllFd(fd, status_line);

    if (response.headers.bytes) |bytes| {
        const elems: [*]const RocHeader = @ptrCast(@alignCast(bytes));
        for (0..response.headers.length) |i| {
            const name = elems[i].name.asSlice();
            const value = elems[i].value.asSlice();
            // Refuse header injection via embedded CR/LF.
            if (std.mem.indexOfAny(u8, name, "\r\n") != null) continue;
            if (std.mem.indexOfAny(u8, value, "\r\n") != null) continue;
            var header_buf: [1024]u8 = undefined;
            const line = std.fmt.bufPrint(&header_buf, "{s}: {s}\r\n", .{ name, value }) catch continue;
            writeAllFd(fd, line);
        }
    }

    writeAllFd(fd, "\r\n");
    if (!suppress_body) {
        writeAllFd(fd, body);
    }
}

// ============================================================================
// Connection queue and worker pool
// ============================================================================

/// Bounded MPMC queue of accepted connection fds (mutex + condition
/// variables). The acceptor thread pushes; worker threads pop. When the
/// queue is full, the acceptor blocks, which makes the kernel listen
/// backlog absorb bursts. fd -1 is the shutdown poison pill.
const ConnQueue = struct {
    mutex: std.c.pthread_mutex_t = .{},
    not_empty: std.c.pthread_cond_t = .{},
    not_full: std.c.pthread_cond_t = .{},
    buf: [QUEUE_CAP]Fd = undefined,
    head: usize = 0,
    count: usize = 0,

    fn push(self: *ConnQueue, fd: Fd) void {
        lockMutex(&self.mutex);
        defer unlockMutex(&self.mutex);
        while (self.count == QUEUE_CAP) {
            _ = std.c.pthread_cond_wait(&self.not_full, &self.mutex);
        }
        self.buf[(self.head + self.count) % QUEUE_CAP] = fd;
        self.count += 1;
        _ = std.c.pthread_cond_signal(&self.not_empty);
    }

    fn pop(self: *ConnQueue) Fd {
        lockMutex(&self.mutex);
        defer unlockMutex(&self.mutex);
        while (self.count == 0) {
            _ = std.c.pthread_cond_wait(&self.not_empty, &self.mutex);
        }
        const fd = self.buf[self.head];
        self.head = (self.head + 1) % QUEUE_CAP;
        self.count -= 1;
        _ = std.c.pthread_cond_signal(&self.not_full);
        return fd;
    }
};

var conn_queue = ConnQueue{};

fn workerLoop(ops: *RocOps) void {
    while (true) {
        const fd = conn_queue.pop();
        if (fd == -1) return; // poison pill: drain complete
        handleConnection(ops, fd);
    }
}

fn workerCount() usize {
    // Workers are cheap blocking threads; WS connections occupy one each,
    // so allow more than core count to keep HTTP responsive during chats.
    const cpus = std.Thread.getCpuCount() catch 4;
    return @max(4, @min(cpus * 2, MAX_WORKERS));
}

// ============================================================================
// Entry point
// ============================================================================

// Symbol provided by the Roc runtime, per `provides { handle_for_host!: "handle" }`.
extern fn roc__handle(ops: *RocOps, ret_ptr: *anyopaque, arg_ptr: ?*anyopaque) callconv(.c) void;

comptime {
    if (!@import("builtin").is_test) {
        @export(&main, .{ .name = "main" });
    }
}

/// SIGINT/SIGTERM: just flag shutdown. The acceptor polls with a timeout,
/// so it notices within 500 ms without any fd tricks (closing the listener
/// from the signal handler makes a blocked accept() hit EBADF -> unreachable).
fn handleShutdownSignal(_: std.posix.SIG) callconv(.c) void {
    shutting_down.store(true, .release);
}

fn installShutdownHandlers() void {
    const action = std.posix.Sigaction{
        .handler = .{ .handler = handleShutdownSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
}

/// Port precedence: argv[1], then PORT env var, then 8000.
fn resolvePort(argc: c_int, argv: [*][*:0]u8) u16 {
    if (argc > 1) {
        return std.fmt.parseInt(u16, std.mem.span(argv[1]), 10) catch DEFAULT_PORT;
    }
    if (getenv("PORT")) |value| {
        return std.fmt.parseInt(u16, std.mem.span(value), 10) catch DEFAULT_PORT;
    }
    return DEFAULT_PORT;
}

/// Bind and listen on 127.0.0.1:port via libc. Returns the listener fd.
fn listenOn(port: u16) ?Fd {
    const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (fd < 0) return null;

    const one: c_int = 1;
    _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &one, @sizeOf(c_int));

    var addr = std.c.sockaddr.in{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7F_00_00_01), // 127.0.0.1
    };
    if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) != 0) {
        _ = std.c.close(fd);
        return null;
    }
    if (std.c.listen(fd, 128) != 0) {
        _ = std.c.close(fd);
        return null;
    }
    return fd;
}

fn main(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    const port = resolvePort(argc, argv);

    var host_env: u8 = 0; // no host state needed (yet)

    var roc_ops = RocOps{
        .env = @as(*anyopaque, @ptrCast(&host_env)),
        .roc_alloc = rocAllocFn,
        .roc_dealloc = rocDeallocFn,
        .roc_realloc = rocReallocFn,
        .roc_dbg = rocDbgFn,
        .roc_expect_failed = rocExpectFailedFn,
        .roc_crashed = rocCrashedFn,
        .hosted_fns = .{
            .count = hosted_function_ptrs.len,
            .fns = @constCast(&hosted_function_ptrs),
        },
    };

    const listener_fd = listenOn(port) orelse {
        var err_buf: [96]u8 = undefined;
        const err_msg = std.fmt.bufPrint(&err_buf, "Host error: failed to listen on port {d}\n", .{port}) catch "Host error: failed to listen\n";
        printStderr(err_msg);
        return 1;
    };

    installShutdownHandlers();

    // Spawn the worker pool; threads are joined during graceful shutdown.
    var threads: [MAX_WORKERS]std.Thread = undefined;
    const workers = workerCount();
    var spawned: usize = 0;
    while (spawned < workers) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{}, workerLoop, .{&roc_ops}) catch {
            printStderr("Host error: failed to spawn worker thread\n");
            return 1;
        };
    }

    var msg_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Server running on http://localhost:{d} ({d} workers)\n", .{ port, workers }) catch "Server running\n";
    printStdout(msg);

    // Accept until shutdown is flagged. Poll with a timeout so the flag is
    // rechecked even when no connections arrive.
    while (!shutting_down.load(.acquire)) {
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = listener_fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&poll_fds, 500) catch continue; // EINTR -> recheck flag
        if (ready == 0) continue;
        const conn_fd = std.c.accept(listener_fd, null, null);
        if (conn_fd < 0) continue;
        conn_queue.push(conn_fd);
    }

    // Graceful drain: workers finish queued + in-flight connections, then
    // each consumes one poison pill and exits.
    for (0..workers) |_| {
        conn_queue.push(-1);
    }
    for (threads[0..workers]) |thread| {
        thread.join();
    }

    _ = std.c.close(listener_fd);

    printStdout("Server stopped gracefully\n");
    return 0;
}
