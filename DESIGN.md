# Atoll 3 — Design Specification

## Thesis

**The notch becomes one living object that shows what's happening right now, and gets out of the way.**

v1–v2 treated the notch as a place to put a dashboard: five tabs, cards, chips, a tool strip, CPU stats.
That is a utility-app idea. Apple's Dynamic Island is the opposite: one thing at a time, chosen by
context, presented with as little chrome as possible. Atoll 3 adopts Apple's Live Activity model
wholesale and adapts it to the Mac.

> `live-activities.md › Best practices`: "Focus on important information that people need to see at a glance.
> Your Live Activity doesn't need to display everything."
>
> `design-principles.md › Simplicity`: "A well-designed experience removes the unnecessary, with every element earning its place."

**Signature moment:** when two things are live at once, the island *splits* — the secondary activity
detaches into its own bubble with a liquid (metaball) stretch, exactly like the iPhone. Everything else
stays quiet so that moment carries the identity.

---

## Information architecture

| v2 (dashboard) | v3 (Apple model) |
|---|---|
| 5 tabs: Home, Apps, Shelf, Clipboard, Notes | **No tabs.** The island shows a *presentation*, not a page |
| Home = cards for media, weather, agenda, timer, tools | **Live Activities** — each feature that has a beginning and end is an activity with compact, minimal and expanded presentations |
| Launcher tab + Clipboard tab | **Search** — one surface (⌥Space) with scopes: Applications · Files · Actions · Clipboard (`searching.md`: "make content searchable through a single location") |
| Shelf tab | **Drop** — drag a file to the notch and the island becomes two targets (Hold, AirDrop). Held files become a Live Activity |
| Notes / Tasks (private store) | **Reminders** — "remind me to … at 5pm" creates a real reminder in the Reminders app |
| Tool strip | **Actions** scope in Search + the menu bar extra |
| CPU / RAM header | Removed. Not something people need at a glance |
| Peeks | **Alerts** — a Live Activity briefly shows its expanded (or wide compact) presentation when something needs attention |

### Presentations (per `live-activities.md › Anatomy`)

```
Compact (one activity)        Minimal (two activities)             Expanded (hover / click)
┌──[art]▓▓▓▓notch▓▓▓▓[≋]──┐    ┌──[◷]▓▓▓notch▓▓▓[24:13]─┐ (●art)     ┌─[♫ Music]▓▓notch▓▓[≋]─┐
                              primary attached        detached       │ [art] Title          │
                                                       bubble        │       Artist         │
                                                                     │ 0:42 ━━━━━━━━ -2:31  │
                                                                     │  ⏮     ⏯     ⏭    ⌁ │
                                                                     └──────────────────────┘
```

- **Compact** — leading + trailing elements snug against the notch, read as one piece of information.
- **Minimal** — the second-priority activity detaches into a circular bubble right of the island.
- **Expanded** — an enlarged version of compact. Shared elements (artwork, waveform, timer digits) move
  to their new positions with matched geometry instead of fading out and back in
  (`live-activities.md › Animate layout changes`).
- **Glance** — when nothing is live, hovering shows only the date, weather and what's next.

### Activities and priority

| Activity | Tint | Compact leading / trailing | Minimal | Expanded |
|---|---|---|---|---|
| Timer | systemOrange | progress ring / `24:13` | ring | pause + stop circles, large digits |
| Meeting (starting ≤ 10 min or in progress) | systemGreen | video glyph / `4 min` | glyph | title, time, **Join** |
| Download | systemBlue | progress ring / `62%` | ring | file, bytes, progress, Show in Finder |
| Now Playing | artwork colour | artwork / waveform | artwork | artwork, title, scrubber, transport, AirPlay |
| Mirror | white | — | — | live camera, concentric corners |
| Shelf (files held) | systemCyan | thumbnail stack / count | count | tray, Quick Look, AirDrop, Share |
| Keep Awake | systemYellow | cup / `On` | cup | duration, Turn Off |

Priority: Timer › Meeting › Download › Now Playing › Shelf › Keep Awake. Primary takes the compact
presentation; the next one takes the minimal bubble.

Alerts (transient): volume, charging, low battery, device connected, mic/camera started, download
finished, timer finished, meeting starting, track change, confirmations.

---

## Visual system

### Surface
The island is **opaque black in both appearances** (`live-activities.md › Choosing colors`:
"Live Activities in the Dynamic Island use a black opaque background"). No Liquid Glass inside the island —
glass belongs to the functional layer only (`liquid-glass.md › Where the material belongs`).

**Key line:** a 1 pt stroke tinted with the active activity's colour at 35 % so the island separates from
dark wallpapers (`live-activities.md`: "Tint your Live Activity's key line color so that it matches your content").

### Colour (Apple dark system palette, on #000000)

| Role | Value | Contrast on black |
|---|---|---|
| Primary label | #FFFFFF | 21 : 1 |
| Secondary label | #EBEBF5 @ 60 % → ≈ #8D8D93 | 6.4 : 1 |
| Tertiary label | #EBEBF5 @ 30 % → ≈ #464649 | 2.2 : 1 (decorative only) |
| Orange (timer) | #FF9F0A | 10.2 : 1 |
| Green (meeting, charging) | #30D158 | 10.4 : 1 |
| Blue (download) | #0A84FF | 5.8 : 1 |
| Cyan (shelf) | #64D2FF | 12.2 : 1 |
| Red (low battery) | #FF453A | 6.2 : 1 |
| Yellow (awake) | #FFD60A | 14.9 : 1 |

One colour means one thing. Increase Contrast raises secondary to 80 % and the key line to 60 %.

### Typography (SF Pro, medium weight or heavier per `live-activities.md › Ensure text is easy to read`)

| Style | Size / weight | Use |
|---|---|---|
| Hero numeral | 40 semibold, tabular | timer digits |
| Title | 15 semibold | track, meeting, file name |
| Body | 13 medium | secondary lines |
| Compact | 13 semibold, tabular | compact trailing values |
| Caption | 11 medium, tabular | scrubber times |

### Geometry
- Expanded width **440 pt** (iPhone: 371–408) — tight around the notch, not a 690 pt panel.
- Expanded height is **dynamic per activity**: only the space the content needs.
- Outer radius **R = 32**, margin **m = 16** → corner-adjacent shapes use **R − m = 16** (concentric).
- 4-pt spacing scale: 4, 8, 12, 16, 20, 24.
- Controls ≥ 28 × 28 pt hit area (desktop default), 24 pt spacing between bezel-less glyph buttons.

---

## Motion

| Moment | Curve | Notes |
|---|---|---|
| Expand | spring(response 0.48, damping 0.76) | shape morph; content scales 0.86 → 1 from the notch with blur 8 → 0 |
| Collapse | spring(response 0.36, damping 0.9) | content fades out in 0.12 s first |
| Split | spring(response 0.55, damping 0.68) | metaball bridge stretches then snaps |
| Content updates | `.contentTransition(.numericText())`, symbol replace | never re-layout what didn't change |

All animations ≤ 2 s (`live-activities.md`). **Reduce Motion:** morphs become 0.2 s cross-fades,
the split is a fade, marquee becomes truncation.

## Haptics (Force Touch trackpad)

Restraint over volume (`playing-haptics.md`: "the best haptic experience is one that people may not be
conscious of, but miss when it's turned off").

| Event | Pattern | Why this pattern |
|---|---|---|
| Island opens under the pointer | alignment | snapping to a preferred position |
| Scrubber / volume reaches either end | alignment | Apple's documented scrubber case |
| Swipe gesture crosses its threshold | alignment | commit point of a drag |
| Drop accepted | generic | discrete completion |

Nothing fires on hover, list movement, tab changes or incoming alerts. One on/off setting.

## Accessibility
- Every glyph button has an accessibility label; the island exposes a single summary element
  ("Now playing, Midnight City by M83") with actions.
- Full keyboard path: ⌥Space → type → ↑↓ → ↩ / ⌘↩, ⌘1–4 scopes, Esc closes.
- Reduce Motion, Increase Contrast honoured; nothing conveyed by colour alone (every tint pairs with a glyph).

## Permissions (`privacy.md`, `onboarding.md`)
Nothing is requested at launch. Each permission is asked at the moment its feature is used,
with a purpose string that says exactly what it's for.

## App icon (`app-icons.md`)
Layered Icon Composer icon compiled by `actool`: a glass reef ring with a black island resting on it.
Filled overlapping shapes, no UI replica, no painted highlights — the system renders specular
highlights, dark and tinted appearances.

---

# Atoll 4 — Plan

## The experience map

Atoll grows from one surface into five, each with a single job. Nothing duplicates another surface's job.

| Surface | Job | When it's there |
|---|---|---|
| **Island** | What is happening *right now* | Always, at the notch |
| **Desktop Widgets** | What I want to *keep an eye on* | On the desktop, under your windows |
| **StandBy** | The Mac as an *ambient display* | When the Mac sits idle while charging, or on request |
| **Dock Companion** | *Get somewhere fast* | Rises above the Dock when you reach for it |
| **Drop Zones** | *Put this file somewhere* | At the notch and above the Dock while dragging |

## Motion signature — the duo cross-fade

Every content change uses one transition so the whole product feels like one material.

| | Opacity | Blur | Scale |
|---|---|---|---|
| Outgoing | 1 → 0 | 0 → 12 pt | 1 → 0.96 |
| Incoming | 0 → 1 | 12 → 0 pt | 1.04 → 1 |

Both run **at the same time** on one spring (response 0.5, damping 0.86), so screens melt into each other with
no empty frame. Shared elements (artwork, digits, rings) skip the fade and travel with matched geometry.
Reduce Motion: a 0.2 s opacity cross-fade, nothing else.

## Desktop Widgets (`widgets.md`)

- **Sizes** (Mac desktop): small 170 × 170, medium 364 × 170, large 364 × 382 pt. Corner radius 22, margin 14,
  inner radius 22 − 14 = 8 via `ContainerRelativeShape`.
- **Material**: Liquid Glass on macOS 26+, behind-window material on 14–25.
- **Two rendering modes**: full colour while you're on the desktop; when you're working in an app the widgets
  drop to a *vibrant* monochrome (desaturated, softer), as macOS does.
- **Placement**: drag anywhere on a widget to move it. Near another widget it pulls flush with its edges, or exactly one
  16-pt gap away, with an alignment haptic; elsewhere it lands on a 16-pt grid. It never overlaps another widget.
- **Editing**: right-click › Size, Remove, Edit Widgets…. The gallery groups each widget's sizes with one
  description that starts with a verb.
- **Catalog**

| Widget | Sizes | Shows | Action |
|---|---|---|---|
| Now Playing | S M | art, title, progress | play/pause, skip |
| Up Next | S M L | next event / day agenda | Join |
| Weather | S M | now, high/low, hourly strip | — |
| World Clock | S M | analog local clock / 4 cities | — |
| Batteries | S M | Mac + AirPods rings | — |
| Focus Timer | S | ring + presets | start / pause |
| Reminders | M L | today's reminders | check off |
| System | S | CPU, memory, disk gauges | — |
| Shortcuts | S M | 4 / 8 shortcut tiles | run |
| Shelf | M | held files | drag out, AirDrop |

## StandBy for Mac (`widgets.md › StandBy`)

- **Enters** after the Mac has been idle for 5 minutes *on power* (configurable, 2–15), or from the menu / ⌃⌘S.
  **Leaves** on any key or pointer movement, fading back to the desktop.
- **Pages** (swipe sideways, ← → keys): **Clock** (large numerals, date, next event), **Widgets** (two smart stacks
  side by side, scaled up, no backgrounds, vertical swipe to cycle), **Now Playing** (full-bleed artwork ambience).
- **Night mode** between 22:00 and 06:00: monochrome red, as on iPhone.
- **Care**: content drifts a few points every minute against burn-in, and the display stays awake only while charging, for at most an hour.

## Dock Companion

- **Geometry**: reads the Dock's edge, size and auto-hide setting; follows changes live.
- **Reveal**: move from the Dock into the thin band just past its inner edge and rest there for a moment, or choose
  **Show Dock Companion** from the menu bar. Leaves 0.6 s after you move away from both the bar and the Dock.
- **Content** (one Liquid Glass capsule, sections separated by hairlines):
  1. **Now** — whatever is live: song with play/pause, timer, meeting with Join, download progress.
  2. **Continue** — the files you used most recently, ready to reopen.
  3. **Go** — Downloads, Desktop, Documents, Applications.
  4. **Do** — Search, Shelf, Screenshot, StandBy, Widgets.
  Icons magnify under the pointer, like the Dock itself.
- **Live Dock icon** (optional "Show in Dock"): the icon carries a timer ring, download ring or album art,
  and its menu lists every action.
- **Dock drop zone**: dragging files toward the Dock raises a tray: Hold on Shelf · AirDrop · Share · Compress.


---

# Atoll 5 — The island, perfected

Feedback on v4: too many surfaces, rough edges, nothing felt finished. Atoll 5 does one thing beautifully.

## Principles (from the reference)

1. **Born from the bezel.** The top edge is wider than the body and curves into it (shoulders: 8 pt closed, 22 pt open,
   cubic, tangent to the top edge and the sides). Bottom corners are continuous, 30 pt when open — a pill, not a card.
2. **One row, one anatomy.** Every open state: 44-pt visual · title (15 semibold) / detail (13 medium, secondary) ·
   at most two controls. Row area 64 pt below the notch: 4 above the content, 14 below. Body 460 pt wide.
3. **Light means alive.** A rim light in the activity's colour (search uses a spectrum) on the lower contour only — it fades
   out toward the top so the island still merges with the notch. Off when closed. One sweep of light travels the rim each
   time the island opens onto something new.
4. **Motion keeps continuity.** See the choreography below.
5. **Always minimal.** Desktop widgets, StandBy and the Dock companion ship off; one switch each in Settings.

## Choreography

| Moment | Shape | Content |
|---|---|---|
| Open | spring 0.30 / 0.80 | old content fades in 0.10 s; new elements arrive from 30 ms, 25 ms apart, left → right (blur 4 → 0, rise 6 pt, spring 0.30 / 0.90). Album art and the timer ring travel from the compact wing into the row as one object |
| Close | spring 0.26 / 1.0 (critically damped), no delay | content exits first, so nothing squashes |
| Switch | spring 0.30 / 0.88 | outgoing exits, incoming staggers in |
| Rim sweep | — | 0.6 s ease-in-out, 50 ms after opening |
| Reduce Motion | 0.2 s ease | opacity only, no stagger |

Rules that remove glitches:
- Each presentation is laid out once at its own final size and captured (size, alert, primary activity), so while it
  leaves it never reflows with the shape.
- Content is pinned to the top of the shape. A larger state's content hangs from the top edge while the shape grows;
  it never drifts vertically (found and fixed with `--motion`).
- Collapse waits 0.3 s after the pointer leaves a forgiving zone (18–20 pt beyond the body), so brushing the edge
  doesn't thrash.

## New activities

- **Calls** — an app on a known list (FaceTime, Zoom, Teams, Slack, Discord, WhatsApp, Webex, browsers) using the
  microphone, or any app using microphone and camera together. Public CoreAudio / CoreMediaIO only; ends 4 s after
  the microphone goes quiet so a brief mute doesn't flicker.
- **Your tools** — `atoll://progress|done|fail|clear` and the bundled `atoll` command. Text is limited to 64 plain
  characters, symbols must be real SF Symbols, and a link can never trigger an action.


## Atoll 5.1 — measured, not guessed

Feedback: "animation feels laggy, the Dock feature is not working, the start is not proper."

**Measurement.** `--perf` (an optimised build with `-DATOLL_PROBE`) drives the real island and records every display
frame. Before: opening music stalled 57 ms (3 missed frames) at the very start; search stalled 82 ms (5 missed).
Causes found: views built at the moment of hovering, four large blurs per frame (drop shadow, two rim glows, sweep),
Now Playing re-querying Music and computing the artwork colour on the main thread inside the first frames, and
search re-rendering the island on every result reassignment while closing.

**Fixes.** Presentations are warmed off screen after launch; the rim is stacked strokes with a vertical gradient (no blur,
no mask); no drop shadow (the rim separates the island, as in the reference); artwork colour is computed off the main
thread and the player re-sync waits until the open has settled; search resizes only when its height changes and
resets after closing; the waveform is one Canvas at 24 fps instead of per-bar animations.

**After.** Every open, close and switch: 0 missed frames. First search open of a session: 2 frames (AppKit creating the
text field); repeat opens: 0. Idle: 0.0 % CPU.

**Dock.** The companion's window was sized from a hosting view that reported no size, so it never appeared; it's now
measured from its current content. It's reached from a glass handle that appears above the Dock while the pointer is
on it (above magnified icons when magnification is on); hover or click the handle. Opened from a menu or Settings it
stays until you use it or click elsewhere. Recent files show Quick Look thumbnails.

**Start.** The island introduces itself after the welcome window with three tips (it's visible over full-screen apps),
and the first open after launch no longer stalls.


## Atoll 5.2 — one object, no blur, no fade

Feedback: "remove the blur and fade, I want it smooth"; "the first hover shows a calendar — what is that for?"

**Motion.** The island's content is laid out once at its final size and *scaled with the shape* (`visualEffect`,
anchored at the top), so it grows and shrinks inside the island as one object — the way the Dynamic Island behaves.
There is no blur and no opacity animation anywhere in the island:
- Opening or switching: the new content takes over on the first frame (as a miniature inside the pill) and grows.
- Closing: the open content shrinks with the shape and hands over to the compact view at 0.17 s (`Motion.closeSwap`),
  as it lands.
- Shape: spring 0.30 / 0.80 to open, 0.26 / 1.0 to close (no bounce, no wait), 0.30 / 0.88 to switch, 0.22 / 0.80 for
  the hover swell. Quicker and lighter than the first tuning (0.36 / 0.80, 0.32 / 0.92 + 30 ms), which read as sluggish.

**Performance.** The island sits on screen all day, so at rest it must cost nothing:
- `IslandModel` is `@Observable`: a view re-renders only when a property it read changes. Every place (Home, each
  activity page) stays built for instant opens; as an `ObservableObject` all of them re-rendered on every hover, tick
  and alert.
- Anything that loops — the live dot, Claude's thinking dots, the waveform, the spinner, a scrolling title, the
  Claude spark, the album field — is a Core Animation layer (`LayerMotion.swift`) run by the render server, and stops
  while its presentation is out of sight (`islandShowing`). A SwiftUI loop re-ran the view graph and laid out the
  hosting view every display frame, closed or not. Offscreen renders keep a still SwiftUI drawing.
- Clocks tick only when their label changes (`ElapsedSchedule`: every second for the first minute, then once a
  minute) and never while hidden.
- The metaball canvas is a strip under the bezel, not the whole panel; pointer moves far from the notch skip hit-testing.
- Services: clipboard polling stops when history is off; images and history are encoded and written off the main
  thread; album art is decoded and downsized off the main thread; the Brain reads on its own SQLite connections so the
  main thread never waits behind a long scan; every AppleScript runs on one serial queue; models publish only real
  changes. Measured at rest with Claude working: ~0.1–0.4 % CPU (was 3–5 %).

**Home.** Hovering with nothing live (or only music) opens the home: date and weather beside the notch on the left,
battery and search on the right; below, your player (or one tap to start Music/Spotify) and eight apps — the ones
you open from Atoll first, then favourites — one click to launch. Anything else that's live (timer, call, meeting,
download, your build) opens its own row.

**First hover.** For 2.5 s after launch the home, music and search views are drawn invisibly outside the island, so
their layers, textures and text field already exist. Measured on an optimised build: first home open 0 missed frames
(was 2), every other open/close/switch 0; the first search open of a session still costs 2 frames (the panel
becoming keyboard-active).


## Atoll 5.3 — connected to Claude

Feedback: "it should keep track and be connected to my Claude."

**Tracking (no setup).** Claude Code keeps a small status file per running session in `~/.claude/sessions/<pid>.json`
(name, folder, `status`, `statusUpdatedAt`). Atoll watches that folder (directory events, plus a 1.5 s poll while a
session works, 6 s otherwise), ignores files whose process has exited, and maps `busy` → working, any status mentioning
waiting/approval/input → needs you, else idle. Conversations are never opened.

- **Live activity** (priority below calls, above timers): a slowly turning spark (Canvas, 20 fps) and elapsed time; "Needs you"
  in orange when a session waits; a count when several work. Open row: session name · Working · folder · time · Open.
- **Alerts**: *Claude needs you* (Ping) and *Claude finished · 12m 14s* (Glass) for tasks over 20 s, each with Open. Silent while
  the Claude app is in front. Open brings forward the Claude app, or the terminal/editor that owns a CLI session (walking
  the process tree).
- **Home**: a strip of your three most recent sessions with state and age.

**Ask Claude.** Search offers *Ask Claude “…”* (first when the query reads like a question) and, for words like explain,
summarize, translate or fix, actions on the clipboard. Answers come from the Claude Code bundled in the Claude app
(`~/Library/Application Support/Claude/claude-code/<version>/…/claude`) run as `claude -p --tools "" --no-session-persistence
--output-format stream-json`, streamed into a panel in the island with Copy and Continue in Claude. Not signed in →
Sign In (opens Terminal for `claude auth login`, once) or Ask in Claude (claude.ai with the question filled in).

## Atoll 6.2 — Instruments (the design kit)

The old island used one template for everything (icon tile · two lines · grey circle buttons, inside a
coloured glowing rim). That made it read as a notification banner. The kit replaces it with one rule:
**each activity is an instrument built around the one thing you read it by.**

| Activity | What it's read by | Composition |
| --- | --- | --- |
| Music | the artwork | 58-pt art, title/artist, ghost transport, scrubbable hairline with elapsed / remaining |
| Timer | time left | eyebrow + "Ends 3:15", 40-pt light rounded figure, a dial that is the pause button |
| Meeting | how soon | eyebrow (service · time), title, "5 min" figure, white **Join** pill |
| Download | percent | eyebrow (size), name, "62 %" figure, full-width hairline |
| Call | elapsed | app, eyebrow with live dot, voice waveform, elapsed figure |
| Claude | elapsed / needs you | spark, eyebrow (state · project), session name, figure or **Open** pill |

Pieces (`DesignSystem/Instruments.swift`):

- **Ink** — four whites (100 / 58 / 36 % and a 9 % hairline). Hierarchy comes from ink, never from colour.
- **Figure** — SF Pro Rounded, light from 34 pt up, tabular, numeric-text transitions. Words stay SF Pro.
- **Eyebrow** — 10-pt semibold small capitals, 0.9 tracking, optional **LiveDot** that breathes while live.
- **ContentLight** — the content's colour glowing up inside the black (two gradients, no blur). It replaces
  the coloured rim, which is now a single neutral hairline.
- **Ghost** — a glyph with no chrome until hovered. **Pill** — the one action an instrument exists for:
  white capsule, black type, never more than one per state.
- **ProgressLine** / **Dial** — 3-pt hairlines and 2.5-pt arcs; scrubbable lines thicken under the pointer.

Rules: no icon tiles · no coloured outlines · one hero figure per state · one Pill at most · colour only
from content (art, a running clock, a live signal).

### Closed (compact) states
Same rules beside the notch: the coloured **mark** sits on the left (art, dial, spark), the **figure** on the right in
white SF Pro Rounded. Durations never look like a clock face when they could be read as the time of day:
Claude shows "3m" with its thinking dots and the project name, and a call's elapsed time has a live dot.

## Atoll 6.3 — navigation, Insight, and a real control panel

**Navigation.** Hovering always opens **Home**, the hub — a live activity (Claude, a timer) can no longer take the
island over. Every open state carries a **tab switcher** beside the notch: Home, then each live activity's page,
one click apart (the selected tab takes its activity's colour). A sideways swipe walks the same order, and the
content slides in from the side you're heading, with the shape's morph spring — no fade.

**Insight** (`Brain/Insight.swift`). Every five minutes, off the main thread, the Brain condenses raw observations into:
today by kind of work (and hour by hour), every **project** (time today and this week, active days, apps, recent
documents, usual kind of work), and **taste** (top artists, artists per kind of work, listening hours, skip rate,
main player). **Open loops** combine it with live state: Claude sessions waiting on you, a meeting in the next two
hours, projects you were deep in recently but haven't touched today. Suggestions, the Brain's answers and Settings
all read from it — music suggestions now name the artist you actually play for that work.

**Settings** is a sidebar window with an **Overview** at the top: the day strip, an on-device written brief,
open loops with one-click actions, project cards, and taste. Everything shown is computed on this Mac.

## Atoll 6.3.1 — hover and switching, measured on the real flow

The probe now replays the real path with Claude live: hover swell → Home → tab to Claude → tab Home → close → hover.
Before → after (main-thread work per step; dropped frames at 60 Hz):

| Step | Before | After |
| --- | --- | --- |
| Hover opens Home | 23–34 ms, 1–2 dropped | 5–8 ms, 0 dropped |
| Switch tab | 12–26 ms, 1–2 dropped | ~0 ms, 0 dropped |

What changed:
- **No island-wide drop destination.** `.onDrop` on the whole island made SwiftUI re-reduce drop preferences across
  the tree on every change. File drags are caught by IslandController, which opens the drop view (own targets).
- **Places are kept alive.** Home and each live activity's page are built once and only revealed (like tabs);
  hidden pages stop their clocks (`islandShowing`). Building Home fresh was ~25 ms of button machinery.
- **MarqueeText is plain `Text` unless it overflows** (`ViewThatFits`), no geometry readers for titles that fit.
- **Content zooms by the smaller of width and height ratio**, so an opening island never chops off its content.

## Atoll 6.3.2 — immersive music

**Covers for streamed songs.** Music reports no artwork for tracks streamed from Apple Music (not in the library).
Atoll now asks Apple's public catalog (iTunes Search) with the title and artist, picks the matching result
(title must match; artist and album add confidence) and loads the 600-px cover. Covers are cached per track.

**The colour field.** Each cover is averaged to 6×4 pixels, exposure-normalised (dark covers lifted until they glow,
as Apple Music does), saturated a little, and upscaled once (bicubic). Behind Home and the music instrument it's
stretched into a field of the album's colours that drifts slowly — a Core Animation layer, so the motion runs in
the render server (measured: 1.5 % CPU with Home open and playing, the same as with no field). The top stays black
so the island still melts into the bezel; pausing dims the field and slows it to a stop. The cover is lit from
beneath by its own colours and settles slightly smaller while paused.

## Atoll 6.4 — sound & display, immersive closed state

**Music sync fixed at the root.** Opening Home never re-synced the player (only the music page did), and Atoll
didn't ask the player at launch — so a song already playing never appeared, and its cover never loaded. Home now
re-syncs after its opening spring, and at launch Atoll syncs with players it's already allowed to automate
(checked with `AEDeterminePermissionToAutomateTarget`, never prompting). `atoll://diagnose` writes Atoll's music
state to `diagnostics.json` in its folder, so a build can be checked instead of guessed.

**Controls** (a place of its own: Home › slider button; it joins the tab switcher while open):
- Sound — a Control Center slider (drag anywhere, relative; two-finger scroll; tap the glyph to mute) and the
  output in use with a menu of every device (AirPods, speakers, displays, AirPlay, USB) to switch instantly.
- Display — brightness, Night Shift and True Tone (private DisplayServices / CoreBrightness, loaded at run time;
  anything unsupported doesn't appear).
- Input — microphone mute and which mic; the keyboard backlight.
- Brightness keys now show an island HUD like volume; the volume HUD shows the output device when it isn't the
  built-in speakers.
- Built once a few seconds after launch and kept; display state re-reads after the opening spring.

**Closed state.** Music: the cover glows with its own colours and settles smaller when paused; the waveform is
painted in the album's colours. Claude: the wing grows only when the duration reaches hours ("1h 14m" fits).

## Atoll 6.5 — responsiveness, measured; Search as a command centre

**Hover, tested with a scripted pointer** (`--hover-test`: a virtual pointer drives the real controller along the
paths a hand takes; the real cursor is never moved). 9/9:
pass-through to the menu bar doesn't open · approach-and-rest opens Home within the hover delay · a graze doesn't
open · a brief overshoot and return stays open · leaving closes · closing under a resting pointer stays closed until
the pointer leaves · leaving and returning reopens · an open menu holds the island · after a tab switch, leaving
still closes. Fixes behind them: pointer-speed intent (a pointer moving faster than ~420 pt/s is passing through),
a leave-before-reopen rule, NSMenu tracking, and tabs no longer pinning the island open.

**Music stays in step**: while the player is on screen Atoll re-reads it every 4 s (seeking in Music or Spotify sends
no notification), and the previous cover stays up while the next one loads (no placeholder flash between songs).

**Light, pre-rendered** (`DesignSystem/Glow.swift`). SwiftUI gradients inside the island were rasterised by
CoreGraphics on the main thread every frame of every animation (`ripc_DrawShading`, `rgba64_shade` in samples,
100 ms+ frames when Search opened). All island light — content light, the closed-island light, the rim's fade,
card glows, the music field's masks — is now drawn once into small images the GPU scales and tints. The rim's
travelling sweep is gone (per-frame path work, and decoration Apple wouldn't add).

**Closed island**: light rising behind each side in the content's colours (the cover's two most distinct colours,
Claude's orange, a timer's amber); the centre over the camera stays black.

**Search** — "Search, ask, or tell Atoll what to do":
- *For You* when empty: Claude waiting on you, the next meeting, the project you were deep in, what's playing (or
  the artist you play for this kind of work), and what you just copied (an error becomes "Ask Claude to fix it").
- *Do*: typed commands that act at once — `volume 40`, `mute`, `brightness 70`, `night shift`, `true tone`, an output
  by name (`jbl`, `airpods`, `speakers`), `play`/`pause`/`next`, `play <artist>`, `join` — plus projects and Claude
  sessions by name. Clear commands hide the "Ask Claude…" rows; ⇥ asks anyway.
- A preview beside the list: file thumbnails (Quick Look) with folder, date and size; big answers; the level you're
  about to set; copied text. The field's glyph shows what Atoll thinks you mean; the island takes on the selection's
  colour. The selection follows the top hit until you move it.
- Kept built after launch, like Home: opening is a reveal (16 → 10.6 ms main-thread, 9 → ~2 dropped frames).

## Atoll 6.5.1 — file search off the main thread

Typing a query that matched files froze the island for up to 1.6 s: Spotlight ran on the main thread and every
result's name, type, date and size was fetched with its own blocking XPC round trip (`MDItemCopyAttribute`).
Now the query, its notifications and result reading run on a background queue; results are ranked from batched
attributes (`valueListAttributes`) and only the best few fetch a path. Scope is your folders (home minus Library
and hidden folders), so app data never crowds out real files. Measured: 59–123 → 1–2 dropped frames while typing;
closing from file results 0 dropped.

## Atoll 6.6 — the Brain acts

Atoll's Brain is now an assistant you talk to (the ✦ place: Home's sparkles button, ⇥ on a personal question in
Search, or a suggestion's "Ask"). Apple's on-device model, multi-turn, with ten tools — the only things it can do,
each local, reversible and shown in the conversation as it happens:
`startTimer`, `controlPlayback`, `playMusic`, `setLevel` (volume/brightness), `setDisplayFeature` (Night Shift,
True Tone), `open` (a project's apps, or an app), `remember` (a fact about you), `createReminder`,
`joinNextMeeting`, `handToClaude` (deep questions go to Claude, answered in the notch).

Verified on the real model in dry-run mode (`--agent-check`: tools record, never act) — every request routed right,
1.2–4.4 s: "What did I get done today?" → answered from the day · "25-minute focus and play AP Dhillon" → two tools ·
volume, open project, remember, reminder, pause → one tool each · "Explain Swift actors" → Claude.
Context is the Brain's digest (today, projects, open loops, taste, what you've told it), trimmed for the on-device
window; a long conversation restarts its session automatically. The page is kept built like Home: opening it is
~1 ms; the keyboard is taken after the spring and released after a switch, so focus never costs a moving frame.

## Atoll 6.7 — one project again; covers, perfectly

**Merge.** Atoll had split into two copies (this folder, and a session's working folder). They're one again here:
this folder's work stays as it was — `@Observable` island model, Core Animation loops (`LayerMotion`), faster
springs, live-size zoom, off-main cover decoding, `TransitionCapture` — and 6.5–6.6 is ported on top (file search
off the main thread, Search as a command centre, pre-rendered light, pointer fixes, the Atoll agent). A backup of
this folder from before the merge is in `.merge-backup-*`.

**Covers, fastest first** (`Services/Artwork.swift`): memory → this Mac's cover cache (on disk, per album: a whole
album shows instantly after its first song, and anything heard before shows its cover the moment it starts, across
relaunches) → the player (Music's own cover, or Spotify's) → Apple's catalog.

- **One song counts once.** Music's notification carries no ID for streamed songs and a decimal one for library
  songs, while AppleScript reports a hex persistent ID; keying on those made every song "change" twice — its first
  cover was thrown away, the work done twice, the track-change moment fired twice. Songs are now keyed by player,
  title, artist and album, which every source reports (test: `oneSongCountsOnce`).
- **Catalog matching**: your region's store; titles and albums compared without "(feat. …)", "- Single", "(Deluxe)";
  artists matched by any named artist; the album you're playing breaks ties; nothing below a confident match
  (tests on Apple's real answer for "Kareeb": picks the album version you're playing, refuses a same-title song by
  someone else). Albums it can't match are remembered for six hours.
- **The catalog is never leaned on.** It limits each connection to ~20 requests a minute (a test burst got `403` for
  minutes). Atoll asks once per new song at most, never a blind second request, and backs off 1 → 5 → 15 minutes if
  refused.
- **Scripts compile once.** Each AppleScript is compiled on first use and kept (compiling cost tens of ms a call).
- `atoll://diagnose` reports each cover's source and time (e.g. `music, 55 ms`).

## Mac Flow 7.0 — the brand

Atoll is now **Mac Flow**; its assistant is **Flow**. The mark is a stadium — the island — with a four-point star cut
through it; the star alone is Flow's symbol, used wherever the assistant speaks or acts (its tab, Home's button,
the conversation, Search, Settings). One geometry, fitted to the reference artwork, drives everything:
`scripts/make_brand.swift` (the kit in `brand/`), `DesignSystem/Brand.swift` (the app: `FlowMark`, `FlowStar`,
`FlowGlyph`, `Wordmark`, `FlowLogo`, the menu bar icon), the installer art and the app icon.

- **App icon**: Liquid Glass (Icon Composer) — the black glass pill with the star cut through, on pearl; graphite in
  dark mode.
- **Names**: the bundle, menus, Settings, permission prompts and copy say Mac Flow; the bundle identifier, the data
  folder and window autosave names keep their old values so permissions and settings survive. `macflow://` links work
  alongside `atoll://`. The executable is `MacFlow`; the Swift package product is still `Atoll`.
- **Wordmark**: SF Pro Medium, "Mac" in ink `#0A0A0B`, "Flow" in `#636467` (`#8E8E93` on dark). See
  `brand/README.md` for the font licence note before trademark use.

## Mac Flow 7.1 — Flow waits for you; plan your day

**Flow's inbox** (`Brain/FlowInbox.swift`). A suggestion or question used to live only in its alert: 10–14 s, replaced
by any volume or track alert, dropped entirely if the island was open, and gone for good if missed. Now every one goes
into Flow's inbox and stays until it's answered, dismissed or stops mattering (questions a day, suggestions ~30 min,
plan nudges for the length of their block). It pops once — 30 s for a question, 18 s for a suggestion, held while the
pointer rests on it — and a passing alert over it (volume, a track) gives way back to it afterwards. Missed, it's the
first thing on Home: a violet card that settles in a beat after the island opens, with how long it's been waiting.
While anything waits, the closed island carries Flow's star (`ActivityKind.flow`, lowest priority; the bubble when
something else is live); it opens Home, never a page of its own. A question's alert offers "Answer Later" (it waits on
Home); the card's × is "Don't Ask Again" (three days). Unanswered suggestions count as ignored when they expire — once.

**Plan your day** (`Brain/DayPlan.swift`, `Surfaces/PlanView.swift`). The first unlock, wake or login each morning
(5–12, once a day, never over a call or StandBy) opens the island to the planner — a reveal, since it's prebuilt like
Controls and Flow. Left: three priorities with lengths (click to change, ⌥-click back) and a meeting field that reads
plain words ("Sam at 4pm for 30m", "Design review 2–3pm") and shows what it understood before Return. Right: the day —
a strip from the workday's start to its end with now marked, and the schedule, which re-flows as you type: each
priority takes the earliest free slot after your calendar and added meetings, with a 10-minute buffer and lunch held
at 12:30. Flow's line at the bottom reads the day back ("2h 45m of focus around 3 meetings", or what won't fit).
Start My Day, Skip Today, or Later (× or Esc) — which leaves a "Plan your day" card on Home until lunchtime.

**Guidance** (`DayGuide`). Every 30 s against the saved plan: "Up next" two minutes before each focus block (Start
Focus runs a timer named for it; the timer finishing marks it done), a heads-up five minutes before meetings you
added, a break prompt at lunch, a check-in question between 13:30 and 14:30 (On Track / Behind / Replan), and an
evening wrap-up that asks Flow to recap the day against the plan. Each fires once per block and time, even across
relaunches. Replanning keeps what's behind you and re-flows the rest from now. The plan is in Flow's context; Flow
can add to it (`addToPlan`) or open it (`openDayPlanner`); "plan" in Search and `macflow://plan` open it too. Settings
› Flow › Plan Your Day turns the morning prompt off and sets the workday.

**Fix: frozen at launch.** Device alerts registered with IOBluetooth on the main thread, and IOBluetooth waits for the
Bluetooth permission answer on whichever thread first touches it — so while macOS's prompt was up (every new unsigned
build is a new app to macOS), the whole island was frozen. Permission is now asked through CoreBluetooth on a
background queue; IOBluetooth is touched only once it's allowed.

## Mac Flow 7.2 — rooms, voice, rewind, meetings, your day

**Rooms** (`Brain/Rooms.swift`). A room is the Mac as it was for one piece of work: the apps with windows on screen,
the documents and pages open in them (each window's `AXDocument`, at the Context level with Accessibility — never
pixels, never private windows or excluded apps), what was playing (Spotify's own track id, so the exact song) and
the Claude session in front. A room is saved when a focus block's timer ends (`FocusTimer.onStop`) and, per project,
at most every ten minutes while you work on it. "Set the Room" — the plan's "Up next" nudge, Flow's `setRoom`, Search
on a project — reopens those documents in their apps, hides everything else (Settings › Flow › Rooms), plays the music,
runs your Focus Shortcut (macOS has no API for apps to turn on Focus; `shortcuts run`) and starts a quiet timer;
its partner Shortcut runs when the block ends. "Pick up X" suggestions and open loops now resume rooms, not just apps.
While a block runs, Flow keeps its own suggestions to itself.

**Rewind** (`Surfaces/RewindView.swift`). Moments — mode, project, app, title, document, song, Claude session — are
written every five minutes and at each change (`MomentRecorder`, a `moments` table with the same retention as the
rest). Rewind is today as a ribbon coloured by kind of work: drag the playhead, swipe with two fingers, or use ←/→;
the moment shows above with Reopen (its room) and Ask Flow. Flow's `recall` answers "what was I doing at 3?" and
opens Rewind there. Search: "rewind", "what was I…".

**Hold the notch and talk** (`Brain/Speech.swift`). Press and hold the closed island — or the notch itself when it's
open — for 0.45 s: Flow's conversation opens listening, with live words and a level meter; let go and the words go
to Flow as if typed. Speech is recognised on this Mac (`requiresOnDeviceRecognition`); audio is never kept. New tools:
`moveEvent` ("move my 3 o'clock to tomorrow" — keeps the length; events with other people are left to Calendar so
they're notified), plus `setRoom`, `resume`, `recall`, `showDay`, `meetingNotes`.

**Meeting companion** (`Brain/MeetingCompanion.swift`). A call or meeting row grows a strip: minutes left and the
agenda (the invite's notes, minus dial-in boilerplate). With notes offered (Settings › Flow, off by default), "Take
Notes" asks you to tell the room, then transcribes on this Mac — you from the microphone, the others from the Mac's
audio through a Core Audio process tap (macOS 14.2+, "System Audio Recording" permission) — with a red dot on the
island the whole time. When the call ends (or Stop), Flow writes it up with the on-device model (`@Generable`
summary and action items; a sentence heuristic without it), saves Markdown in Mac Flow's Meetings folder, and offers
"Add to Tomorrow" — carried items fill the next morning's empty priorities.

**Your day** (`Surfaces/DayArtView.swift`). A ring from the first moment you sat down: each stretch of work an arc
in its colour (deep work thicker), meetings on an inner track, every song a dot outside (a stable colour per artist),
Flow's star for each priority finished, focus hours in the middle, and a line that reads the day back — computed,
never invented. It draws itself in as it opens; Save Image writes a 3× card to ~/Pictures/Mac Flow. The evening
wrap-up now opens it; "my day" in Search and Flow's `showDay` too.

**Measured.** All three new places are prebuilt like the planner (switching to each: 0 dropped frames); idle Home with
music 0.5% CPU. Audio engines are created only when someone talks (an `AVAudioEngine` made at launch cost real CPU).
The perf probe's CPU figure now covers only its steady window (it had been dividing every later step by 2 s), and
`ATOLL_NOCAPTURE=1` runs it without frame captures.

## Mac Flow 7.3 — Now; Flow drafts the morning; Control Center modules

**Now** (`Brain/Now.swift`). The island stops being a set of places and follows the day. Home's top slot shows the one
thing that matters, in order: Flow's question or suggestion → a meeting starting within ten minutes or under way
(Join, or Take Notes) → the focus block running (its ring, time left, its room; Pause, End) → the plan's next block
within 45 minutes (Set the Room) → the morning plan, unmade (Plan) → the evening, after the workday (See Your Day).
One row, one surface (`FlowCardBackground(tint:)` in the moment's colour), one settle-in; nothing at all when nothing
needs you. Every non-Flow moment is the same height, so moving between them never resizes the island. × hides a
moment for the day.

**Flow drafts the morning.** A day's unfinished priorities carry into the next (with where they came from), as do a
meeting's action items ("From Design Review"); the planner opens with them filled in, plus your main project this week
if there's room. Each draft shows Flow's star (hover for its source) until you type over it; Flow's line says "Drafted
from yesterday — change anything". Carried items have one morning; the keyboard goes to the first empty priority, not
into a draft.

**Controls** rebuilt as Control Center modules: each says what it is and its reading (Sound 72%, Display 100%), the
output and microphone show their full names (two lines if needed), Night Shift and True Tone are labelled tiles.

**Permissions** (Settings › Permissions): every permission, what it's for, live status, "Ask" (macOS's prompt for this
exact build — which also cures a switch that looks on but belongs to an older build) and "Open" (the exact pane). And
how to keep them across updates without a developer account: a self-signed "Mac Flow Local" code-signing certificate,
which `scripts/build.sh` uses automatically when present, so macOS sees each build as the same app.

Also: the Claude strip shows two sessions — the first at its full name — and "+N", never three cut short. Moving an
event reads "tomorrow" from now and keeps a bare time on the event's own day.

## Mac Flow 7.3.1 — smooth, measured on the release build

Measured with the probe built into a release binary (`swift build -c release -Xswiftc -DATOLL_PROBE`), and a new
`ATOLL_LOOP=1` mode that repeats each everyday move eight times and reports medians (single runs varied 28–70 dropped
frames with nothing changed). Three causes, three fixes:

- **Parked places followed the animation.** Every built place read the island's live size and rescaled to it on every
  frame of every spring — so each animation resized every text field and menu in Home, Controls, Flow, the planner,
  Rewind and your day at once. A parked place now holds still and never reads the live size (`IslandPresentation.parked`).
- **Opacity 0 threw pixels away.** A place at 0 opacity keeps no rendered layers, so showing one redrew all its text
  and controls on the main thread in the transition's first frame (40–50 ms). Parked places sit at 0.001: rendered,
  invisible, free to show. While the island has the keyboard they drop to 0 (becoming key redraws every rendered
  control), and are parked again 0.7 s after it lets go.
- **Synchronous work in the first frames.** Display state (brightness, Night Shift, True Tone, keyboard) is read on a
  queue of its own instead of the main thread; the planner takes the keyboard after its sections settle.

Release, eight repetitions each — open Home, back to Home, close Home, open and close music: 0 dropped frames (they
dropped 1–12 before, with 70–110 ms frames). Opening Search still costs 2–4 frames at the start (SwiftUI's commit of the
largest view, unchanged by these fixes); closing it, 0–1.

## Mac Flow 7.4 — Flow learns; Flow Lens; the sheet; the living island; dimmed focus

**Flow learns how you work** (`Brain/Patterns.swift`). From four weeks of your sessions (refreshed every six hours, off
the main thread): deep work by hour, the best two-to-three-hour focus window, when your day starts and ends, how long a
focus session lasts, whether music lengthens it (sessions with a track starting during them vs not), the hour you
switch apps most, the meeting-heaviest weekday — and plain sentences for each. It acts on them: the planner puts your
first priority into your sharpest window when it fits there (`PlanScheduler.schedule(focusWindow:)`), Flow's line says
so, a "Your sharpest hours start now" nudge offers to set the room (skipped when a meeting is about to take them), and
Flow's context carries what it has learned. Settings › Flow shows your rhythm (24 bars, the best window lit) and the
sentences. Silent until there are three days to learn from.

**Flow remembers** (`Brain/Memory.swift`). An on-device semantic index (Apple's NaturalLanguage sentence embedding,
cosine similarity, a gentle preference for recent): an hour of work at a time from Rewind's moments ("10–11 AM: coding on
Atoll in Xcode (PlanView.swift, Rooms.swift), listening to M83"), each session's summary, finished priorities, meeting
write-ups and what you told Flow. Every question to Flow carries its five closest memories; `searchMemory` lets Flow
look further ("when did I last work on pricing?"). Capped at 4,000 memories; erased with the Brain.

**Flow Lens** (`Brain/Lens.swift`). Copy something with an obvious next step and the notch offers it: a time and a
place → Add to Calendar / Remind Me; a long passage → Summarize / Find Tasks (into your next plan); a message that asks
you something → Draft Reply; another language → Translate. Links, code, secrets and ordinary text show nothing; at most
once a minute; never over a call or from excluded apps. Drag a PDF, an image (Vision reads its words) or a text file
onto the notch's new **Ask Flow** target for the same. All on this Mac.

**The sheet** (`Surfaces/FlowSheet.swift`). Two fingers down on Home — or a click on its grabber — pulls the island into
a sheet: the day's ring and line, what's next, your rhythm; what's playing with its artwork large; a line to Flow. Two
fingers up or Esc put it back.

**The living island.** With nothing playing, Home is lit by the moment instead of black — morning peach and rose, midday
sky and teal, ember and amber during a focus block, evening magenta and indigo, deep night blues — rendered once per
mood and drifted by the same render-server layer as the album field (no per-frame cost). Artwork lifts toward the
pointer with a soft travelling highlight (2D: a 3D rotation cost 6–10 frames whenever Home reappeared over the light).

**Dimmed focus** (`Services/FocusDimmer.swift`). While a focus block runs, everything but the window you're in dims
behind a feathered edge that follows it (the window server's front-to-back order, not "frontmost app", which lagged);
clicks pass through; the menu bar and notch stay lit; breaks don't dim. Settings › Flow › Rooms.

## Mac Flow 7.5 — a learning brain; your browser; the Brief; Learn

**Habits** (`Brain/Habits.swift`). A personal model of what you do next. Every switch in three weeks of moments is an
example: the situation — app, window title, project and mode, embedded with Apple's on-device sentence model, plus the
time of day on a circle and weekend — and what came next. Asked at a turning point (back from a pause, out of a meeting
or messages), it finds the fourteen most similar past situations, lets them vote by similarity, and suggests the winner
only if it has at least 60% of the weight and six supporters ("Back to Atoll? · what you usually do now · 74% of
moments like this"); the project's room if one's saved. Retrained every four hours. The clearest transitions become
sentences in Settings and in Flow's context ("After Zoom you usually go to Xcode").

**Suggestions learn the time of day.** Acceptance is now counted per part of the day (morning, afternoon, evening) and
blended with the overall rate, so a nudge you take at 10 and wave away at 4 keeps to the morning. Fixed on the way:
every suggestion *shown* had been counted as half an ignore — even ones you then took — making Flow quietly timid.

**Your interests, as a vector** (`Memory.interest`): the recency-weighted mean of what you worked on, read, saved and
discussed — used to rank the Brief.

**Your browser** (`Brain/Browser.swift`). In Chrome, Arc, Brave, Edge or Safari, Now shows the page you're reading with
Summarize and Save to Learn; Flow's `readPage` tool and the sheet's Learn page do the same. The page's words come from
the browser itself (it needs "Allow JavaScript from Apple Events" turned on in that browser — Flow says how when it's
off) and stay on this Mac. "Ask About It" hands the page to Flow as context for your next question. Pages you read go
into memory.

**The Brief** (`Services/News.swift`). Headlines from feeds you choose (Hacker News, The Verge, Apple Newsroom on by
default; Ars Technica, BBC and your own RSS/Atom in Settings › Flow), fetched every 45 minutes with an ephemeral,
cookie-less session — the only network traffic Flow makes for itself — and ranked on this Mac by closeness to your
interest vector; the ones for you carry Flow's star. In the sheet's Brief page; Flow's `news` tool answers "what's new
in…".

**Learn** (`Brain/Learn.swift`). Save a page or a passage (Now, the sheet, Flow, or Flow Lens's new Save to Learn) and
the on-device model writes two to four question-and-answer cards from it — only from what you saved; without the model,
its clearest sentences become cards. They come back at quiet moments — after a pause or a focus block, at most six a day,
45 minutes apart — as a card in the notch: Show Answer, then Again (ten minutes), Got It or Easy (a day, three days,
then growing). The sheet's Learn page reviews what's due.

**The sheet** now has three pages — Today, Brief, Learn — switched at the top. Its day runs 4 AM to 4 AM (work at 1 AM
belongs to the day it ends), songs are a continuous soundtrack ribbon round the ring, and "Next" says something useful
at any hour.

## Mac Flow 8.0 — StandBy, reimagined

Feedback: StandBy should feel immersive and finished, play the song you're listening to with lyrics that float like
Apple Music's, and sit on clean 4K wallpapers. A first pass with flat, illustrated pictures and imitation-glass digits
was rejected as "basic — Apple works clean and in deep". This is the second. StandBy stays opt-in (Settings › StandBy,
⌃⌘S).

**Wallpapers, rendered.** Original 3840 × 2400 pictures (`Resources/Wallpapers`), each a real 3D render made on
the GPU by `scripts/wallpapers` — a small Metal path: every scene is a function that traces one ray, and the host
averages 48 jittered samples per pixel (antialiasing, soft sun shadows, depth of field, dispersion), then grades through
AgX and dithers into HEIC. Skies and haze come from a physically based single-scattering atmosphere (Rayleigh + Mie),
so light, colour and distance agree. No stock or licensed imagery.
- *Dunes* — one great dune late in the afternoon, Mojave's picture: a knife-edge crest built from a line, an arc and a
  line with matching tangents (no creases), the windward face warm in low sun, the slip face falling into shadow.
- *Silk* — satin ribbons in a dark space; *Horizon* — the open sea at dusk, glitter path to a low sun.
- 8.0 ships these three. Alpine, Aurora and Glass have scene files in `scripts/wallpapers` that weren't finished; a
  picture appears in Settings as soon as its HEIC is in `Resources/Wallpapers` and listed in `Wallpapers.all`.
- *Depth* — a scene can mark its nearest landform while rendering; its sample coverage becomes the alpha
  of a separate layer (`<id>-depth.heic`), pixel-identical to the picture. The clock is drawn between the two, so the
  ridge tucks over the lower part of the time, as on the iPhone lock screen.

**The stage.** Every page sits on one backdrop (`StandBy/StandByBackdrop.swift`) drawn as Core Animation layers, so its
motion runs in the render server: the picture drifts in a slow 70-second loop (scale 1.06 → 1.12, a 1.5 % pan) and the
depth layer moves with it exactly (both start from one shared epoch). On Now Playing the backdrop becomes the cover:
four soft fields of its colours turning slowly against each other, Apple Music's animated background; pausing stills it.
At night (22:00–06:00 with Night Mode) the backdrop goes black and everything drawn on it turns dim red.

**Clock.** The default **Glass** face is the system's Liquid Glass (macOS 26) in the exact outline of the time:
SF Pro's own glyphs — condensed semibold, tabular figures, a smaller colon centred on them — become one shape, and the
picture bends through it with light along its edges. Before macOS 26 the figures are frosted out of the wallpaper
instead. Around it, as little as possible: the date with the weather beside it, one line; below, a glass pill only for
what matters now (the next event, charging). Digital and Float stay, solid; Analog sits on a disc of glass. Widgets
stand in glass cards.

**Now Playing, with lyrics.** While music plays, StandBy opens on Now Playing (and turns to it when a song starts).
The cover sits left with title, artist and time; the lyrics float right:
- The line being sung is full white; the others recede to 34 % and soften with distance. When the line changes, every
  line rises on its own spring, each a few hundredths of a second after the one above — the staggered float of Apple
  Music. The current line sits a third of the way down; the column fades out at its edges.
- Breaks of five seconds or more (an intro, a solo) show three dots that fill across the break, breathing, then fold.
- Lyrics without timing glide with the song's progress. With none, the player takes the centre.
- Space plays and pauses; L shows or hides lyrics; ↑ ↓ on the clock change the picture.

**Where lyrics come from** (`Services/Lyrics.swift`). Apple Music doesn't give other apps its time-synced lyrics, so
Mac Flow reads the song from Music (or Spotify) as before and asks **LRCLIB** (lrclib.net, open, free, no account) by
title, artist, album and length — the fields the cover lookup already sends to Apple's catalog. A match must agree on
title and artist and be within 3 s; synced wins over plain. Failing that, the lyrics Music keeps with the track. Answers,
including "none", are cached per song on this Mac. Only fetched while StandBy shows Now Playing; off with Show Lyrics.

**Care.** Text drifts a few points a minute against burn-in; the display is held awake only on power and for at most an
hour; StandBy never starts over video, presentations or calls. Reduce Motion stills the backdrop and turns the lyric
float into a cross-fade.

**Checked on the real screen.** `Atoll --standby-check <dir>` opens StandBy for a few seconds and captures only Mac
Flow's own window on each page (Liquid Glass draws only on screen); `--standby <dir>` renders every page offscreen.

**Also in 8.0: reading pages, fixed.** Summarize and Explain ran inside Flow's chat session, whose 21 tools, day digest
and memories already fill most of the on-device model's ~4,000-token context — a page on top overflowed it, the one
retry was the same size, and asking from the chat was dropped because Flow was still mid-answer. Page work now has its
own small session (`Mind.onPage`) with no tools, the page's opening and a little of its end, shrinking by half until it
fits; it streams into the conversation under a one-line label instead of the whole page as your message. Save to Learn
shrinks the same way and no longer hides the error. When macOS hasn't allowed Mac Flow to control the browser, the island
says so and opens Privacy & Security › Automation; when the browser's "Allow JavaScript from Apple Events" is off, it
says how to turn it on. Night Mode's red is now opt-in, and never covers Now Playing.
