#!/usr/bin/env bash
set -euo pipefail

# Pinned toolchain (see CREATING-AN…md): roc @ 48b28c07 + Zig 0.16.0.
# Override with ROC=/path/to/roc and/or ZIG=/path/to/zig.
ROC="${ROC:-$HOME/Code/roc/roc-48b28c07/zig-out/bin/roc}"
ZIG="${ZIG:-$HOME/zig-0.16.0/zig}"

if [[ $# -lt 1 ]]; then
    echo "Usage: ./build.sh <example> [port]" >&2
    echo >&2
    echo "Builds examples/<example>/main.roc and starts the server." >&2
    echo "Port defaults to \$PORT or 8000." >&2
    echo >&2
    echo "Available examples:" >&2
    for dir in examples/*/; do
        [[ -f "$dir/main.roc" ]] && echo "  - $(basename "$dir")" >&2
    done
    exit 1
fi

APP="examples/$1"
if [[ ! -f "$APP/main.roc" ]]; then
    echo "Error: $APP/main.roc not found." >&2
    echo "Available examples:" >&2
    for dir in examples/*/; do
        [[ -f "$dir/main.roc" ]] && echo "  - $(basename "$dir")" >&2
    done
    exit 1
fi
shift

if [[ -f "$APP/src/Main.elm" ]]; then
    echo "Compiling Elm frontend..."
    (cd "$APP" && elm make src/Main.elm --output=elm.js --optimize)
fi

case "$(uname -sm)" in
    "Darwin arm64") TARGET=arm64mac ;;
    "Darwin x86_64") TARGET=x64mac ;;  # cross-compiles cleanly; untested at runtime
    *) echo "Unsupported host: $(uname -sm) (see README, Other targets)" >&2; exit 1 ;;
esac

echo "Building host library ($TARGET)..."
"$ZIG" build "$TARGET"

echo "Building Roc app (standalone binary): $APP ..."
"$ROC" build "$APP/main.roc"

echo "Starting server..."
# Port: first remaining argument, else $PORT, else 8000
exec ./main "$@"
