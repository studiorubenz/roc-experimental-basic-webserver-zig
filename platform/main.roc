platform ""
    requires {
        handle! : Request => Response,
        on_ws! : { message : Str, path : Str } => { broadcast : Str, reply : Str }
    }
    exposes [Stdout, Stderr, Method, Request, Response, Cmd, Dir, Env, File, IOErr, Random, Sleep, Utc]
    packages {}
    provides { "roc_handle": handle_for_host!, "roc_ws_message": ws_for_host! }
    hosted {
        "roc_cmd_host_exec_exit_code": Cmd.host_exec_exit_code!,
        "roc_cmd_host_exec_output": Cmd.host_exec_output!,
        "roc_dir_create": Dir.create!,
        "roc_dir_create_all": Dir.create_all!,
        "roc_dir_delete_all": Dir.delete_all!,
        "roc_dir_delete_empty": Dir.delete_empty!,
        "roc_dir_list": Dir.list!,
        "roc_env_cwd": Env.cwd!,
        "roc_env_exe_path": Env.exe_path!,
        "roc_env_var": Env.var!,
        "roc_file_delete": File.delete!,
        "roc_file_read_bytes": File.read_bytes!,
        "roc_file_read_utf8": File.read_utf8!,
        "roc_file_write_bytes": File.write_bytes!,
        "roc_file_write_utf8": File.write_utf8!,
        "roc_random_seed_u32": Random.seed_u32!,
        "roc_random_seed_u64": Random.seed_u64!,
        "roc_sleep_millis": Sleep.millis!,
        "roc_stderr_line": Stderr.line!,
        "roc_stdout_line": Stdout.line!,
        "roc_utc_now": Utc.now!,
    }
    targets: {
        inputs: "targets/",
        x64mac: { inputs: ["libhost.a", app] },
        arm64mac: { inputs: ["libhost.a", app] },
        x64musl: { inputs: ["crt1.o", "libhost.a", app, "libc.a"] },
        arm64musl: { inputs: ["crt1.o", "libhost.a", app, "libc.a"] },
    }

import Stdout
import Stderr
import Cmd
import Dir
import Env
import File
import IOErr
import Random
import Sleep
import Utc
import Method exposing [Method]
import Request exposing [Request]
import Response exposing [Response]

## The flat record types crossing the host boundary (proven ABI: records of
## Str/List/U16). The nominal Request/Response types from roc-lang/http are
## built/unpacked on the Roc side of the fence.
handle_for_host! : { body : List(U8), headers : List((Str, Str)), method : Str, uri : Str } => { body : List(U8), headers : List((Str, Str)), status : U16 }
handle_for_host! = |raw| {
    request = Request.from_method(Method.from_str(raw.method))
        .with_uri(raw.uri)
        .with_headers(raw.headers)
        .with_body(raw.body)

    response = handle!(request)

    {
        body: response.body(),
        headers: response.headers(),
        status: response.status(),
    }
}

## Called by the host for every WebSocket text message. `reply` is sent to
## the sender only, `broadcast` to every connected client (including the
## sender); an empty string skips that send. The host owns handshake,
## framing and the client registry.
ws_for_host! : { message : Str, path : Str } => { broadcast : Str, reply : Str }
ws_for_host! = |frame| on_ws!(frame)
