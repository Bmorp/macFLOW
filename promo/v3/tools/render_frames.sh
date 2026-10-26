#!/bin/bash
# Re-renders island frames from the film copy of the app, each section with the local clock set to its scene's time.
# Needs a scratch copy of the app with promo/tools/harness applied (see ../REVIEW.md). Whole-hour time zones only
# (Foundation ignores odd offsets), so the meeting scene reads whatever minute it is rendered at, written to
# assets/frames/meet-clock.txt for the builder. Usage: tools/render_frames.sh <film app dir> <out dir>
set -euo pipefail
APP=$1; OUT=$2; ART="$(cd "$(dirname "$0")/../.." && pwd)/tools/harness/artwork.png"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$APP"; BIN="$(swift build --show-bin-path)/Atoll"
run() { TZ=$1 FILM_SCALE=5 ATOLL_ART=$ART FILM_ONLY=$2 "$BIN" --film "$OUT" | grep -E "film ok"; }
run Etc/GMT+8 v3plan,v3next          # ~10 AM
run Etc/GMT+4 v3meet                 # ~2 PM; the clock is the render's
TZ=Etc/GMT+4 date "+%a %-d %b  %-I:%M %p" | sed 's/^\(...\) \(.*\)/\1 \2/' > "$HERE/assets/frames/meet-clock.txt"
run Etc/GMT-3 v3voice,v3day,v3rewind,v3claude,v3lens   # ~9 PM
