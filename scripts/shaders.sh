#!/bin/bash
# Compiles Prism's Metal shaders (Sources/Atoll/Prism/Shaders) into one library the app loads at launch.
#   ./scripts/shaders.sh                  → build/Prism.metallib (a debug `swift run` finds it there)
#   ./scripts/shaders.sh path/to/out.metallib
# For development: ./scripts/shaders.sh && swift run
#
# Metal 2.4 and macOS 14 as the floor, so the same library runs on the oldest Macs Mac Flow supports (Intel UHD 617
# included). Xcode 26 and later ship the Metal compiler as a separate component; without it this exits with 2 and says
# how to add it (xcodebuild -downloadComponent MetalToolchain). The app runs without the library, in its plain look.
set -euo pipefail

cd "$(dirname "$0")/.."
SRC="Sources/Atoll/Prism/Shaders"
OUT="${1:-build/Prism.metallib}"

if ! xcrun metal --version >/dev/null 2>&1; then
    echo "shaders.sh: the Metal compiler isn't installed. Add it with: xcodebuild -downloadComponent MetalToolchain" >&2
    exit 2
fi

mkdir -p "$(dirname "$OUT")"
AIR="$(mktemp -d)"
trap 'rm -rf "$AIR"' EXIT
for f in "$SRC"/*.metal; do
    xcrun -sdk macosx metal -std=macos-metal2.4 -mmacosx-version-min=14.0 -I "$SRC" -Werror -c "$f" -o "$AIR/$(basename "${f%.metal}").air"
done
xcrun -sdk macosx metallib "$AIR"/*.air -o "$OUT"
echo "shaders.sh: $OUT ($(du -h "$OUT" | cut -f1 | tr -d ' '))"
