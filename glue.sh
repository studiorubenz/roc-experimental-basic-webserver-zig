#!/usr/bin/env bash
set -euo pipefail

# Regenerate platform/roc_platform_abi.zig from the platform's hosted API.
#
# Run this whenever platform/main.roc or a hosted module (Stdout.roc, File.roc,
# ...) changes its hosted functions or the types crossing the host boundary.
# The generated file is checked in; `zig build` never needs the compiler tree.
#
# Pinned toolchain (see CREATING-AN…md): roc @ 48b28c07.
# Override with ROC_SRC=/path/to/roc-checkout and/or ROC=/path/to/roc.
ROC_SRC="${ROC_SRC:-$HOME/Code/roc/roc-48b28c07}"
ROC="${ROC:-$ROC_SRC/zig-out/bin/roc}"

cd "$(dirname "$0")"
"$ROC" glue "$ROC_SRC/src/glue/src/ZigGlue.roc" platform/ platform/main.roc
echo "Regenerated platform/roc_platform_abi.zig"
