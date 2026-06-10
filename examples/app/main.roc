app [handle!, on_ws!] { pf: platform "../../platform/main.roc" }

import pf.Stdout
import pf.Cmd
import pf.Dir
import pf.Env
import pf.IOErr exposing [IOErr]
import pf.File
import pf.Random
import pf.Sleep
import pf.Utc
import pf.Request exposing [Request]
import pf.Response exposing [Response]

# -- Types --------------------------------------------------------------------

Route : [
    Home,
    Greet(Str),
    Echo(Str),
    ShowHeaders(List((Str, Str))),
    ApiHello(Str),
    System,
    Notes,
    AddNote(Str),
    ClearNotes,
    Options,
    NotFound(Str, Str),
]

# -- Effectful shell ----------------------------------------------------------

## Called by the host once per incoming HTTP request.
handle! : Request => Response
handle! = |request| {
    Stdout.line!("${request.method_str()} ${request.uri()}")
    match route(request) {
        # Routes that run platform effects render in the effectful shell;
        # everything else renders purely.
        System => render_system!({})
        Notes => render_notes!({})
        AddNote(text) => add_note!(text)
        ClearNotes => clear_notes!({})
        other => render(other)
    }
}

## Demo page for the platform effects: Env, Utc, Sleep, Random, File, Dir, Cmd.
render_system! : {} => Response
render_system! = |{}| {
    match system_rows!({}) {
        Ok(rows) => html_response(200, "System", headers_table(rows))
        Err(_) => html_response(500, "System", "<p>a system probe failed unexpectedly</p>")
    }
}

## Gather one table row per effect. Happy-path style: `?` propagates any
## unexpected error to render_system!'s single match above.
system_rows! : {} => Try(List((Str, Str)), [RandomErr(IOErr)])
system_rows! = |{}| {
    start = Utc.now!({})

    # These two matches are deliberate, not pyramid debt: the page exists to
    # SHOW both branches of Env.var! (a set and an unset variable).
    home = match Env.var!("HOME") {
        Ok(value) => value
        Err(VarNotFound(name)) => "Err(VarNotFound(${name}))"
    }
    missing = match Env.var!("SURELY_NOT_SET_XYZ") {
        Ok(value) => value
        Err(VarNotFound(name)) => "Err(VarNotFound(${name}))"
    }
    cwd = Env.cwd!({}) ?? "(unavailable)"
    exe = Env.exe_path!({}) ?? "(unavailable)"
    seed_64 = Random.seed_u64!({})?
    seed_32 = Random.seed_u32!({})?
    # Handlers run in parallel, so each request probes its own temp paths
    # (a shared path would race with concurrent /system requests).
    unique = seed_64.to_str()

    Sleep.millis!(2)
    end = Utc.now!({})

    Ok([
        ("File roundtrip", file_roundtrip!(unique)),
        ("Dir roundtrip", dir_roundtrip!(unique)),
        ("Cmd roundtrip", cmd_roundtrip!({})),
        ("Utc.now! (nanos since epoch)", start.to_str()),
        ("Utc.to_millis_since_epoch", Utc.to_millis_since_epoch(start).to_str()),
        ("Env.var!(\"HOME\")", home),
        ("Env.var! on an unset name", missing),
        ("Env.cwd!", cwd),
        ("Env.exe_path!", exe),
        ("Random.seed_u64!", seed_64.to_str()),
        ("Random.seed_u32!", seed_32.to_str()),
        ("Sleep.millis!(2), measured", "${Utc.delta_as_nanos(start, end).to_str()} ns"),
    ])
}

## Exercise all five File operations against a temp file.
file_roundtrip! : Str => Str
file_roundtrip! = |unique| {
    match try_file_roundtrip!(unique) {
        Ok(message) => message
        Err(FileErr(_)) => "a File operation FAILED"
    }
}

## Happy-path style: every step shares File's error union, so `?` can
## propagate it; the semantic checks report through the Ok branch. (Mixing
## FileErr and DirErr steps in one `?` chain would need open `..` unions,
## which the vendored basic-cli signatures don't have.)
try_file_roundtrip! : Str => Try(Str, [FileErr(IOErr)])
try_file_roundtrip! = |unique| {
    path = "/tmp/roc-webserver-system-probe-${unique}.txt"
    File.write_utf8!(path, "round trip äöü")?
    bytes = File.read_bytes!(path)?
    File.write_bytes!(path, bytes.concat(" + bytes".to_utf8()))?
    content = File.read_utf8!(path)?
    if content != "round trip äöü + bytes" {
        Ok("content mismatch: ${content}")
    } else {
        File.delete!(path)?
        match File.read_utf8!(path) {
            Err(FileErr(NotFound)) => Ok("write/read/append/delete OK, NotFound after delete OK")
            Err(FileErr(_)) => Ok("deleted, but re-read gave an unexpected error")
            Ok(_) => Ok("file still exists after delete!")
        }
    }
}

## Exercise the Cmd API: output capture, exit codes, spawn failure, env vars.
cmd_roundtrip! : {} => Str
cmd_roundtrip! = |{}| {
    match try_cmd_roundtrip!({}) {
        Ok(message) => message
        Err(_) => "a Cmd operation FAILED"
    }
}

try_cmd_roundtrip! : {} => Try(Str, _)
try_cmd_roundtrip! = |{}| {
    output = Cmd.new("echo").args(["hello", "subprocess"]).exec_output!()?
    exit_code = Cmd.new("sh").args(["-c", "exit 42"]).exec_exit_code!()?

    # This match is the point of the row: we EXPECT the Err branch here.
    missing = match Cmd.new("definitely-not-a-program-xyz").exec_output!() {
        Err(FailedToGetExitCode({ command: _, err: NotFound })) => "Err(NotFound)"
        Err(_) => "some other error"
        Ok(_) => "unexpectedly Ok"
    }

    env_check = Cmd.new("sh").args(["-c", "echo $CMD_PROBE"]).env("CMD_PROBE", "env works").exec_output!()?
    Ok("echo -> ${output.stdout_utf8.trim()}; exit 42 -> ${exit_code.to_str()}; missing program -> ${missing}; ${env_check.stdout_utf8.trim()}")
}

## Exercise all five Dir operations against a temp tree.
dir_roundtrip! : Str => Str
dir_roundtrip! = |unique| {
    match try_dir_roundtrip!(unique) {
        Ok(message) => message
        Err(DirErr(_)) => "a Dir operation FAILED"
    }
}

try_dir_roundtrip! : Str => Try(Str, [DirErr(IOErr)])
try_dir_roundtrip! = |unique| {
    base = "/tmp/roc-webserver-dir-probe-${unique}"
    nested = "${base}/a/b"
    Dir.create_all!(nested)?
    Dir.create!("${nested}/c")?
    Dir.create!("${nested}/d")?
    entries = Dir.list!(nested)?
    if entries.len() != 2 {
        Ok("list expected 2 entries, got ${entries.len().to_str()}")
    } else {
        Dir.delete_empty!("${nested}/c")?
        Dir.delete_all!(base)?
        match Dir.list!(base) {
            Err(DirErr(NotFound)) => Ok("create_all/create/list/delete_empty/delete_all OK, NotFound after delete_all OK")
            _ => Ok("directory still listable after delete_all!")
        }
    }
}

# -- Notes: file-backed persistence demo ------------------------------------------

notes_path : Str
notes_path = "notes.txt"

## Show the notes stored on disk; a missing file is just an empty list.
render_notes! : {} => Response
render_notes! = |{}| {
    notes = match File.read_utf8!(notes_path) {
        Ok(content) => content
        Err(FileErr(_)) => ""
    }
    items = notes
        .split_on("\n")
        .keep_if(|line| line != "")
        .map(|line| "<li>${escape_html(line)}</li>")
        .join_with("")
    listing = if items == "" { "<p>No notes yet.</p>" } else { "<ul>${items}</ul>" }
    content =
        \\${listing}
        \\<form method="post" action="/notes">
        \\    <input name="note" placeholder="Add a note..." autofocus>
        \\    <button>Add</button>
        \\</form>
        \\<form method="post" action="/notes/clear">
        \\    <button>Clear all notes</button>
        \\</form>
    html_response(200, "Notes", content)
}

## Append one note line to the file, then redirect back to /notes.
## Honest caveat: handlers run in parallel, so two simultaneous posts can
## race this read-modify-write and one note can be lost. Durable designs
## use one file per record (unique names) instead of one shared file.
add_note! : Str => Response
add_note! = |text| {
    if text.trim() == "" {
        redirect_to_notes
    } else {
        existing = match File.read_utf8!(notes_path) {
            Ok(content) => content
            Err(FileErr(_)) => ""
        }
        line = text.trim().split_on("\n").join_with(" ")
        match File.write_utf8!(notes_path, "${existing}${line}\n") {
            Ok({}) => redirect_to_notes
            Err(FileErr(_)) => html_response(500, "Error", "<p>Could not save the note.</p>")
        }
    }
}

clear_notes! : {} => Response
clear_notes! = |{}| {
    # Deleting a file that never existed is fine for "clear".
    match File.delete!(notes_path) {
        Ok({}) | Err(FileErr(NotFound)) => redirect_to_notes
        Err(FileErr(_)) => html_response(500, "Error", "<p>Could not clear the notes.</p>")
    }
}

redirect_to_notes : Response
redirect_to_notes =
    Response.from_status(303)
        .with_headers([("Location", "/notes")])

## This example doesn't use WebSockets — see examples/ws-echo and examples/chat.
on_ws! : { message : Str, path : Str } => { broadcast : Str, reply : Str }
on_ws! = |_frame| {
    broadcast: "",
    reply: "This example does not speak WebSocket. Try examples/ws-echo or examples/chat.",
}

# -- Routing ------------------------------------------------------------------

route : Request -> Route
route = |request| {
    url = split_query(request.uri())
    # HEAD routes like GET; the host suppresses the response body.
    method = match request.method() {
        HEAD => GET
        other => other
    }
    match (method, url.path) {
        (GET, "/") => Home
        (GET, "/headers") => ShowHeaders(request.headers())
        (GET, "/system") => System
        (GET, "/notes") => Notes
        (POST, "/notes") => AddNote(url_decode(Str.from_utf8_lossy(request.body()).drop_prefix("note=")))
        (POST, "/notes/clear") => ClearNotes
        (GET, "/echo") => Echo(query_message(url.query))
        (GET, path) if path.starts_with("/api/hello/") => ApiHello(url_decode(path.drop_prefix("/api/hello/")))
        (GET, path) if path.starts_with("/hello/") => Greet(url_decode(path.drop_prefix("/hello/")))
        (POST, "/echo") => Echo(url_decode(Str.from_utf8_lossy(request.body()).drop_prefix("msg=")))
        (OPTIONS, _) => Options
        (_, path) => NotFound(request.method_str(), path)
    }
}

render : Route -> Response
render = |current_route|
    match current_route {
        Home => html_response(200, "Hello from Roc!", home_content)
        Greet(name) => html_response(200, "Hello ${escape_html(name)}!", "<p>Lovely to meet you, ${escape_html(name)}.</p>")
        Echo(message) => html_response(200, "You said:", "<pre>${escape_html(message)}</pre>")
        ShowHeaders(headers) => html_response(200, "Your request headers", headers_table(headers))
        ApiHello(name) => json_response("{ \"hello\": \"${json_escape(name)}\" }")
        # Effectful routes are handled in the shell (see handle!).
        System | Notes | AddNote(_) | ClearNotes => html_response(500, "unreachable", "")
        Options =>
            Response.from_status(204)
                .with_headers([("Allow", "GET, POST, HEAD, OPTIONS")])
        NotFound(method, path) => html_response(404, "404 Not Found", "<p>No route for ${escape_html(method)} ${escape_html(path)}</p>")
    }

# -- Response builders ----------------------------------------------------------

html_response : U16, Str, Str -> Response
html_response = |status, title, content|
    Response.from_status(status)
        .with_headers([("Content-Type", "text/html; charset=utf-8"), ("X-Powered-By", "Roc")])
        .with_body(page(title, content).to_utf8())

json_response : Str -> Response
json_response = |json|
    Response.from_status(200)
        .with_headers([("Content-Type", "application/json"), ("X-Powered-By", "Roc")])
        .with_body(json.to_utf8())

# -- Pure text utilities --------------------------------------------------------
#
# Historical note: these were written to avoid `fold` + `List.append` and
# `List.map` with complex lambdas, which miscompiled at compiler ee0fc49d.
# Both are fixed at 48b28c07 (verified by probe); the split_on/join_with
# style is kept because it reads well and is battle-tested here.

## Replace every occurrence of needle with replacement.
replace_all : Str, Str, Str -> Str
replace_all = |haystack, needle, replacement|
    haystack.split_on(needle).join_with(replacement)

## Split a request path into the path proper and the query string.
split_query : Str -> { path : Str, query : Str }
split_query = |full_path|
    match full_path.split_on("?") {
        [] => { path: full_path, query: "" }
        [path] => { path: path, query: "" }
        [path, .. as rest] => { path: path, query: rest.join_with("?") }
    }

## Find a query parameter by name in raw "name=value" pairs, URL-decoding
## both sides.
find_param : List(Str), Str -> [Found(Str), Missing]
find_param = |pairs, wanted|
    match pairs {
        [] => Missing
        [pair, .. as rest] =>
            match pair.split_on("=") {
                [name, .. as values] =>
                    if url_decode(name) == wanted {
                        Found(url_decode(values.join_with("=")))
                    } else {
                        find_param(rest, wanted)
                    }
                _ => find_param(rest, wanted)
            }
    }

query_message : Str -> Str
query_message = |query|
    match find_param(query.split_on("&"), "msg") {
        Found(message) => message
        Missing => "(no msg parameter given)"
    }

## Decode %XX sequences and + as space (URL / form encoding).
url_decode : Str -> Str
url_decode = |input| {
    plus_decoded = replace_all(input, "+", " ")
    match plus_decoded.split_on("%") {
        [] => ""
        [first, .. as rest] => Str.from_utf8_lossy(append_decoded_segments(first.to_utf8(), rest))
    }
}

## Each segment followed a '%' in the input: decode its two leading hex
## chars, keep accumulating bytes (UTF-8 conversion happens once at the end,
## so multi-byte sequences like %C3%B6 survive segment boundaries).
append_decoded_segments : List(U8), List(Str) -> List(U8)
append_decoded_segments = |acc, segments|
    match segments {
        [] => acc
        [segment, .. as rest] => append_decoded_segments(acc.concat(decode_segment_bytes(segment)), rest)
    }

decode_segment_bytes : Str -> List(U8)
decode_segment_bytes = |segment|
    match segment.to_utf8() {
        [a, b, .. as tail] =>
            match (hex_value(a), hex_value(b)) {
                (Hex(hi), Hex(lo)) => [hi * 16 + lo].concat(tail)
                # Invalid hex: keep the '%' (byte 37) and the segment as-is.
                _ => [37].concat(segment.to_utf8())
            }
        _short => [37].concat(segment.to_utf8())
    }

hex_value : U8 -> [Hex(U8), NotHex]
hex_value = |byte|
    if byte >= '0' and byte <= '9' {
        Hex(byte - '0')
    } else if byte >= 'a' and byte <= 'f' {
        Hex(byte - 'a' + 10)
    } else if byte >= 'A' and byte <= 'F' {
        Hex(byte - 'A' + 10)
    } else {
        NotHex
    }

## Escape &, <, >, " and ' for safe interpolation into HTML.
escape_html : Str -> Str
escape_html = |input| {
    amp = replace_all(input, "&", "&amp;")
    lt = replace_all(amp, "<", "&lt;")
    gt = replace_all(lt, ">", "&gt;")
    quot = replace_all(gt, "\"", "&quot;")
    replace_all(quot, "'", "&#39;")
}

## Escape backslash and double quote for JSON strings.
json_escape : Str -> Str
json_escape = |input| {
    backslashes = replace_all(input, "\\", "\\\\")
    replace_all(backslashes, "\"", "\\\"")
}

expect split_query("/echo?msg=hi&x=2") == { path: "/echo", query: "msg=hi&x=2" }
expect split_query("/plain") == { path: "/plain", query: "" }
expect find_param("a=1&msg=hi%20there&b".split_on("&"), "msg") == Found("hi there")
expect find_param("a=1".split_on("&"), "msg") == Missing
expect query_message("msg=query+works") == "query works"
expect url_decode("a%20b%2Bc") == "a b+c"
expect url_decode("J%C3%B6rg") == "Jörg"
expect url_decode("hi+there") == "hi there"
expect url_decode("100%") == "100%"
expect escape_html("<b>&\"") == "&lt;b&gt;&amp;&quot;"
expect json_escape("say \"hi\"") == "say \\\"hi\\\""

# -- Page rendering --------------------------------------------------------------

headers_table : List((Str, Str)) -> Str
headers_table = |headers| {
    rows = headers
        .map(|(name, value)| "<tr><th>${escape_html(name)}</th><td>${escape_html(value)}</td></tr>")
        .join_with("")
    "<table>${rows}</table>"
}

home_content : Str
home_content =
    \\<p>Try these:</p>
    \\<ul>
    \\    <li><a href="/hello/Johnny">/hello/Johnny</a> — greet someone by name</li>
    \\    <li><a href="/hello/J%C3%B6rg%20%26%20S%C3%B6hne">/hello/J%C3%B6rg%20%26%20S%C3%B6hne</a> — URL decoding &amp; HTML escaping</li>
    \\    <li><a href="/echo?msg=Hello%20from%20a%20query%20string">/echo?msg=...</a> — echo via query string</li>
    \\    <li><a href="/api/hello/Johnny">/api/hello/Johnny</a> — JSON with its own Content-Type</li>
    \\    <li><a href="/headers">/headers</a> — see your request headers</li>
    \\    <li><a href="/system">/system</a> — platform effects: Env, Utc, Sleep, Random, File</li>
    \\    <li><a href="/notes">/notes</a> — file-backed persistence (File.read/write/delete)</li>
    \\    <li><a href="/nope">/nope</a> — a 404</li>
    \\</ul>
    \\<form method="post" action="/echo">
    \\    <input name="msg" placeholder="Say something...">
    \\    <button>Echo</button>
    \\</form>

page : Str, Str -> Str
page = |title, content| {
    html =
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\    <meta charset="utf-8">
        \\    <title>${title}</title>
        \\</head>
        \\<body>
        \\    <h1>${title}</h1>
        \\    ${content}
        \\    <p><a href="/">home</a></p>
        \\</body>
        \\</html>
    html
}
