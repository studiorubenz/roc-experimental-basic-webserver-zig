# Creating an Experimental Basic Webserver for the New Roc Compiler

## Status: WORKING (2026-06-09)

```bash
$ ./build.sh          # builds host + runs the server
$ curl http://localhost:8000
<html><body><h1>Hello World!</h1></body></html>
```

The Roc app serves a static HTML page with `Hello World!` built via Roc string
interpolation. The first attempt (March 2026, see git history at 363da77) was
rewritten in June 2026 against the then-current compiler conventions.

## Toolchain (pinned)

Since 2026-06-10 (round 5) everything is pinned to **roc commit `48b28c07`**
(2026-06-09) built with **Zig 0.16.0**:

- Compiler: `~/Code/roc/roc-48b28c07/zig-out/bin/roc` (built from the
  worktree with `~/zig-0.16.0/zig build`; `roc version` →
  `debug-48b28c07`). NOTE: `/usr/local/bin/roc` is still the old
  `ee0fc49d` binary — build.sh uses the pinned path; export
  `ROC=~/Code/roc/roc-48b28c07/zig-out/bin/roc` for ad-hoc commands, or
  install it system-wide when ready.
- Zig 0.16.0 lives at `~/zig-0.16.0/` (0.15.2 stays installed for other
  projects).
- The dependency worktree is `../roc-48b28c07`; the previous
  `../roc-ee0fc49d` worktree still exists and can be removed with
  `git -C ../roc worktree remove ../roc-ee0fc49d` once nothing needs it.

`roc build` now emits via a **checked-artifact LLVM backend** (the dev
backend is no longer what you get), ~same request latency as before.

**Upgrade verification playbook** (used for this migration, keep using it):
run the in-repo `test/int` layout tests with the new binary (11/11 must
pass), re-check syntax conventions against `test/fx/`, then run this
project's `roc test` + curl battery + `leaks` + shutdown test.

**When upgrading again:** add a worktree at the new commit, build the
compiler, update `build.zig.zon` and build.sh, port host.zig if Zig moved.

### Zig 0.16 host-port notes (round 5)

- `std.net` is gone; `std.Thread.Mutex/Condition` moved into the `std.Io`
  overhaul and want an explicit Io instance. The host now uses **libc
  directly**: `std.c` sockets (socket/bind/listen/accept/close/write),
  `std.posix` read/poll/setsockopt/sigaction, and pthread
  mutex/cond (their zig struct defaults equal the static initializers).
- Console output: raw `write(1/2, ...)` — no Io plumbing needed.
- `sigaction` handlers now take `std.posix.SIG` (an enum), not `c_int`.
- Build script: `linkLibC()` became `.link_libc = true` on createModule;
  `std.fs.cwd()` in build steps became `std.Io.Dir.cwd()` + `b.graph.io`.
- roc's build.zig **panics when consumed via `b.dependency`** (reads
  Builtin.roc relative to cwd). Our build.zig therefore constructs the
  builtins module directly: builtins (`src/builtins/mod.zig`) ← tracy
  (`src/build/tracy.zig`) ← an options module with the four tracy flags
  off. Smaller and more robust anyway.
- New hosted-function contract (documented in host_abi.zig now): **hosted
  functions own their refcounted arguments and must decref them** —
  Stdout/Stderr line! gained `defer args.str.decref(ops)`.
- Platform header: targets exe entries are now
  `arm64mac: { files: [...] }` (was a bare list).

### Compiler bugs from ee0fc49d — status at 48b28c07 (all verified by probe)

- record-update incref UAF: **fixed** → upstream roc-lang/http `with_*`
  builders restored; Request/Response re-vendored pristine.
- `List.map` with match-on-list lambda returning records: **fixed**.
- `fold` + `List.append` corruption: **fixed** (split_on/join_with style
  kept in the app because it reads well).
- Lists of tuples zeroed: **fixed** → headers are `List((Str, Str))`
  again, matching upstream.
- Remaining vendored divergence: only `Method.from_str` (upstream gap, to
  be proposed upstream) — and the package still gets vendored because the
  upstream package-header form needs checking against this pin before
  switching to a real package dependency.

## Architecture: handler inversion (since 2026-06-10)

The host owns the TCP listener and the accept loop. The app exports a single
handler that the host calls once per request — the same model as the original
basic-webserver:

```roc
handle! : { method : Str, path : Str, body : Str } => { html : Str, status : U16 }
```

Records cross the host boundary in both directions. This is proven ABI: the
in-repo `test/int` platform passes mixed-alignment records to pure AND
effectful entry points and verifies every field (run it with
`zig build test-platforms && roc --no-cache test/int/app.roc` inside the
pinned worktree — all 11 tests pass at ee0fc49d).

**Record layout rule** (from `test/int/platform/main.roc`): fields are sorted
by alignment descending, then field name alphabetically. Hence on the Zig
side:

```zig
const RocRequest = extern struct {  // all RocStr (align 8) -> alphabetical
    body: RocStr, method: RocStr, path: RocStr,
};
const RocResponse = extern struct { // RocStr (8) before u16 (2)
    html: RocStr, status: u16,
};
```

**String/List ownership:** the handler consumes its argument strings and the
headers list (the generated code decrefs them); the host owns the returned
`html` and must `decref(ops)` it after writing the response. Verified
leak-free (`leaks` reports 0) over hundreds of requests with 100 KB bodies.

**Headers (since 2026-06-10):** the Request record includes
`headers : List({ name : Str, value : Str })`. The host builds it exactly
like `buildArgsList` in `test/fx-open/platform/host.zig`:
`RocList.list_allocate(@alignOf(Elem), count, @sizeOf(Elem), true, ops)`
(elements_refcounted=true because the element records contain RocStrs), then
fills `list.bytes` as `[*]RocHeader`. Element layout follows the same
alignment-then-alphabetical rule (`name` at 0, `value` at 24).

**Request reading (since 2026-06-10):** the host reads until `\r\n\r\n`
(cap 16 KiB), parses all headers (cap 64), then reads the body to exactly
`Content-Length` bytes across as many reads as needed (cap 1 MiB, else a
static 413). No Content-Length means no body.

```
examples/app/main.roc  # Roc app — handle! + pure route/render core
                       # (examples/ holds the apps; more to come)
platform/main.roc   # platform header; handle_for_host! wraps handle!
platform/Stdout.roc # Stdout := [].{ line! }
platform/Stderr.roc # Stderr := [].{ line! }
platform/host.zig   # Zig host: listener, accept loop, calls roc__handle
build.zig           # builds libhost.a into platform/targets/<target>/
build.sh            # zig build arm64mac && roc build examples/app ($APP to pick)
```

The previous app-driven event-loop design (app calls `Http.listen!` /
`accept!` / `respond!` hosted functions) is preserved in git history; it was
replaced because the "current request" host state it relied on can never
support concurrent connections, whereas the handler model can.

## Conventions of the new compiler (as of ee0fc49d)

These changed since the March attempt — all verified against `test/fx`:

- **Module syntax:** `Stdout := [].{ line! : Str => {} }` — `:=`, not `::`.
- **Zero-arg lambdas:** `main! = || { ... }`; requires-clause type is
  `main! : () => {}`.
- **provides symbol naming:** `provides { main_for_host!: "main" }` makes the
  Roc object export `roc__main`; the host declares
  `extern fn roc__main(ops, ret_ptr, arg_ptr)`.
- **Hosted function table:** `RocOps.hosted_fns` entries are type-erased
  `*const fn (*anyopaque, *anyopaque, *anyopaque)`. Write them with concrete
  types and wrap with `builtins.host_abi.hostedFn(&f)`.
- **Hosted function order:** sorted alphabetically by fully-qualified
  `Module.function` name with the `!` stripped (see
  `src/canonicalize/HostedCompiler.zig`). Here:
  `Http.accept`(0), `Http.listen`(1), `Http.respond`(2), `Stderr.line`(3),
  `Stdout.line`(4). All modules imported by `platform/main.roc` contribute,
  whether or not the app uses them.
- **Mutable locals:** `var $x = ...` then `$x = ...`; `while $cond { ... }`
  loops work in effectful functions.
- **Discarding a value:** `_name = expr` (a bare `_ = expr` did not parse in
  the March compiler; unverified since).
- **Strings:** `RocStr.fromSlice(slice, ops)` handles small/large strings;
  `.asSlice()` to read.
- **Multiline strings are Zig-style:** each line starts with `\\`; double
  quotes and `${...}` interpolation work inside; the string ends at the first
  line not starting with `\\`. The `"""` token exists in the tokenizer but
  does NOT protect content lines — using it produces baffling
  `SINGLE QUOTE TOO LONG` / parse errors inside your "string".
- **`roc check` vs `roc run`:** plain `roc app.roc` tolerates parse errors
  (malformed code becomes runtime crashes) and can silently run a stale/cached
  build. Always validate with `roc check` first.
- **Host allocator must track sizes:** Roc's realloc callback does not pass
  the old length. The host stores the total size in a header before each
  allocation (same scheme as `test/fx/platform/host.zig`). A naive
  `rawAlloc`+copy-new-length realloc reads past the old block and dies with
  `@memcpy arguments alias` once string interpolation triggers reallocs.
- **`timeout N roc app.roc` leaks the server:** roc spawns the built app as a
  child process; killing `roc` leaves the child listening on the port
  (`pkill -f main.roc` cleans it up).

## Build & Run

```bash
./build.sh                 # builds host + examples/app, starts server
curl http://localhost:8000
```

Note: Zig runs under Rosetta on this machine, so `zig build native` would
produce x64 — always use the explicit `arm64mac` step.

## Concurrency (since 2026-06-10)

A pool of worker threads (min(cpu count, 8), at least 2) handles connection
I/O in parallel: the acceptor thread pushes accepted sockets into a bounded
queue (cap 64); workers pop, read/parse, call the handler, write, close.
Sockets get 10 s read/write timeouts, so slow or silent clients (slowloris)
only occupy one worker briefly instead of stalling the server.

**The roc__handle call itself is serialized with a host mutex.** At ee0fc49d
every evaluation creates a fresh interpreter, but all instances share the
global constant-strings arena via a by-value state snapshot
(`src/interpreter_shim/main.zig` → `eval/interpreter.zig`,
`constant_strings_arena = arena.*`) — parallel evaluations would write into
the same chunk offsets. Refcounts ARE atomic (`RC_TYPE = .atomic` in
builtins/utils.zig), and host-side RocStr create/decref stays outside the
lock. Revisit the mutex when upstream makes the shim arena thread-safe.

**Run mode vs build mode — this matters enormously:** `roc <app>.roc`
(run mode) evaluates via IPC shared memory with the parent roc process and
costs ~150 ms per handler call; under load the serialized calls queue up and
clients time out. `roc build <app>.roc` produces a standalone `./main`
with the module embedded — ~1 ms per call, >500 req/s with 20 parallel
clients, 0 leaks reported by macOS `leaks`. build.sh therefore uses
`roc build` + `./main`.

## Response side & keep-alive (since 2026-06-10, round 2)

- Response record is `{ body : Str, content_type : Str, headers :
  List({ name, value }), status : U16 }`. The host writes Content-Type and
  the app's headers (skipping any containing CR/LF — header injection), then
  decrefs body, content_type, and the headers list via `RocList.decref` with
  an element-destructor callback (list.zig's `Dec` takes a context pointer —
  pass `ops` through it).
- Keep-alive: workers loop per connection (parse → handle → respond →
  shift pipelined leftover bytes to the buffer front). `Connection: close`
  from the client is honored; idle connections die via the 10 s socket
  timeout. Note: idle keep-alive connections occupy a worker until timeout —
  acceptable at 8 workers for a dev server, a real server would need an
  event loop or idle-connection reaping.
- URL decoding (`%XX` + `+`), HTML escaping and JSON escaping live in pure
  Roc in the app, with `expect` tests (`roc test examples/app/main.roc` — also proof
  that top-level expects work).

**Interpreter bug found (ee0fc49d):** `fold` + `List.append` accumulation
returns a corrupted list (right length, garbage bytes; deterministic).
Wrapping the accumulator in a record sometimes masks it. The compiler repo's
own `test/fx/list_append_stdin_uaf.roc` etc. track this family of bugs.
Workaround used here: build text transforms on `split_on`/`join_with`
(= replace-all) and recursion + `List.concat` — both safe.

**Dev-backend bug found (ee0fc49d):** `List.map` with a lambda that matches
on a list and returns records compiles fine, passes `roc test` (interpreter
backend!) — and panics at runtime ("cast causes pointer to be null") in the
`roc build` dev-codegen binary. The two backends have different bug sets:
`roc test` passing does NOT guarantee the built binary works; always smoke
test the built artifact. Workaround: recursion with list patterns instead of
map-with-complex-lambda (see `find_param` in examples/app/main.roc).

## Round 3 (2026-06-10): query strings, port config, graceful shutdown, HEAD/OPTIONS

- **Query strings:** parsed in pure Roc (`split_query`, `find_param` with
  URL-decoding); `GET /echo?msg=...` works. The path is split before
  routing, so `/route?x=1` matches `/route`.
- **Port:** argv[1] beats `$PORT` beats 8000 (`./main 8123` or
  `PORT=8123 ./main`; build.sh passes arguments through). Read via libc
  `getenv` — `std.posix.getenv` does not work when the host exports its own
  C main (std.os.environ is never populated).
- **Graceful shutdown:** SIGINT/SIGTERM set an atomic flag; the acceptor
  polls the listener with a 500 ms timeout so it notices, then poison-pills
  the queue and joins all workers (in-flight requests finish; responses
  during shutdown send `Connection: close`). Do NOT close the listener fd
  from the signal handler — a blocked accept() then hits EBADF, which is
  `unreachable` in zig's std (panic). Idle keep-alive connections can delay
  drain by up to the 10 s socket timeout.
- **HEAD:** routed like GET in the app; the host suppresses the body but
  keeps Content-Length (RFC 9110). **OPTIONS:** 204 + `Allow` header from
  the app.

## Round 4 (2026-06-10): adopted roc-lang/http types

The app and platform now use the ecosystem's standard HTTP types from
https://github.com/roc-lang/http (migrated to the new compiler by Ian
McLerran). `Method.roc`, `Request.roc`, `Response.roc` are vendored into
`platform/` (UPL-1.0, from commit cc845a2) and exposed by the platform; the
app's handler is `handle! : Request => Response` with `Method` as a nominal
tag union (`Unknown(Str)` catches exotic methods), `uri`, and binary-safe
`List(U8)` bodies. The host boundary still uses flat records (proven ABI);
`handle_for_host!` in platform/main.roc converts both ways.

Vendored-module divergences (all marked in the files, worth upstreaming):

1. `Method.from_str : Str -> Method` added — upstream has `method_str` but
   no inverse, which any server platform needs.
2. Headers are `List({ name : Str, value : Str })` instead of
   `List((Str, Str))` (see bug below).
3. `Request.new` / `Response.new` single-shot constructors added — the
   upstream `with_*` builder API is unusable at ee0fc49d (see bug below).

**Dev-backend bug (the big one):** record update `{ ..rec, field: v }` does
not incref the refcounted fields it copies. The old record is decref'd, the
copied list/string is freed while still referenced, and you get either
silently zeroed data, a host-side `cast causes pointer to be null` panic, or
(in debug builds) `Roc crashed: Use-after-free: incref on already-freed
memory` — depending on what reuses the memory first. Every roc-lang/http
`with_*` builder method is a record update, hence `new`. Symptom checklist
for diagnosing: handler returns a list with plausible length but all-zero
element bytes.

**Also noted:** the upstream package-header form (`package [Method, ...] {}`)
does not resolve module exports at ee0fc49d ("EXPOSED BUT NOT DEFINED") —
the modules work fine when vendored individually. Qualified nominal-tag
construction (`Method.GET` from outside the defining module) is likewise
not supported at this commit; constructor methods inside the type's module
are the working idiom (cf. `test/fx/elem_pkg/Elem.roc`).

## Round 6 (2026-06-10): WebSockets

The platform now requires TWO app functions (multi-entry `requires` works):

```roc
handle! : Request => Response                                            # HTTP
on_ws!  : { message : Str, path : Str } => { broadcast : Str, reply : Str }  # WS
```

Server push (round 7): `reply` goes to the sender only, `broadcast` to every
connected client; empty strings skip. The host keeps a registry of upgraded
sockets (cap 32, refused with close 1013 beyond) and serializes ALL websocket
frame writes behind the registry mutex — without that, two workers
broadcasting at once would interleave frame bytes on a shared destination.
Worker pool grew to min(2x cores, 16) since each WS connection occupies one.
`examples/chat` is the broadcast demo (name\ttext wire format, HTML-escaped
in Roc, multi-tab chat). `examples/websocket-elm` is the same protocol with
an Elm 0.19 frontend (ports for the socket); build.sh compiles Main.elm
when present and the bundle is embedded via an ingested import
(`import "elm.js" as elm_js : Str` — ingested files work at 48b28c07) and
served from memory.

The host owns the protocol (RFC 6455): it detects `Upgrade: websocket` +
`Sec-WebSocket-Key`, answers the 101 handshake (SHA-1 + base64 accept key
via std.crypto/std.base64), then runs a frame loop on the worker thread —
unmasking client frames, answering pings with pongs, echoing close frames.
For every complete text frame it calls `roc__ws_message` (under the same
roc mutex) and sends the returned Str back as a text frame.

Keepalive/drain: 5 s read timeout on upgraded sockets; on idle the host
pings once — clients that answer pongs (all browsers) stay connected
indefinitely, dead peers drop after ~10 s, and graceful shutdown drains
idle WS connections in a few seconds (close code 1001).

Limitations: text frames only (binary → close 1003), no fragmented
messages (→ 1009), 64 KiB max payload (→ 1009). Push is broadcast-to-all
only — per-client targeting would need client identities crossing the Roc
boundary. Each WS connection occupies a worker thread (pool of up to 16).

Verified with a raw-socket Python client: handshake accept-key check, echo
and command round-trips, ping→pong, clean close, 4 concurrent clients ×20
messages, 0 leaks, 3 s graceful shutdown with an idle connection open.
`examples/ws-echo` is the demo app (browser chat UI; `/upper`, `/reverse`,
`/count`, `/help`).

## Round 9 (2026-06-10): the I/O port — Env, Utc, Sleep, Random, File, Dir, Cmd

The platform now speaks most of basic-cli's effect vocabulary. Strategy
(after researching upstream): do NOT duplicate the active Rust-host port of
basic-cli (roc-lang/basic-cli, branches migrate-zig-compiler*, by Anton-4
and Luke Boswell); instead vendor basic-cli's module APIs verbatim into our
Zig host so apps stay API-compatible. Working notes, verified ABI layouts
and the phase log live in IO-PORT-PLAN.md.

New platform modules (all vendored from basic-cli, signatures unchanged):
Env (var!/cwd!/exe_path!), Utc (now! + pure helpers), Sleep (millis!),
Random (seed_u64!/seed_u32!), IOErr, File (read_bytes!/write_bytes!/
read_utf8!/write_utf8!/delete!), Dir (create!/create_all!/delete_empty!/
delete_all!/list!), Cmd (builder API + exec!/exec_output!/exec_exit_code!
etc.). Skipped as server-irrelevant: Stdin, Tty, Locale; Path deferred
(our File/Dir take Str paths, matching the basic-cli migrate branch).

A Phase 0 probe platform (/tmp/ioprobe) proved the remaining unknown ABI in
both directions before any real code: multi-arg hosted functions (args =
extern struct, alignment desc then positional), and tag unions across the
boundary — Try payload at offset 0, discriminant byte after the max
payload, tags alphabetical (Err=0/Ok=1), single-tag wrappers like
[FileErr(IOErr)] transparent. Also: at this pin RocStr stores
capacity-shifted-left-by-one at offset 8 and the LENGTH at offset 16 —
always use builtins.str.RocStr, never hand-rolled structs. Cmd later
proved nested Trys: Try(Success, Try(Failure, IOErr)) = 72 bytes with two
discriminants (@56 inner, @64 outer).

Host side: pure libc (getenv/getcwd/_NSGetExecutablePath, clock_gettime,
nanosleep, arc4random_buf, open/read/write/unlink, mkdir/rmdir/opendir/
readdir, posix_spawnp + waitpid + pipes/poll for Cmd), errno → IOErr via a
std.c.E switch (unmapped → Other(strerror)). The hosted-function table is
21 entries, sorted globally alphabetically by Module.fn — getting this
order wrong fails SILENTLY, so every entry is exercised by the demo.
Ownership: hosted fns decref their refcounted args; one elegant case:
Env.var! on a missing variable moves the owned name Str into the
Err(VarNotFound(name)) payload instead of decreffing.

Vendoring gotchas at our pin (documented inline in Cmd.roc): top-level
hosted declarations aren't in scope inside a type body — declare them as
body-less members of the `.{}` instead (mixed hosted + implemented
members work, including effectful implemented methods); and sibling
hosted calls inside methods need method syntax (cmd.host_exec_output!()).
Platform main.roc must import every module it exposes.

Demos in examples/app: GET /system runs every effect (env vars, time,
sleep timing, random seeds, a full File write/read/append/delete
roundtrip, a Dir create_all/list/delete_all roundtrip, and a Cmd block —
echo capture, exit 42, missing program → Err(NotFound), env injection);
/notes is file-backed persistence (add/list/clear with 303 redirects).
Battery: 100 parallel /system requests, 100 concurrent POST /notes (all
100 lines land — the roc mutex serializes read-modify-write), WS suites
still green, 0 leaks after hundreds of effectful requests and 200
subprocess spawns, graceful SIGINT.

## Round 10 (2026-06-10): maintainer feedback — `?` style, mutex removed, realloc tidied

Anton (roc core) reviewed the published repo. Three changes followed:

1. **`?` instead of match pyramids.** The /system roundtrips and seed
   handling now use happy-path `?` propagation through small `try_*`
   functions. Lesson learned: `?` early-returns carry the CALLEE's error
   union, and the vendored File/Dir signatures have CLOSED unions — so a
   `?` chain must stay within one module's error type (Cmd works across
   steps because its signatures end in `, ..`). Semantic checks report
   through the Ok branch.

2. **The roc-call mutex is gone.** It was an interpreter-era relic;
   compiled artifacts have no shared mutable state. Verified without it:
   500-request parallel battery incl. File/Dir/Cmd effects, WS suites,
   0 leaks. 200 effectful requests now take 0.72 s (the per-request 2 ms
   sleeps used to serialize). Consequences honestly handled: app-level
   read-modify-write is now genuinely racy (measured 41/100 surviving
   concurrent /notes appends — documented in the example), and /system
   probes use unique per-request temp paths.

3. **Realloc copies user data only** (style sync with
   lukewilliamboswell/roc-platform-template-zig — same size-header scheme,
   ours previously copied header+data then overwrote the header; equivalent
   but less clear).

## Known limitations

- Handler execution is serialized (see above) — parallel I/O, sequential Roc.
  Revisit when upstream interpreter state becomes thread-safe.
- No chunked transfer encoding, no TLS. Headers cap 16 KiB / 64 entries;
  body cap 1 MiB (413 beyond).
- Server binds 127.0.0.1 only.
- Idle keep-alive connections each occupy a worker until the 10 s timeout.
