app [handle!, on_ws!] { pf: platform "../../platform/main.roc" }

import pf.Stdout
import pf.Request exposing [Request]
import pf.Response exposing [Response]
import "page.html" as chat_page : Str

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
    # dbg rather than Stdout: stripped from optimized builds, so it can't
    # slow down benchmarks.
    dbg frame
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
