# I/O Port Plan & Complete Project State (compaction file, 2026-06-10)

This file holds everything needed to continue working on new-basic-webserver
without prior conversation context. Companion doc:
CREATING-AN–EXPERIMENTAL–BASIC-WEBSERVER-new-compiler.md (full history).

## Project identity

Experimental port of basic-webserver to Roc's new Zig compiler.
~/Code/roc/new-basic-webserver, git main, all work committed through
a5a2c00 (websocket-elm).

## Toolchain (pinned, working)

- roc compiler: ~/Code/roc/roc-48b28c07/zig-out/bin/roc (= /usr/local/bin/roc,
  both debug-48b28c07, built 2026-06-10 from worktree with Zig 0.16.0)
- Zig 0.16.0: ~/zig-0.16.0/zig (0.15.2 still at /usr/local/bin/zig for other projects)
- Pinned worktree ../roc-48b28c07 (referenced by build.zig.zon); old
  ../roc-ee0fc49d worktree still exists, removable
- build: ./build.sh <example> [port] (compiles src/Main.elm first if present,
  then zig build arm64mac, then roc build, then runs ./main)
- Nightlies now exist: github.com/roc-lang/nightlies (daily,
  e.g. nightly-2026-June-09-2c6b32e). Possible future pin source.

## Architecture (all verified working)

- Handler inversion: Zig host owns listener + accept loop; worker pool
  (min(2x cores,16)) does connection I/O; roc calls serialized by
  roc_call_mutex (interpreter shares global state; refcounts ARE atomic).
- Apps export BOTH:
  handle! : Request => Response        (HTTP; roc-lang/http vendored types)
  on_ws!  : { message : Str, path : Str } => { broadcast : Str, reply : Str }
- platform/: main.roc (requires/provides), Method/Request/Response.roc
  (vendored from roc-lang/http @ cc845a2, pristine except added
  Method.from_str), Stdout.roc, Stderr.roc, host.zig (~1000 lines: HTTP
  parsing, keep-alive, WebSocket RFC6455 + broadcast registry, graceful
  shutdown via poll+atomic flag, port from argv/$PORT/8000).
- Host boundary types (flat records; nominal types built Roc-side in
  platform/main.roc wrappers handle_for_host!/ws_for_host!):
  Request:  { body : List(U8), headers : List((Str,Str)), method : Str, uri : Str }
  Response: { body : List(U8), headers : List((Str,Str)), status : U16 }
- examples/: app (HTTP demo), ws-echo, chat (broadcast), websocket-elm
  (Elm frontend; elm.js embedded via ingested import
  `import "elm.js" as elm_js : Str` — ingested files WORK at this pin).
- tests/: wstest_helpers.py, test_ws_concurrent.py, test_ws_chat.py
  (raw-socket WS protocol tests; run server first, port 8000).

## ABI knowledge (hard-won, all verified at 48b28c07)

- Roc record layout: fields sorted by ALIGNMENT DESC, then NAME ALPHABETICAL.
  Tuples: alignment desc, then position. RocStr/RocList = 24B align 8.
- Entry points: provides { name!: "sym" } → host calls roc__sym(ops, ret_ptr,
  arg_ptr); args struct built per layout rule above; fresh interpreter per call.
- Hosted fns: type-erased via builtins.host_abi.hostedFn(&f); table sorted
  alphabetically by Module.function (! stripped) — BUT for functions spanning
  multiple modules the rule is "more involved": see
  ~/Code/roc/roc-48b28c07/src/compile/README.md ("Host functions") — MUST READ
  during Phase 0/1 before adding modules.
- Ownership: hosted fns OWN their refcounted args (must decref; new contract
  at this pin). Roc entrypoints CONSUME their args; host owns returned values
  and must decref (RocList.decref takes element destructor w/ context; pass ops).
- Host allocator: size header before each allocation (realloc gets no old len).
- roc's build.zig panics as b.dependency → our build.zig constructs builtins
  module directly: builtins(src/builtins/mod.zig) ← tracy(src/build/tracy.zig)
  ← options{4x tracy flags false/0}.
- Zig 0.16: no std.net; host uses libc (std.c sockets, pthread mutex/cond,
  raw write()); sigaction handler takes std.posix.SIG enum.
- All 4 old-pin compiler bugs FIXED at 48b28c07 (record-update UAF, map with
  match-lambda, fold+append, tuple lists) — verified by probe.
- VERIFIED by Phase 0 probe (/tmp/ioprobe, 2026-06-10) — both directions
  (roc-built hexdumps AND host-built values matched in roc):
  - RocStr field order AT THIS PIN: bytes@0, capacity_or_alloc_ptr@8,
    length@16 (!). Big strs store capacity SHIFTED LEFT BY ONE at offset 8;
    seamless slices store alloc ptr tagged with 1. Differs from old Rust ABI
    (ptr/len/cap). Always use builtins.str.RocStr, never hand-rolled structs.
  - Multi-arg hosted fns WORK: args struct = extern struct, fields by
    alignment desc then positional (Str,U64 → str@0,num@24; Str,List(U8) →
    str@0,list@24).
  - Tag unions as hosted-fn ARGS work too (dump_try_str! took a Try).
  - Try(Str, [VarNotFound]): 32B; payload RocStr@0; disc u8@24; Err=0, Ok=1
    (alphabetical).
  - Try(List(U8), [FileErr(ErrLike)]) with ErrLike := [NotFound, Other(Str),
    Permission]: 40B total. Single-tag wrapper [FileErr(..)] is TRANSPARENT
    (no disc). ErrLike: payload@0 (Other's Str), own disc u8@24 (NotFound=0,
    Other=1, Permission=2, alphabetical), size 32. Try: payload@0 =
    max(RocList 24, ErrLike 32) = 32; Try disc u8@32; Err=0, Ok=1.
  - General tag-union rule confirmed: size = max payload + disc (aligned),
    disc AFTER payload, tags alphabetical, single-variant = transparent.
  - Hosted-fn table order confirmed across modules: globally alphabetical by
    Module.fn (! stripped): Probe.dump_try_str, Probe.make_env,
    Probe.make_read, Probe.two_args, Probe.write_like, Stdout.line.
  - Pattern for writing Try into ret_ptr: @memset 0 first, write payload via
    *align(1) RocStr/RocList @ptrCast(out), set disc bytes (see
    /tmp/ioprobe/platform/host.zig hostedProbeMakeEnv/MakeRead).

## Research findings (2026-06-10, all verified)

1. basic-cli port EXISTS upstream: roc-lang/basic-cli branches
   migrate-zig-compiler + migrate-zig-compiler-edits, authored by Anton-4 and
   Luke Boswell (no commits from us; our clone at
   ~/Code/roc/basic-cli is reference-only, currently on -edits branch).
   Strategy there: Roc modules in new syntax (14 modules: Cmd, Dir, Env, File,
   IOErr, Locale, Path, Random, Sleep, Stdin, Stdout, Stderr, Tty, Utc) +
   RUST host implementing the new RocOps ABI (src/lib.rs, RocTry<T,IOErr>).
   Targets nightlies; 43 parse errors against our pin = version skew only.
2. Old basic-webserver (~/Code/roc/basic-webserver, Rust) literally depends on
   basic-cli crates (roc_env, roc_command, roc_io_error, roc_stdio, roc_file,
   roc_http, roc_sqlite via git deps) → "webserver = basic-cli effect layer +
   hyper/tokio web host" is the historical architecture. Hypothesis confirmed.
3. Decision: do NOT port all of basic-cli to Zig (duplicates active upstream
   work). Instead adopt basic-cli's module API surface selectively into our
   Zig host so apps are API-compatible.

## Reference paths

- Compiler internals: ~/Code/roc/roc-48b28c07/src/builtins/host_abi.zig,
  src/compile/README.md, src/canonicalize/HostedCompiler.zig,
  src/layout/ (tag union layout!)
- In-tree reference platforms: test/fx (canonical host), test/int (record
  layout proofs, 11 tests, run: roc --no-cache test/int/app.roc in worktree),
  test/fx-open (RocList building: buildArgsList; main! takes List(Str) and
  returns Try({}, [Exit(I32), ..]) — TAG UNION RETURN host→roc reference!)
- basic-cli branch: ~/Code/roc/basic-cli (on migrate-zig-compiler-edits);
  Roc APIs: platform/{Env,File,IOErr,Path,Random,Sleep,Utc}.roc;
  Rust Try encoding: src/lib.rs (RocTry::ok/err written to ret_ptr)
- Old webserver: ~/Code/roc/basic-webserver

## THE PLAN (phases; 0 starts now)

Phase 0 — ABI groundwork:
  a. Read src/compile/README.md "Host functions" (multi-module ordering rule).
  b. Probe multi-arg hosted fn: e.g. two_args! : Str, U64 => Str and
     write_like! : Str, List(U8) => U64.
  c. Probe tag-union returns from hosted fns: shapes needed by basic-cli APIs:
     - Try(Str, [VarNotFound])            (Env.var!)
     - Try(List(U8), [FileErr(IOErr)])    (File.read_bytes!)
     - Try({}, [FileErr(IOErr)])          (File.write_bytes!)
     IOErr := [NotFound, PermissionDenied, ..., Other(Str)] — check exact
     tags in basic-cli platform/IOErr.roc; discriminants alphabetical.
     Check test/fx-open host for how it writes Try into roc args (reference!)
     and src/layout for tag union memory layout (payload then discriminant,
     padded; verified shape at old pin: disc byte after max-payload bytes).
  d. Record verified layouts here + in the main doc.

Phase 1 — DONE (2026-06-10). Vendored basic-cli APIs verbatim:
  Env.var! : Str => Try(Str, [VarNotFound(Str)])  (Err carries the name —
    host moves the owned arg Str into the Err payload, no decref)
  Env.cwd! : {} => Try(Str, [CwdUnavailable]); Env.exe_path! similar
  Utc.now! : {} => U128 nanos (std.c.clock_gettime; + pure helpers in Utc.roc)
  Sleep.millis! : U64 => {} (std.c.nanosleep; NOTE: holds roc_call_mutex →
    delays ALL handlers, documented in Sleep.roc)
  Random.seed_u64!/seed_u32! : {} => Try(U64/U32, [RandomErr(IOErr)])
    (arc4random_buf, always Ok; pulls in vendored IOErr.roc)
  Gotcha found: platform main.roc must IMPORT every module it exposes,
  else "EXPOSED BUT NOT DEFINED". Hosted table now 9 entries, globally
  alphabetical (Env.cwd, Env.exe_path, Env.var, Random.seed_u32,
  Random.seed_u64, Sleep.millis, Stderr.line, Stdout.line, Utc.now) —
  verified functionally. Demo: examples/app GET /system exercises all of
  them (effectful render_system! in the shell; render stays pure).
  Full battery green: curl set, 100x parallel /system (0.29s, sleeps
  serialize as expected), distinct seeds per request, 0 leaks, graceful
  SIGINT, WS tests still pass (chat + ws-echo).

Phase 2 — DONE (2026-06-10). platform/File.roc vendored verbatim (all 5 fns:
  read_bytes!, write_bytes!, read_utf8!, write_utf8!, delete!), all returning
  Try(T, [FileErr(IOErr)]) = the 40-byte probe shape. Host: libc open/read/
  write/unlink with NUL-terminated path copy (pathZ, 1024 buf →
  ENAMETOOLONG); errno→IOErr via std.c.E switch (darwin: ENOTSUP is
  .OPNOTSUPP); unmapped errnos → Other(strerror). read_utf8 uses
  builtins.str.fromUtf8Lossy (valid-UTF-8 fast path via std.unicode).
  Zig 0.16 note: std.posix.clock_gettime/nanosleep are GONE — use
  std.c.clock_gettime(.REALTIME, &ts) / std.c.nanosleep(&req, &req) + EINTR
  loop; std.ArrayList is unmanaged (.empty / deinit(alloc) / appendSlice(alloc)).
  Hosted table now 14 entries (File.delete..write_utf8 = indices 3-7).
  Demo: examples/app /system "File roundtrip" row (all 5 ops + NotFound
  after delete) and /notes (file-backed add/list/clear, 303 redirects).
  Battery green: 100x parallel /system, 100x concurrent POST /notes → all
  100 lines on disk (roc mutex serializes read-modify-write), 0 leaks,
  graceful SIGINT.

Phase 3 — DONE (2026-06-10). Dir AND Cmd both landed:
  Dir.roc vendored verbatim (create!, create_all!, delete_empty!,
  delete_all!, list!). Host: std.c mkdir/rmdir/opendir/readdir (+ recursive
  deleteTree, symlinks unlinked not followed); list! returns "dir/name"
  paths as host-built List(Str) (RocList.list_allocate with
  elements_refcounted=true, mirroring buildHeadersList).
  Cmd.roc vendored with TWO adaptations (documented in the file):
  (1) top-level hosted decls (host_exec_exit_code!/host_exec_output!) are
  not in scope inside the type body at our pin → moved INSIDE the `.{}` as
  body-less members (mixed hosted + implemented members work, both pure
  AND effectful implemented methods — Cmd proves the full case);
  (2) sibling hosted calls inside methods must use METHOD syntax
  (cmd.host_exec_output!()), bare names don't resolve.
  NESTED TRY ABI VERIFIED: Try(Success48, Try(Failure56, IOErr)) = 72B;
  inner Try: payload@0 max(56,32)=56, disc@56; outer: payload@0
  max(48,inner 64)=64, disc@64. Failure rec: stderr_bytes@0,
  stdout_bytes@24, exit_code i32@48 (basic-cli's "do not change field
  order" comments = alphabetical layout, consistent with our rule).
  Cmd record arg: { args: RocList, envs: RocList, program: RocStr,
  clear_envs: u8 } (align desc, alphabetical). Host: posix_spawnp +
  waitpid (returns errno directly, e.g. ENOENT for a missing program);
  output capture via 2 pipes + poll drain; envp = environ (+/- clear_envs)
  + flattened k=v pairs; arena for argv/envp copies; signal termination →
  Other("terminated by signal N").
  Hosted table now 21 entries (Cmd 0-1, Dir 2-6, Env 7-9, File 10-14,
  Random 15-16, Sleep 17, Stderr 18, Stdout 19, Utc 20).
  Demo: /system "Cmd roundtrip" row (echo capture, exit 42, missing
  program → Err(NotFound), env injection). Battery green incl. 50x
  parallel /system (200 subprocess spawns), 0 leaks, graceful SIGINT.
  Skipped permanently: Tty/Locale/Stdin (server-irrelevant). Path: skipped
  for now — our File/Dir take Str paths (matches basic-cli migrate branch
  File API); revisit only if upstream converges on Path-first APIs.

Phase 4 — convergence: consider nightly-based pinning (matches basic-cli),
  later swap vendored modules for real basic-cli/roc-lang-http packages.

## Verification playbook (run after every change)

1. zig build arm64mac (use $ZIG or ~/zig-0.16.0/zig)
2. roc check + roc test on changed examples
3. ./build.sh app — curl battery: /, /hello/Jörg (urlencoded), /echo?msg=,
   POST /echo, /headers (X-Probe roundtrip), /api/hello (JSON content-type),
   HEAD (no body), OPTIONS (204+Allow), 404, unknown method
4. seq 1 100 | xargs -P 20 curl (expect 100x200, ~0.2s)
5. python3 tests/test_ws_concurrent.py + test_ws_chat.py (against chat example)
6. leaks $(lsof -nP -t -iTCP:8000 -sTCP:LISTEN | tail -1) → 0 leaks
7. kill -INT → "Server stopped gracefully"
8. ALWAYS smoke-test the BUILT binary, not just roc test (backends differ)
