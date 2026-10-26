# Mac Flow v2 — "The notch that thinks" — review notes

70 s, 30 fps. Outputs: `renders/mac-flow-the-notch-that-thinks-4k.mp4` (3840×2160) and `renders/mac-flow-the-notch-that-thinks-1080p.mp4`.

## What changed from v1, and why

v1 was a flat screen recording on a pastel wallpaper with a synthesised score. v2 follows what Apple's own films do
(watched frame by frame: the iPhone 14 Pro Dynamic Island reveal, "Introducing Liquid Glass", the MacBook Pro M5
Pro/Max and Mac mini M6 films, and the viral "Dynamic Notch" concept) — see `TREATMENT.md`:

- **Pure black stage, the hero alone and lit**: the island drawn in violet light; Flow's star igniting with a light streak.
- **A real-time 3D MacBook** (Three.js, machined-aluminium edge, glass display, rim lights, floor reflection): a low glide
  into the notch, a pull-back for privacy, a hero orbit.
- **UI at macro scale with a 3D tilt and depth of field**; every island frame is still the real app (5× renders).
- **Kinetic type** typed letter by letter or word by word, gradient on the key word.
- **Story centred on Flow's brain**: it learns how you work (real work modes, the three depths), speaks up at the right
  moment (eight real suggestions + the learning question, a cursor accepting one), just ask (the agent acting, the
  answer about your day), on-device, then "and that's just the brain" → everything live → the notch that thinks.
- **Sound**: a produced track (Pixabay, Editor's Choice, not Content ID registered) cut on its own bars, 16 licensed
  effects each placed so its measured peak lands one frame after its picture.

## Measured vs looked at

- `hyperframes check`: passes. Warnings kept: menu-bar text under the type floor (it's the Mac's chrome), typed lines
  flagged as "unread" (the checker counts letters as words).
- Looked at ~70 stills across every scene; fixed: overlay hiding the film, gradient words showing early, a dropped
  word space, 3D depth fighting on the screen, privacy shot framing, a "Late night" greeting and a "Sat, 24 Oct" date
  from the render time zone (re-rendered at a morning time).
- Music edits checked: no transient spike at either seam; harmony matches across them (0.89 and 0.97 chroma similarity).
- Mix (measured, not heard): music mastered then mixed with all 31 effects in `tools/mixdown.py` — the bed ducks 2–6 dB
  under clicks, UI sounds and whooshes; hits sit +6–9 dB, UI sounds +3–6 dB over it. Final file: −14.2 LUFS integrated,
  −1.6 dBTP, loudest moment on the second drop (48.3 s).
- 4K sharpness: the UI stage is laid out at 3× with CSS `zoom` (the 3D camera only scales down), so Chrome rasterizes
  the island text sharp at 3840×2160. Encoded at 38 Mbps (4K) and 13 Mbps (1080p).

## Weakest moments / with more time

- The 3D MacBook is procedural: from the hero angles the keyboard reads as a grid of keys rather than a photographed deck.
- The rapid suggestion montage (0.6 s per card) reads as "lots of smart help" rather than card by card — intentional.
- Day Plan and the Flow inbox were left out: that code was mid-change and didn't compile when this was made.

## Rebuild

```bash
python3 tools/music_edit.py <track.wav> assets/audio/music-edit.wav   # needs the WAV of the Pixabay track
python3 tools/master_music.py <music-edit.wav> assets/audio/music-master.wav -13
python3 tools/build_v2.py
python3 tools/mixdown.py <path/to/ffmpeg>
npx hyperframes render --resolution landscape-4k --quality delivery -o renders/mac-flow-the-notch-that-thinks-4k.mp4
```

Island frames: `tools/` + the film harness in `../tools/harness` (add the v2 sections), rendered at `FILM_SCALE=5`
with `TZ` set so the local time is morning, then `tools/merge_frames.py <dir> assets/frames 5`.
