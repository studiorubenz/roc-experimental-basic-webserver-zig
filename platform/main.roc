platform ""
    requires {
        handle! : Request => Response,
        on_ws! : { message : Str, path : Str } => { broadcast : Str, reply : Str }
    }
    exposes [Stdout, Stderr, Method, Request, Response, Cmd, Dir, Env, File, IOErr, Random, Sleep, Utc]
    packages {}
    provides { handle_for_host!: "handle", ws_for_host!: "ws_message" }
    targets: {
        files: "targets/",
        exe: {
            x64mac: { files: ["libhost.a", app] },
            arm64mac: { files: ["libhost.a", app] },
            x64musl: { files: ["crt1.o", "libhost.a", app, "libc.a"] },
            arm64musl: { files: ["crt1.o", "libhost.a", app, "libc.a"] },
        }
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
