app [handle!, on_ws!] { pf: platform "../../platform/main.roc" }

import pf.Stdout
import pf.Request exposing [Request]
import pf.Response exposing [Response]

# -- HTTP: serve the chat page --------------------------------------------------

handle! : Request => Response
handle! = |request| {
    Stdout.line!("${request.method_str()} ${request.uri()}")
    match request.uri() {
        "/" =>
            Response.from_status(200)
                .with_headers([("Content-Type", "text/html; charset=utf-8")])
                .with_body(chat_page.to_utf8())
        _ =>
            Response.from_status(404)
                .with_headers([("Content-Type", "text/plain")])
                .with_body("not found — try /".to_utf8())
    }
}

# -- WebSocket: broadcast chat ----------------------------------------------------
#
# The client sends "name\ttext" (tab-separated; the page does this). Plain
# chat lines are broadcast to everyone; /-commands get a private reply.

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
    if text == "/help" {
        { broadcast: "", reply: "commands: /help, /me ACTION — anything else is sent to everyone" }
    } else if text.starts_with("/me ") {
        { broadcast: "* ${escape_html(name)} ${escape_html(text.drop_prefix("/me "))}", reply: "" }
    } else if text == "/joined" {
        { broadcast: "* ${escape_html(name)} joined the chat", reply: "welcome, ${escape_html(name)}! type /help for commands" }
    } else {
        { broadcast: "<b>${escape_html(name)}:</b> ${escape_html(text)}", reply: "" }
    }

## Escape &, <, >, " and ' — chat text is rendered as HTML on the page.
escape_html : Str -> Str
escape_html = |input| {
    amp = replace_all(input, "&", "&amp;")
    lt = replace_all(amp, "<", "&lt;")
    gt = replace_all(lt, ">", "&gt;")
    quot = replace_all(gt, "\"", "&quot;")
    replace_all(quot, "'", "&#39;")
}

replace_all : Str, Str, Str -> Str
replace_all = |haystack, needle, replacement|
    haystack.split_on(needle).join_with(replacement)

expect route_message("ada", "hi <all>").broadcast == "<b>ada:</b> hi &lt;all&gt;"
expect route_message("ada", "/me waves").broadcast == "* ada waves"
expect route_message("ada", "/help").broadcast == ""

# -- Page ------------------------------------------------------------------------
# (Plain JS on purpose: Roc multiline strings interpolate ${...}, so no JS
# template literals in here. Server output is HTML-escaped in Roc and
# rendered via innerHTML so <b>name:</b> formatting works.)

chat_page : Str
chat_page =
    \\<html lang="en">
    \\<head>
    \\    <meta charset="utf-8">
    \\    <title>Roc chat</title>
    \\</head>
    \\<body>
    \\    <h1>Roc chat</h1>
    \\    <p>Open this page in several tabs and chat between them. <code>/help</code> for commands.</p>
    \\    <ul id="log"></ul>
    \\    <form onsubmit="send(); return false;">
    \\        <input id="msg" autocomplete="off" placeholder="Say something...">
    \\        <button>Send</button>
    \\    </form>
    \\    <script>
    \\    var name = "";
    \\    while (name === "") { name = (prompt("Your name?") || "").trim(); }
    \\    var ws = new WebSocket("ws://" + location.host + "/ws");
    \\    ws.onopen = function () { ws.send(name + "\t/joined"); };
    \\    ws.onclose = function () { add("[disconnected]"); };
    \\    ws.onmessage = function (event) { add(event.data); };
    \\    function add(html) {
    \\        var item = document.createElement("li");
    \\        item.innerHTML = html;
    \\        document.getElementById("log").appendChild(item);
    \\    }
    \\    function send() {
    \\        var input = document.getElementById("msg");
    \\        if (input.value === "") { return; }
    \\        ws.send(name + "\t" + input.value);
    \\        input.value = "";
    \\    }
    \\    </script>
    \\</body>
    \\</html>
