# Modern Roc: Before and After the Tutorial-Style Refactor

The webserver app (`app/main.roc`) was refactored on 2026-06-09 to follow the
idioms taught in `~/Code/roc/roc-ai-tutorial`. Behaviour is identical — same
routes, same responses, verified with the same curl checks. What changed is
*how the code says what it means*. This document walks through the differences.

> **Addendum (2026-06-10):** the effectful shell described in section 4 has
> since been inverted again: the app now exports `handle! : Request =>
> Response` and the Zig host owns the accept loop, so `main!`/`serve!` no
> longer exist. The pure core (`route`, `render`) and everything said about
> tag unions, pattern matching and type aliases is unchanged — the shell
> just got even thinner. See CREATING-AN–EXPERIMENTAL–BASIC-WEBSERVER…md.

## At a glance

| Aspect | Previous version | Current version |
|---|---|---|
| Routing | `if`/`else if` chain on `method`/`path` strings | `match` on a `(method, path)` tuple |
| Route representation | none — routing and rendering fused in one function | `Route` tag union: `[Home, Greet(Str), Echo(Str), NotFound(Str, Str)]` |
| Domain types | anonymous record `{ status, html }` inline | named aliases `Request`, `Route`, `Response` |
| Request data | three loose `Str` bindings | one `Request` record |
| Structure | one `handle_request` doing everything | `route` (parse) → `render` (present), pure; effects in `main!`/`serve!` |
| Adding a route | edit the if-chain, hope you caught every spot | add a tag; the compiler flags every `match` that misses it |

## 1. Routing: from boolean logic to pattern matching

**Previous** — conditions are free-form boolean expressions; the structure of
the request is implicit in repeated comparisons:

```roc
handle_request = |method, path, body| {
    if method == "GET" and path == "/" {
        { status: 200, html: home_page }
    } else if method == "GET" and path.starts_with("/hello/") {
        name = path.drop_prefix("/hello/")
        { status: 200, html: page("Hello ${name}!", "...") }
    } else if method == "POST" and path == "/echo" {
        message = body.drop_prefix("msg=")
        { status: 200, html: page("You said:", "<pre>${message}</pre>") }
    } else {
        { status: 404, html: page("404 Not Found", "...") }
    }
}
```

**Current** — the request shape is laid out as data; each case is a pattern,
with a guard for the one dynamic segment:

```roc
route : Request -> Route
route = |request|
    match (request.method, request.path) {
        ("GET", "/") => Home
        ("GET", path) if path.starts_with("/hello/") => Greet(path.drop_prefix("/hello/"))
        ("POST", "/echo") => Echo(request.body.drop_prefix("msg="))
        (method, path) => NotFound(method, path)
    }
```

What this buys:

- **Literal patterns** (`("GET", "/")`) read like a routing table, not logic.
- **Guards** (`if path.starts_with(...)`) handle the dynamic case without
  breaking the table shape.
- **The catch-all binds what it needs** — `(method, path)` flows straight into
  `NotFound(method, path)`, so the 404 page can say what was asked for. The
  old `else` branch got this for free only because everything was in scope;
  here it is explicit.
- A subtle behaviour win: the old chain handled `POST /` by falling to the
  bottom; the new catch-all does the same but *visibly* — the last tuple
  pattern is unmistakably "everything else".

## 2. Routes as a tag union — the refactoring superpower

The previous version had no notion of "a route" at all: deciding *which* route
matched and producing *its HTML* happened in the same breath. The current
version splits that into a value:

```roc
Route : [Home, Greet(Str), Echo(Str), NotFound(Str, Str)]
```

and an exhaustive consumer:

```roc
render : Route -> Response
render = |current_route|
    match current_route {
        Home => { status: 200, html: home_page }
        Greet(name) => ...
        Echo(message) => ...
        NotFound(method, path) => ...
    }
```

This is the tutorial's central argument for tag unions (chapters 10 and 13):
`match` must be exhaustive, so when you add `Health` or `Greet(Str)` gains a
second payload, the compiler points at every `match` that needs updating. In
the if-chain version, a forgotten case silently fell through to the 404 — the
C-`switch` trap, minus even the `switch`.

The intermediate `Route` value is also inspectable: it can be logged, tested
against, or pattern-matched again — none of which a half-executed if-chain
can offer.

## 3. Named types over loose strings

**Previous:** `handle_request : Str, Str, Str -> { status : U16, html : Str }`
— three positional strings; the caller must remember that the order is
method, path, body. Swap two arguments and the type checker shrugs.

**Current:**

```roc
Request : { method : Str, path : Str, body : Str }
Response : { status : U16, html : Str }

route : Request -> Route
render : Route -> Response
```

Field names make argument mix-ups impossible, and the signatures now document
the pipeline by themselves (tutorial chapter 17: "aliases document intent").
The record is built right where the effects happen:

```roc
request = { method: Http.method!(), path: Http.path!(), body: Http.body!() }
```

## 4. Functional core, imperative shell

Both versions kept `main!` effectful, but the previous one mixed concerns:
`handle_request` was pure by accident rather than by design, and `main!` did
listening, logging, accepting and dispatching in one block.

The current version makes the boundary explicit (tutorial chapter 21):

- **Shell (`=>`):** `main!` checks `listen!` and delegates; `serve!` loops on
  `accept!`, gathers the `Request`, and ships the `Response` back through
  `set_status!`/`respond!`.
- **Core (`->`):** `route` and `render` are pure functions. The whole request
  handling collapses to one line in the shell:

```roc
response = render(route(request))
```

Pure functions are testable without a socket in sight — a future `expect
route({ method: "GET", path: "/", body: "" }) == Home` needs no server.

Roc enforces the split in the type system: `->` functions *cannot* perform
effects, so the compiler guarantees `route`/`render` stay pure no matter who
edits them next.

## 5. What deliberately did not change

- The `var $running` / `while` accept-loop — mutable locals scoped to one
  function are idiomatic Roc (tutorial chapter 15), not something to refactor
  away.
- The `\\`-style multiline HTML strings and the `page` helper (including the
  corrected `<head>` with `<meta charset="utf-8">`).
- The platform API and host: this was an app-level refactor; the hosted
  functions (`listen!`, `accept!`, `method!`, `path!`, `body!`,
  `set_status!`, `respond!`) are untouched.

## Takeaway

The if-chain version asked: *"do these strings look like route X?"* — control
flow as interrogation. The modern version says: *"a request parses into one
of these routes, and each route renders into a response"* — control flow as
data. Same behaviour today; far better leverage the day the app grows.
