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

# -- WebSocket: one reply per text message --------------------------------------

## Commands: /upper TEXT, /reverse TEXT, /count TEXT — anything else echoes.
## Everything is a private reply to the sender; see examples/chat for broadcast.
on_ws! : { message : Str, path : Str } => { broadcast : Str, reply : Str }
on_ws! = |frame| {
    Stdout.line!("ws ${frame.path}: ${frame.message}")
    { broadcast: "", reply: answer(frame.message) }
}

answer : Str -> Str
answer = |message|
    if message.starts_with("/upper ") {
        ascii_upper(message.drop_prefix("/upper "))
    } else if message.starts_with("/reverse ") {
        reverse_words(message.drop_prefix("/reverse "))
    } else if message.starts_with("/count ") {
        text = message.drop_prefix("/count ")
        words = text.split_on(" ").len()
        bytes = text.to_utf8().len()
        "${words.to_str()} word(s), ${bytes.to_str()} byte(s)"
    } else if message == "/help" {
        "commands: /upper TEXT, /reverse TEXT, /count TEXT — anything else is echoed"
    } else {
        "echo: ${message}"
    }

ascii_upper : Str -> Str
ascii_upper = |text| {
    upped = text.to_utf8().map(|byte|
        if byte >= 'a' and byte <= 'z' {
            byte - 32
        } else {
            byte
        })
    Str.from_utf8_lossy(upped)
}

reverse_words : Str -> Str
reverse_words = |text|
    prepend_words(text.split_on(" "), []).join_with(" ")

prepend_words : List(Str), List(Str) -> List(Str)
prepend_words = |remaining, reversed|
    match remaining {
        [] => reversed
        [word, .. as rest] => prepend_words(rest, [word].concat(reversed))
    }

expect ascii_upper("hello Jörg!") == "HELLO Jörg!"
expect reverse_words("one two three") == "three two one"

# -- Page ------------------------------------------------------------------------
# (Plain JS on purpose: Roc multiline strings interpolate ${...}, so no JS
# template literals in here.)

chat_page : Str
chat_page =
    \\<html lang="en">
    \\<head>
    \\    <meta charset="utf-8">
    \\    <title>Roc WebSocket echo</title>
    \\</head>
    \\<body>
    \\    <h1>Roc WebSocket echo</h1>
    \\    <p>Try <code>/help</code>, <code>/upper roc</code>, <code>/reverse one two three</code>, <code>/count some words</code>.</p>
    \\    <ul id="log"></ul>
    \\    <form onsubmit="send(); return false;">
    \\        <input id="msg" autocomplete="off" placeholder="Say something...">
    \\        <button>Send</button>
    \\    </form>
    \\    <script>
    \\    var ws = new WebSocket("ws://" + location.host + "/ws");
    \\    ws.onopen = function () { add("[connected]"); };
    \\    ws.onclose = function () { add("[disconnected]"); };
    \\    ws.onmessage = function (event) { add("server: " + event.data); };
    \\    function add(line) {
    \\        var item = document.createElement("li");
    \\        item.textContent = line;
    \\        document.getElementById("log").appendChild(item);
    \\    }
    \\    function send() {
    \\        var input = document.getElementById("msg");
    \\        if (input.value === "") { return; }
    \\        add("you: " + input.value);
    \\        ws.send(input.value);
    \\        input.value = "";
    \\    }
    \\    </script>
    \\</body>
    \\</html>
