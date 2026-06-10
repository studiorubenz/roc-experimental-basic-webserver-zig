# Examples

Each subdirectory is a standalone app for the basic-webserver platform
(`../platform/main.roc`). Build and run one with:

```bash
./build.sh app          # build + run examples/app on port 8000
./build.sh app 8123     # same, on port 8123
./build.sh              # lists available examples
```

Or directly:

```bash
roc build examples/app/main.roc && ./main
```

- `app/` — the full HTTP demo: routing on `Method`/path, query strings, URL
  decoding, HTML escaping, request headers page, JSON endpoint, POST echo.
- `ws-echo/` — WebSocket demo: the server privately answers every text
  message (`/help`, `/upper`, `/reverse`, `/count`, plain echo).
- `chat/` — WebSocket broadcast chat: open `/` in several tabs; plain
  messages go to everyone, `/me` actions broadcast, `/help` is private.
- `websocket-elm/` — the same chat with an Elm frontend. `build.sh` compiles
  `src/Main.elm` first (any example with a `src/Main.elm` gets this step);
  the server reads the compiled `elm.js` from disk per request
  (`File.read_bytes!`), so you can re-run `elm make` and just refresh the
  browser — no server rebuild. Elm talks to the socket through ports
  (Elm 0.19 has no built-in WebSockets). Alternative technique: embedding
  the bundle at build time via an ingested import
  (`import "elm.js" as elm_js : Str`) also works at this pin, at the cost
  of a build-time dependency on the asset.

Every app must export both `handle! : Request => Response` (HTTP) and
`on_ws! : { message : Str, path : Str } => { broadcast : Str, reply : Str }`
(WebSocket text messages: `reply` goes to the sender, `broadcast` to all
connected clients; empty string skips that send — return a stub if unused).

When adding a new example, reference the platform as
`../../platform/main.roc`.
