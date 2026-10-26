# Mac Flow v3 — "One day" — spec

GOAL:    the viewer feels the notch runs a whole day — plans it, focuses it, takes its notes, draws it, and sings it to
         sleep — and wants to install it. Told the way Apple tells a feature film: calm, confident, real UI, the Mac as hero.
OUTPUT:  HyperFrames, 1920 × 1080 composition, rendered 3840 × 2160 (master) and 1920 × 1080 (README), 30 fps.
TIME:    70.0 s × 30 = 2100 frames. Music "AMALGAM" (Rockot, Pixabay) cut on its downbeats (tools/music_edit.py), ~110 BPM,
         bar ≈ 2.18 s. Film downbeats: 0, 2.11, 4.36, 6.51 | DROP A 8.66, 10.85, 13.04, 15.47, 17.66, 19.84, 22.02, 24.20,
         26.38 | CALM 28.57, 30.75, 32.93, 35.11, 37.30, 39.48, 41.66 | HUSH 43.855 | DROP B 46.005, 48.455, 50.635,
         52.825, 55.005, 57.195, 59.375, 61.545 | FINAL HIT 63.48 | end 70.0.

LOOK:    Three worlds, alternating bright and dark, never a void with small UI in it:
         - Studio: the 3D MacBook (v2's model) fills 55–85% of the frame width; black ground with a floor reflection,
           key from upper left (dawn: warm #ffd9b0 at 3.0; night: neutral), rim lights violet #a58cff and white.
         - Desktop: the Mac's own screen full frame — the app's original wallpapers (Dunes for day, Horizon for dusk) and
           its menu bar; the island at 1.8–2.6× with a ≤ 8° tilt and depth of field (7 px blur outside a 52 × 46% ellipse).
         - StandBy: the app's 4K StandBy pages, full bleed.
         Ink #ffffff; accent: Flow's gradient #d9ccff → #9e85ff → #e58ad0 on at most one word per title.
         Type: SF Pro (variable), titles 600 weight at 96–112 px, tracking −2.8%, line-height 1.04; one line on screen at a
         time; titles in the desktop world sit left at x = 160 px, y = 760–860 px (over the sky/sand, a 0 0 24px
         rgba(0,0,0,.35) shadow, no scrim); studio and end titles centred.
OBJECTS: the MacBook (machined aluminium edge, glass screen, keyboard deck, hinge); the notch and its island (always the
         real app, rendered at 5×); the macOS arrow cursor at 5% of frame height, entering from off-screen; the menu bar
         (Apple logo, app menus, the clock — which carries the time of day: 7:58 AM → 2:04 PM → 7:42 PM → 11:48 PM).
MOTION:  camera moves power2.inOut 0.5–0.9 s, landing on a bar; whips 0.35 s expo.inOut with 18 px motion blur at peak;
         titles: word-by-word blur 12 → 0 px, 0.22 s each, 75 ms stagger, then hold still; exit blur 10 px over 0.2 s.
         UI motion is the app's own springs (rendered frames). Cursor: 0.45–0.6 s power3.inOut to the target, click
         = 80 ms scale 0.88 at the frame the UI reacts.
SHOTS:   (film seconds)
  1  0.00– 8.66  Studio, dawn. Low three-quarter glide toward the notch; on the screen Dunes at morning, menu bar 7:58 AM,
                 the island opens into the planner at 3.2 s. Titles: "Your day" (1.0) → "starts at the notch." (4.4).
                 Hand-off: the camera flies into the screen and lands on the drop.
  2  8.66–13.04  Desktop (Dunes). The planner at 2.4×: three drafted priorities with Flow's star. Cursor to Start My Day,
                 click 10.85; the island closes; Up next opens; click Set the Room 13.04 → the focus timer starts.
                 Title: "Planned before you are." (9.1)
  3 13.04–17.66  Desktop. A copied line "Lunch with Sam tomorrow at 1pm" (⌘C) → Flow Lens offers Add to Calendar;
                 click 15.47 → "Lunch with Sam · Tue 1:00 PM". Title: "It reads what you copy."
  4 17.66–22.02  Desktop, push-in. Focus timer running; Claude finishes: "Refactor the settings window · 12m 14s".
                 Title: "It keeps an eye on Claude."
  5 22.02–28.57  Desktop, 2:04 PM. "Design Review in 5 min" → Join 24.20 → Take Notes → the other side's words appear
                 as they're said. Title: "It takes the notes."
  6 28.57–32.93  Desktop dissolves Dunes → Horizon (dusk), clock 7:42 PM. Cursor holds the notch: Flow listens,
                 "What did I get done today?" Title: "Just ask."
  7 32.93–37.30  The day ring draws itself in (real progress 0 → 1). Title: "Your day, drawn."
  8 37.30–43.86  Rewind: the playhead scrubs 9 AM → 3:30 PM. Title: "Rewind any moment."
  9 43.86–46.01  Hush. Everything darkens to the notch alone; "11:48 PM" types in the menu bar; the island is still.
 10 46.01–50.64  DROP B. StandBy full bleed: Liquid Glass time over the dune (the ridge over the figures); 1.12 → 1.0 push.
 11 50.64–55.01  StandBy Now Playing: lyrics rise line by line on the half bar.
 12 55.01–61.55  Studio, night: the MacBook in the dark, StandBy on its screen; slow hero arc. Titles: "Your whole day." (55.6)
                 → "In the notch." (58.9, gradient on "notch").
 13 61.55–63.48  The island alone at 2.6×, every live state in a 2× montage, closing into the pill.
 14 63.48–70.00  FINAL HIT. The pill becomes the Mac Flow mark (lands at 63.5), wordmark wipes in (64.1), then
                 "Free and open source · macOS 14 or later" and github.com/Bmorp/macFLOW (65.0), held to 70.
SOUND:   the edited track at −14 LUFS; effects (Pixabay, v2's set): a click on every cursor click; a soft whoosh on each world
         change (rotate 3 takes); a pop on Lens and Claude cards; a riser through the hush into DROP B; a sub boom on DROP B
         and on the final hit. Each placed so its peak lands one frame after its picture; bed ducks 2–4 dB under clicks.
BANNED:  a dark void with small UI floating in it; glow, bloom, particles; glass cards; three cards in a row; titles that
         drift after they land; everything fading in; a title over a dimmed screenshot; the logo docked in a corner; any
         UI that isn't rendered from the app; invented numbers.
QA:      0.0 (thumbnail: MacBook + title), 3.4 (planner on the 3D screen readable), 10.85/13.04/15.47/24.20 (clicks land
         on the button the frame it reacts), 26.0 (transcript legible), 35.0 (ring mid-draw), 44.5 (hush), 46.1 (StandBy
         sharp at 4K), 52.0 (lyrics), 57.0 (MacBook night), 64.5 and 69.5 (end card), plus every seam ± 2 frames.
