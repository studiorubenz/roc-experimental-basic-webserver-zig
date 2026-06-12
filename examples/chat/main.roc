app [handle!, on_ws!] { pf: platform "../../platform/main.roc" }

import pf.Stdout
import pf.Request exposing [Request]
import pf.Response exposing [Response]
import "chat.html" as chat_page : Str

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
## `&` must be first, or it would double-escape the `&` in `&lt;` etc.
escape_html : Str -> Str
escape_html = |input|
    input
        ->replace_all("&", "&amp;")
        ->replace_all("<", "&lt;")
        ->replace_all(">", "&gt;")
        ->replace_all("\"", "&quot;")
        ->replace_all("'", "&#39;")

replace_all : Str, Str, Str -> Str
replace_all = |haystack, needle, replacement|
    haystack.split_on(needle).join_with(replacement)

expect route_message("ada", "hi <all>").broadcast == "<b>ada:</b> hi &lt;all&gt;"
expect route_message("ada", "/me waves").broadcast == "* ada waves"
expect route_message("ada", "/help").broadcast == ""
