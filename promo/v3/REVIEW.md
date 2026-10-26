# Mac Flow v3 — "One day" — review notes

70 s, 30 fps. Outputs: `renders/mac-flow-one-day-4k.mp4` (3840 × 2160) and `renders/mac-flow-one-day-1080p.mp4`
(the README copy, in `docs/film/`). Storyline **A, "One day"** from `STORYLINES.md`, written up as `SPEC.md`.
Asked for: a clean, Apple-style promo of the latest features, clean UI, smooth animation, high-quality audio.

## What it shows (every frame of UI is the real app)

7:58 AM the planner Flow drafted overnight → Start My Day → Up next with its saved room → Flow Lens on a copied line →
Claude finishing a long task → the meeting, Join, notes taken on this Mac → hold the notch and ask → the day drawn as a
ring → Rewind scrubbing the day → 11:54 PM StandBy in Liquid Glass behind the dune, then Now Playing with floating
lyrics → the MacBook in the dark → every live state → the mark.

- **Island frames** are rendered by the app's own SwiftUI views through the film harness (`../tools/harness`: the v2
  harness plus `FilmHarnessV3.swift`, and `film-hooks-v3.patch` for three small app hooks), at 5×, each section with
  the local clock set to its scene's time. StandBy pages are rendered at 3× on the app's own 4K wallpapers.
- **The Mac** is the v2 Three.js MacBook, relit for dawn and night, its screen texture drawn from the same frames.
- **Cuts and clicks land on the music's grid** (`assets/audio/grid.json`, from the track's measured downbeats): the
  planner's Start My Day click on the bar at 10.85 s, Set the Room 13.04, Add to Calendar 15.47, Join 24.20, the StandBy
  flash on drop B at 46.00, the end-card star on the final hit at 63.48.

## Sound

"AMALGAM" by Rockot (Pixabay; human-made, not Content ID registered; picked by ear from four candidates), cut on
downbeats whose harmony matches (`tools/bars.py` found the seams: chroma 0.94 and 0.997), 12 ms equal-power crossfades,
no step at either seam above the music's own transients. 16 Pixabay effects, each placed so its measured peak lands one
frame after its picture. `tools/mixdown.py` ducks the bed under each effect; every effect sits 2–10 dB over the bed.

Measured, **not heard**: music alone −14.0 LUFS; final mix −14.2 LUFS integrated, −3.4 dBTP by the mixer's meter (about
−1.2 by the renderer's), short-term max −11.5 LUFS, no clipping, silence only in the last 1.1 s (the tail). Nobody has
listened to the finished file yet; the track was chosen by ear, the mix was not.

## Checked

- `hyperframes check`: ok, 0 errors. Warnings kept: the Mac's own menu-bar and UI text under the 28 px floor (it is the
  real app at the screen's scale), a `dead_stretch` over the 3D intro (the checker can't see a WebGL camera move), a
  two-axis tween on the end-card star, and a file-length note.
- Looked at ~110 stills across every scene and seam, then at 44 frames of the encoded file.

Fixed along the way: the 3D scene never registered because the wallpaper was waited on twice (the second `onload` replaced
the first); decoding 23 frames of 3260 px at once ran the browser out of memory, so the MacBook uses 2× copies
(`tools/mk_3d_frames.py`); titles collided with the screen, so they sit on black above the MacBook (and away from the
island on the desktop); a stray `.h` class made the note's header absolute; the meeting card showed the render's real
time zone, so it is rendered at a whole-hour zone and the menu-bar clock reads what the card says.

## Weakest moments / with more time

- The 3D MacBook is procedural: from the hero angles the keyboard reads as a grid of keys, not a photographed deck.
- The copied line sits in an invented Notes window (the one piece of UI that isn't Mac Flow).
- The state montage (61.5–63.5 s) is 2× speed: it reads as breadth, not as each state.
- Day Plan, Rooms, Lens and Rewind each get 3–5 s; Brief, Learn and Dock Companion are not in the film.

## Rebuild

```bash
# 1. island frames (needs a scratch copy of the app with ../tools/harness applied; see tools/render_frames.sh)
tools/render_frames.sh <film app dir> <frames dir>
python tools/crop_frames.py <frames dir> assets/frames 5 && python tools/mk_3d_frames.py p_open p_hold
# 2. music: the Pixabay MP3 -> assets/audio/rockot-amalgam-217007.mp3
python tools/music_edit.py assets/audio/rockot-amalgam-217007.mp3 assets/audio/music-edit.wav 70
python tools/master_music.py assets/audio/music-edit.wav assets/audio/music-master.wav -14
# 3. the film
python tools/build_v3.py && python tools/mixdown.py ffmpeg
npx hyperframes render --resolution landscape-4k --quality delivery -o renders/mac-flow-one-day-4k.mp4
```

Homebrew's ffmpeg on this Mac links `libx265.216`, which only x265 4.2 ships: put a wrapper that sets
`DYLD_LIBRARY_PATH=/opt/homebrew/Cellar/x265/4.2/lib` first on `PATH` (macOS drops `DYLD_*` through `npx`).
