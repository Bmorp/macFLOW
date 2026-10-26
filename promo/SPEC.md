# Mac Flow — "Look up" — spec

GOAL:    A Mac user watches 46 s and wants the notch to do this; they remember "everything live, just look up".
OUTPUT:  HyperFrames, 1920 x 1080, 30 fps, H.264 high + AAC 320k.
TIME:    46.5 s x 30 = 1395 frames. Music 120 BPM = 15 frames a beat, 60 a bar. Big moments on bar lines (even seconds).

LOOK:
- Medium: the product's real UI on a real-feeling MacBook display. Every island frame is rendered from the app's own
  SwiftUI code (same springs, shapes, rim sweep, demo data) at 3x, transparent, then composited. Nothing in the island is drawn by hand.
- Display: 1470 x 956 pt screen, 32 pt menu bar beside a 179 x 32 pt notch, black bezel 14 pt (sides) / 18 pt (top) / 22 pt (chin),
  10 pt screen corners. Menu bar: rgba(255,255,255,0.42) over the wallpaper, SF Pro Text 13 pt, ink #0A0A0B.
- Wallpaper: original warm silk dunes, cream sky #FBF5EE with two soft ribbons high up, sheets #FAD3B4 → #3F1A38, 2% grain.
- Worlds: (1) the notch macro, camera 2.5–3.4x; (2) the black of the island, as a title world; (3) an indigo field #5E5CE6
  (the build activity's own tint) flooding the screen; (4) the whole Mac at 1.04x on ink #0A0A0B; (5) paper #FFFFFF end card.
- Type: SF Pro Display (system file in assets/fonts), Semibold 600, tracking -0.02em. Hook lines 132 px; feature lines 84 px;
  subline 46 px Medium. Ink #0A0A0B on the wallpaper, #FFFFFF on black and indigo, Flow grey #8E8E93 / #636467 for "Flow".
- Brand: the stacked logo and wordmark are the brand kit's own SVGs. The mark lands once, on the end card, 360 px wide (19% of frame).
- Accent ration: activity tints live only inside the island; indigo once as a world; Flow violet only where the app shows it.

OBJECTS: the notch (black, shoulders flaring into the bezel), the island in each state, the macOS arrow / pointing-hand / grab
cursors (system cursors, 56 px tall at 3x), a PDF icon on the desktop labelled "Q4 Proposal.pdf", the Dock with real app icons.

MOTION:
- Island: the app's springs — open response 0.30 / damping 0.80, close 0.26 / 1.0, morph 0.30 / 0.88, split 0.45 / 0.72.
  The wake and the music bloom play at 0.5x, the split at 0.5x, Home at 0.75x; everything else real time; montage at 2x.
- Camera: moves power2.inOut 0.7–2.2 s; punch-ins are hard cuts that settle with expo.out 0.4 s; whip 0.25 s with 24 px blur.
- Titles: land and hold dead still. Entrances vary: per word blur 6→0 in 0.13 s, 0.067 s apart; per word grey→ink 0.08 s apart;
  whole line blur 8→0 in 0.18 s. Exits blur-out 0.15 s. Hold ≥ 0.5 s + 0.3 s a word.
- Cursor: enters from off-screen, power3.inOut 0.5–0.65 s, clicks press to 0.88 for 2 frames; the click causes the next state on the same frame.

SHOTS (s):
- 0.00–6.00  Hook. Notch macro 2.5x → push to 3.2x (1.3–2.3). "Look up." / "That notch?" / "It's been doing nothing." Near silence, ticking pulse, riser from 4.0, silence 5.85.
- 6.00–8.00  Wake. Drop. The notch grows the compact song (0.4 s), then blooms open at 0.5x (6.5–8.0). Sub hit on 6.0.
- 8.00–12.0  Name. The island's black grows past the frame (0.65 s). Wordmark blurs in; "A Dynamic Island for your Mac's notch." Black shrinks back into the meeting island (11.85–12.35).
- 12.0–16.0  Join. Cursor hovers → meeting opens (13.0); clicks Join on the bar (14.0) → call, punch-in. "One click. You're in."
- 16.0–22.6  Flow. Whip. Flow opens, the request types, Flow plays music and starts a timer, replies. "Just tell Flow." / "On-device. Private."
             Closes to the timer; the music bubble splits off at 0.5x (20.6). "Two at once."
- 22.6–25.4  Build. Indigo floods the screen from the notch; the bubble melts back and the build opens and races 24% → 100% → "Build succeeded". "Even your builds."
- 25.4–28.0  AirPods. Indigo recedes; AirPods Pro connect, 92 / 88 / 64. "AirPods, at a glance."
- 28.0–30.0  Drop. Pull back to 1.6x; the grab cursor drags Q4 Proposal.pdf into the notch; Hold on Shelf. "Drop it on the notch."
- 30.0–33.0  Montage. 11 morphs on 8th notes at 2x (every presentation), camera punches on each beat.
- 33.0–36.5  Payoff. Home opens at 0.75x as the camera pulls back 3.05x → 1.04x to the whole Mac (33.0–35.2), holds.
- 36.5–40.0  Claim. Home closes; push back to 2.6x. "Everything live." / "Just look up."
- 40.0–46.5  End. The song ends, the island sleeps into the notch; paper floods from it; the notch lifts into the mark (40.7–41.8);
             the star cuts through on 42.0 (the final hit); the wordmark wipes in; "macOS 14 or later" ; hold to 46.5.

SOUND: score.wav (written for this cut, 48 kHz stereo) + bundled SFX: click on the Join click, soft keys under the typed request,
pops on Flow's two actions and on "Build succeeded", whooshes on the whip and the drag (different takes), bass impact on 42.0.
Mix −14 LUFS integrated, true peak ≤ −1 dBTP.

BANNED: a dark void with small floating UI; glow, bloom, particles, lens flares; purple/blue mesh gradients; glass cards;
the cream-paper serif look; three cards in a row; feature lists as cards; the logo docked in a corner; titles that move after landing;
breathing/floating loops; every element fading and sliding up; tilted 3D product UI; any invented UI inside the island.

QA: 0.0 (thumbnail: notch + "Look"), 6.3 (compact song), 7.9 (open song, rim light), 9.6 (wordmark + subline), 13.9 (cursor on Join),
14.2 (call, punch-in), 19.4 (Flow reply), 21.2 (split bubble), 24.6 (build 100%), 26.8 (AirPods), 29.4 (file over Hold on Shelf),
31.3 (montage), 35.5 (whole Mac + Home), 39.0 (claim), 42.4 (star), 44.5 (end card).
