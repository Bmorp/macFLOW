# Mac Flow v2 — "The notch that thinks" — treatment

## What the references taught (watched frame by frame, 23 Oct 2026)

| Reference | What Apple does | What v1 did instead |
| --- | --- | --- |
| iPhone 14 Pro Dynamic Island reveal | Opens on **pure black**: the pill alone, lit by a violet rim light. Then the device top in **low-angle 3D** with a floor reflection. The island fills **half the frame**; the camera tilts into it. | Flat 2D screen on a pastel wallpaper, island at a third of the frame. |
| "Dynamic Notch" concept (3.1M views) | Liquid colour shapes → the notch shape glowing alone → extreme low angles with motion blur → one word on black → logo. 16 s, every shot moving. | Long static holds; same framing for minutes. |
| iOS 26 "Introducing Liquid Glass" | UI at **macro scale** with a **3D tilt and shallow depth of field**; the **material itself** as an abstract hero (glass ribbons, a droplet on black, giant 9:41 numerals). Bright frames alternate with dark ones. | No material moments, no depth, no light. |
| MacBook Pro M5 Pro/Max (1:41) | Kinetic type **typed letter by letter** on a clean ground; spec lines set *into* the scene; 1–2 s shots; macro detail. | Titles faded in under the UI. |
| Mac mini M6 (0:43) | The product becomes a **character** that grows in power; ends on one line + product. | — |

Shared grammar: one idea per shot, hero object huge and lit, constant camera motion, dark ↔ bright rhythm, type as
design, sound locked to the cut (premium licensed music, few but crisp effects, sub hits, silence before drops).

## The one thing

**Your Mac's notch just got a brain.** Flow learns how you work — on your Mac, privately — and speaks up at exactly
the right moment, then does it for you.

## Every claim is in the code (Brain/*.swift)

- Learns at a depth you choose: **Essentials · Context · Everything** (Everything reads the window you're in with
  Apple's Vision, on-device, never password managers or private windows).
- Understands **what you're doing** (Coding, Writing, Designing, In a meeting…), your projects, routines, music taste.
- **One suggestion at the right moment**, scored by what you accepted before:
  "Good morning — continue Mac Flow?" · "Design Review in 5 min — a timer to wrap up?" · "1h 40m of coding — a short break?" ·
  "Protect the next 25 minutes? 14 app switches in the last 15 minutes" · "Want help with that error?" ·
  "Open Figma too? You open it after Slack 86% of the time" · "Daft Punk for coding?" · "Want a quick recap of today?"
- **Asks while it learns** ("Do you like music while coding?").
- **Does it for you** — timers, music, volume, brightness, reminders, open your project, join the meeting, hand off to Claude.
- **Answers about your day** ("What did I get done today?").
- **Thinks with Apple's on-device model. Nothing leaves your Mac.**

## Shape (about 60 s, 120 BPM, 4K)

| s | Beat | Picture | Sound |
| --- | --- | --- | --- |
| 0–4 | Cold open | Pure black. A violet line draws the island's outline; the pill appears, rim-lit. | Sub swell, a single glassy tick |
| 4–9 | The Mac | Low-angle 3D MacBook on a dark stage, rim-lit aluminium; camera glides along the lid edge to the notch. Type: "Your notch." | Pulse enters |
| 9–12 | Ignition | The island fills the frame; Flow's star ignites inside it. "Meet Flow." | First hit |
| 12–20 | It learns | Macro, tilted, depth of field: the real work modes and projects stream into the island; the three depths. "It learns how you work." | Build |
| 20–34 | The right moment | **Hype core**: 7 real suggestion cards, one per beat, each a different camera move (whip, push, tilt); a cursor accepts one, the action happens. "It speaks up at the right moment." | Drop, cuts on the beat |
| 34–42 | Just ask | Flow chat: "Focus for 25 minutes and play some music" → the actions land → the island splits. "What did I get done today?" → the answer. | Breakdown, keys |
| 42–47 | Private | Camera pulls out through the screen to the whole Mac in the dark: everything stays inside. "On your Mac. Nothing leaves." | Near silence |
| 47–53 | Everything else | 2× montage of Live Activities (music, calls, timers, AirPods, builds). "Plus everything live." | Last chorus |
| 53–60 | End | The island drops off the bezel into the mark; the star ignites; "Mac Flow — The notch that thinks." | Riser → final hit, ring-out |

## Craft targets

- 3840×2160 (composition rendered at 2× device pixels), island frames re-rendered at 5× from the app.
- A real-time 3D MacBook (Three.js, physically based aluminium, area-light rim, floor reflection) for the hardware shots.
- UI shots: 6–14° tilts with depth-of-field falloff, motion blur on every fast move.
- Music: a professionally produced, licensed track (not synthesised). Effects: curated, licensed foley-style UI sounds.
