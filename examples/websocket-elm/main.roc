app [handle!, on_ws!] { pf: platform "../../platform/main.roc" }

import pf.Stdout
import pf.File
import pf.Request exposing [Request]
import pf.Response exposing [Response]
import "page.html" as page : Str

# The compiled Elm bundle is read from disk per request (the server runs
# from the repo root, hence the examples/... path). Re-run `elm make` and
# refresh the browser — no server rebuild needed. Before the platform had
# File I/O this was embedded at build time via an ingested import
# (`import "elm.js" as elm_js : Str`), which also works.
elm_js_path : Str
elm_js_path = "examples/websocket-elm/elm.js"

# -- HTTP: serve the page and the embedded Elm bundle ---------------------------

handle! : Request => Response
handle! = |request| {
    Stdout.line!("${request.method_str()} ${request.uri()}")
    match request.uri() {
        "/" =>
            Response.from_status(200)
                .with_headers([("Content-Type", "text/html; charset=utf-8")])
                .with_body(page.to_utf8())
        "/elm.js" =>
            match File.read_bytes!(elm_js_path) {
                Ok(bytes) =>
                    Response.from_status(200)
                        .with_headers([("Content-Type", "application/javascript; charset=utf-8")])
                        .with_body(bytes)
                Err(FileErr(_)) =>
                    Response.from_status(503)
                        .with_headers([("Content-Type", "text/plain")])
                        .with_body("elm.js missing — run: cd examples/websocket-elm && elm make src/Main.elm --output=elm.js --optimize".to_utf8())
            }
        _ =>
            Response.from_status(404)
                .with_headers([("Content-Type", "text/plain")])
                .with_body("not found — try /".to_utf8())
    }
}

# -- WebSocket: broadcast chat, plain-text protocol ------------------------------
#
# Same "name<TAB>text" wire format as examples/chat, but everything stays
# plain text: Elm renders messages as text nodes, so no HTML escaping is
# needed anywhere.

on_ws! : { message : Str, path : Str } => { broadcast : Str, reply : Str }
on_ws! = |frame| {
    # dbg rather than Stdout: stripped from optimized builds, so it can't
    # slow down benchmarks.
    dbg frame.message
    match frame.message.split_on("\t") {
        [name, text] => route_message(name, text)
        _ => { broadcast: "", reply: "malformed message (expected name<TAB>text)" }
    }
}

route_message : Str, Str -> { broadcast : Str, reply : Str }
route_message = |name, text|
    if text == "/joined" {
        { broadcast: "* ${name} joined the chat", reply: "welcome, ${name}!" }
    } else if text == "/help" {
        { broadcast: "", reply: "commands: /help, /me ACTION — anything else is sent to everyone" }
    } else if text.starts_with("/me ") {
        { broadcast: "* ${name} ${text.drop_prefix("/me ")}", reply: "" }
    } else {
        { broadcast: "${name}: ${text}", reply: "" }
    }

expect route_message("ada", "hi there").broadcast == "ada: hi there"
expect route_message("ada", "/joined").broadcast == "* ada joined the chat"
expect route_message("ada", "/help").broadcast == ""
