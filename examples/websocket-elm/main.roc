app [handle!, on_ws!] { pf: platform "../../platform/main.roc" }

import pf.Stdout
import pf.Request exposing [Request]
import pf.Response exposing [Response]

# The compiled Elm app, embedded at build time (build.sh runs `elm make`
# before `roc build`). No file IO needed at runtime.
import "elm.js" as elm_js : Str

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
            Response.from_status(200)
                .with_headers([("Content-Type", "application/javascript; charset=utf-8")])
                .with_body(elm_js.to_utf8())
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
    Stdout.line!("ws: ${frame.message}")
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

# -- Page ------------------------------------------------------------------------
# Just the Elm mount point and the WebSocket/port glue (Elm 0.19 has no
# built-in WebSockets). Plain JS: Roc multiline strings interpolate ${...},
# so no JS template literals in here.

page : Str
page =
    \\<html lang="en">
    \\<head>
    \\    <meta charset="utf-8">
    \\    <title>Roc + Elm chat</title>
    \\    <script src="/elm.js"></script>
    \\</head>
    \\<body>
    \\    <div id="app"></div>
    \\    <script>
    \\    var app = Elm.Main.init({ node: document.getElementById("app") });
    \\    var ws = new WebSocket("ws://" + location.host + "/ws");
    \\    ws.onopen = function () { app.ports.socketState.send(true); };
    \\    ws.onclose = function () { app.ports.socketState.send(false); };
    \\    ws.onmessage = function (event) { app.ports.messageReceived.send(event.data); };
    \\    app.ports.sendMessage.subscribe(function (message) { ws.send(message); });
    \\    </script>
    \\</body>
    \\</html>
