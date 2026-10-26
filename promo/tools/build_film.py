"""Generates the Mac Flow film: compositions/stage.html, compositions/titles.html and index.html.

The island frames in assets/frames were rendered from the app's own SwiftUI views (film harness, 3x, transparent).
This script only places them on the beat grid and builds the world, camera, cursor and type around them.
Run from the project root:  python3 tools/build_film.py
"""
import json
import math
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FPS = 30
DUR = 46.5
M = json.load(open(os.path.join(ROOT, "assets/frames/manifest.json")))
OX = 735 - 382  # canvas x of the island's centre (382 pt) sits on the screen's centre (735 pt)
SCREEN_W, SCREEN_H = 1470, 956


def r4(x):
    return f"{x:.4f}".rstrip("0").rstrip(".") if abs(x) > 1e-9 else "0"


# ---------------------------------------------------------------- island frames

clips = []  # (seq, idx, start, end)


def show(seq, t0, idxs, hold_until=None, step=1):
    """Show frames `idxs` of `seq`, one every `step` video frames from t0; hold the last until `hold_until`."""
    for k, i in enumerate(idxs):
        s = t0 + k * step / FPS
        e = t0 + (k + 1) * step / FPS
        if k == len(idxs) - 1 and hold_until is not None:
            e = max(e, hold_until)
        clips.append((seq, i, s, e))
    return t0 + len(idxs) * step / FPS


def hold(seq, idx, t0, t1):
    clips.append((seq, idx, t0, t1))


hold("notch", 0, 0.0, 6.0)
show("wake", 6.0, list(range(0, 25, 2)), hold_until=None)
hold("wake", 36, 6.0 + 13 / FPS, 6.5)
show("expandMusic", 6.5, list(range(0, 45)), hold_until=8.3)
hold("meetingCompact", 0, 12.25, 13.0)
show("expandMeeting", 13.0, list(range(19)), hold_until=14.0)
show("meetingToCall", 14.0, list(range(19)))
t_call = 14.0 + 19 / FPS
hold("callTick", 0, t_call, 15.0)
hold("callTick", 1, 15.0, 16.0)
hold("callTick", 2, 16.0, 16.1)
hold("notch", 0, 16.1, 16.25)
t = show("openFlow", 16.25, list(range(19)))
t = show("flowType", t, list(range(22)))
hold("flowChat", 0, t, 18.0)
hold("flowChat", 1, 18.0, 18.5)
hold("flowChat", 2, 18.5, 18.8)
show("flowChat", 18.8, list(range(3, 12)), step=2)
hold("flowChat", 12, 18.8 + 9 * 2 / FPS, 20.0)
show("flowClose", 20.0, list(range(16)), hold_until=20.6)
show("split", 20.6, list(range(60)))
show("splitToBuild", 22.6, list(range(19)))
show("buildRun", 22.6 + 19 / FPS, list(range(46)))
show("buildDone", 22.6 + 65 / FPS, list(range(13)), hold_until=25.4)
show("buildClose", 25.4, list(range(16)))
hold("notch", 0, 25.4 + 16 / FPS, 26.0)
show("airpodsOpen", 26.0, list(range(19)))
hold("airpodsHold", 0, 26.0 + 19 / FPS, 27.5)
show("airpodsClose", 27.5, list(range(16)))
hold("notch", 0, 27.5 + 16 / FPS, 28.9)
show("dropOpen", 28.9, list(range(19)))
hold("dropTarget", 0, 28.9 + 19 / FPS, 29.6333)
show("dropToShelf", 29.6333, list(range(11)), hold_until=30.0)
frame0 = lambda k: 900 + math.floor(7.5 * k + 0.5)
for k in range(11):
    f0, f1 = frame0(k), (frame0(k + 1) if k < 10 else 990)
    for f in range(f0, f1):
        clips.append((f"montage{k:02d}", min(7, f - f0), f / FPS, (f + 1) / FPS))
for f in range(33):
    clips.append(("openHome", min(48, round(1.5 * f)), 33.0 + f / FPS, 33.0 + (f + 1) / FPS))
hold("homeHold", 0, 33.0 + 33 / FPS, 35.0)
hold("homeHold", 1, 35.0, 36.0)
hold("homeHold", 2, 36.0, 36.5)
show("closeHome", 36.5, list(range(16)))
show("sleep", 40.0, list(range(16)))
hold("notch", 0, 40.0 + 16 / FPS, 40.75)
# the song's content stays a beat longer and fades as the island sleeps (see #isl-fadeout in the timeline)
clips.append(("closeHome", 15, 36.5 + 16 / FPS, 40.1))

used = sorted({(s, i) for s, i, _, _ in clips})


def img_tag(n, seq, idx, s, e, extra_id=None):
    m = M[seq]
    s2 = max(0.0, s - 0.25 / FPS)
    e2 = e - 0.25 / FPS
    cid = extra_id or f"isl-{n:04d}"
    return (f'<img id="{cid}" class="clip isl" data-start="{r4(s2)}" data-duration="{r4(e2 - s2)}" '
            f'src="assets/frames/{seq}/{idx:04d}.png" alt="" '
            f'style="left:{r4(OX + m["x"])}px;top:{r4(m["y"])}px;width:{r4(m["w"])}px;height:{r4(m["h"])}px" />')


island_html = []
for n, (seq, idx, s, e) in enumerate(sorted(clips, key=lambda c: c[2])):
    extra = "isl-fadeout" if (seq == "closeHome" and idx == 15 and s > 37.02) else None
    island_html.append(img_tag(n, seq, idx, s, e, extra))

# ---------------------------------------------------------------- the display

menu_left = ["File", "Edit", "View", "Go", "Window", "Help"]
dock = ["finder", "safari", "messages", "mail", "facetime", "calendar", "notes", "music", "photos", "xcode", "terminal", "settings", "|", "macflow", "|", "trash"]
running = {"finder", "safari", "music", "xcode", "terminal", "macflow"}
dock_html = []
for d in dock:
    if d == "|":
        dock_html.append('<div class="dock-sep"></div>')
    else:
        dot = '<i class="run"></i>' if d in running else ""
        dock_html.append(f'<div class="dock-item"><img src="assets/ui/dock-{d}.png" alt="" />{dot}</div>')

# ---------------------------------------------------------------- the end card shapes (frame space)

def island_path(x0, y0, w, h, shoulder, corner):
    """IslandShape.build, ported: the top edge runs wider than the body and curves down into it."""
    s = max(0, min(shoulder, w / 4, h / 2))
    reach = max(0, min(corner * 1.25, h - s, (w - 2 * s) / 2))
    k = 0.32
    p = [f"M{x0:.2f} {y0:.2f}",
         f"C{x0 + s * 0.62:.2f} {y0:.2f} {x0 + s:.2f} {y0 + s * 0.38:.2f} {x0 + s:.2f} {y0 + s:.2f}",
         f"L{x0 + s:.2f} {y0 + h - reach:.2f}",
         f"C{x0 + s:.2f} {y0 + h - reach * k:.2f} {x0 + s + reach * k:.2f} {y0 + h:.2f} {x0 + s + reach:.2f} {y0 + h:.2f}",
         f"L{x0 + w - s - reach:.2f} {y0 + h:.2f}",
         f"C{x0 + w - s - reach * k:.2f} {y0 + h:.2f} {x0 + w - s:.2f} {y0 + h - reach * k:.2f} {x0 + w - s:.2f} {y0 + h - reach:.2f}",
         f"L{x0 + w - s:.2f} {y0 + s:.2f}",
         f"C{x0 + w - s:.2f} {y0 + s * 0.38:.2f} {x0 + w - s * 0.62:.2f} {y0:.2f} {x0 + w:.2f} {y0:.2f}Z"]
    return " ".join(p)


END_S = 2.6                      # camera scale on the end card
END_FY = 540 / END_S             # screen top on the frame top
notch_fx = 960 + (OX + M["notch"]["x"] - 735) * END_S
NOTCH_SH = 10 * END_S
notch_w = 199 * END_S
notch_h = 32 * END_S
notch_d = island_path(notch_fx, 0, notch_w, notch_h, NOTCH_SH, 10 * END_S)
body_x = notch_fx + NOTCH_SH
body_w = notch_w - 2 * NOTCH_SH

menu_mark_d = open(os.path.join(ROOT, 'assets/brand/macflow-mark-black.svg')).read().split(' d="')[1].split('"')[0]
stacked = open(os.path.join(ROOT, "assets/brand/macflow-logo-stacked-light.svg")).read()
paths = re.findall(r'<path fill="(#[0-9A-Fa-f]{6})"(?: fill-rule="evenodd")? d="([^"]+)"', stacked)
mark_d = paths[0][1]
star_d = "M" + mark_d.split("ZM", 1)[1]  # the star, the second subpath of the mark
word_paths = paths[1:]
# Lockup: the mark 360 px wide, centred at (960, 412); the stacked file's mark is 404 x 128 units at (191.83..595.83, 64..192).
LK = 360 / 404
LX = 960 - 393.83 * LK
LY = 412 - 128 * LK
mark_x, mark_y, mark_w, mark_h = 191.83 * LK + LX, 64 * LK + LY, 404 * LK, 128 * LK
word_svg = "".join(f'<path fill="{c}" d="{d}"/>' for c, d in word_paths)

# ---------------------------------------------------------------- stage.html

stage = f"""<template>
  <style>
    @font-face {{ font-family: "SF Pro"; src: url("assets/fonts/SFNS.ttf"); font-weight: 1 1000; }}
    #root {{ position: absolute; inset: 0; overflow: hidden; background: #0a0a0b; font-family: "SF Pro"; }}
    #cam-whip {{ position: absolute; inset: 0; }}
    #cam-center {{ position: absolute; left: 960px; top: 540px; width: 0; height: 0; }}
    #cam-scale {{ position: absolute; left: 0; top: 0; width: 0; height: 0; }}
    #cam-focus {{ position: absolute; left: 0; top: 0; width: {SCREEN_W}px; height: {SCREEN_H}px; }}
    .bezel {{ position: absolute; left: -16px; top: -18px; width: {SCREEN_W + 32}px; height: {SCREEN_H + 40}px;
             background: #050506; border-radius: 26px; box-shadow: 0 0 0 1.5px #1c1c1f, 0 0 0 3px #3a3b40; }}
    .screen {{ position: absolute; left: 0; top: 0; width: {SCREEN_W}px; height: {SCREEN_H}px; overflow: hidden;
              border-radius: 10px 10px 2px 2px; background: #f7efe6; }}
    .wall {{ position: absolute; left: 0; top: 0; width: {SCREEN_W}px; height: {SCREEN_H}px; }}
    .menubar {{ position: absolute; left: 0; top: 0; width: {SCREEN_W}px; height: 32px; color: #0a0a0b;
               font-size: 13px; letter-spacing: -0.005em; }}
    .mb {{ position: absolute; top: 0; height: 32px; line-height: 32px; white-space: nowrap; }}
    .mb b {{ font-weight: 700; }}
    .mb span {{ margin-right: 12px; font-weight: 500; }}
    .sym {{ position: absolute; top: 5px; width: 30px; height: 22px; }}
    .mb-mark {{ position: absolute; top: 11px; width: 24px; height: 10px; }}
    .dock {{ position: absolute; left: 50%; bottom: 6px; height: 72px; transform: translateX(-50%);
            display: flex; align-items: center; gap: 4px; padding: 0 10px; border-radius: 24px;
            background: rgba(255, 255, 255, 0.34); box-shadow: inset 0 0 0 0.75px rgba(255, 255, 255, 0.65), 0 10px 30px rgba(60, 20, 40, 0.18); }}
    .dock-item {{ position: relative; width: 58px; height: 58px; }}
    .dock-item img {{ width: 58px; height: 58px; }}
    .dock-item .run {{ position: absolute; left: 27px; bottom: -6px; width: 4px; height: 4px; border-radius: 2px; background: rgba(20, 10, 20, 0.7); }}
    .dock-sep {{ width: 1px; height: 50px; margin: 0 6px; background: rgba(40, 20, 30, 0.22); }}
    .desk-file {{ position: absolute; width: 96px; text-align: center; }}
    .desk-file img {{ width: 66px; height: 66px; filter: drop-shadow(0 2px 3px rgba(0,0,0,0.18)); }}
    .desk-file div {{ font-size: 12px; font-weight: 600; color: #fff; text-shadow: 0 1px 2px rgba(0,0,0,0.55); line-height: 15px; }}
    .flood {{ position: absolute; }}
    #flood-indigo {{ left: 0; top: 0; width: {SCREEN_W}px; height: {SCREEN_H}px; background: #5e5ce6; clip-path: circle(0px at 735px 0px); }}
    #flood-paper {{ left: -400px; top: -400px; width: {SCREEN_W + 800}px; height: {SCREEN_H + 800}px; background: #ffffff; clip-path: circle(0px at 1135px 400px); }}
    #reveal {{ position: absolute; left: 0; top: 0; overflow: visible; }}
    #island {{ position: absolute; left: 0; top: 0; width: {SCREEN_W}px; height: {SCREEN_H}px; }}
    .isl {{ position: absolute; }}
    .cursor {{ position: absolute; left: 0; top: 0; }}
    .cursor img {{ position: absolute; }}
    #endcard {{ position: absolute; inset: 0; }}
    #endcard svg {{ position: absolute; left: 0; top: 0; }}
  </style>
  <div id="root" data-composition-id="stage" data-width="1920" data-height="1080">
    <div id="cam-whip">
      <div id="cam-center"><div id="cam-scale"><div id="cam-focus">
        <div class="bezel"></div>
        <div class="screen">
          <img class="wall" src="assets/img/wallpaper.jpg" alt="" />
          <div class="flood" id="flood-indigo"></div>
          <div class="menubar">
            <img class="sym" style="left:6px" src="assets/ui/sym-apple.logo-black.png" alt="" />
            <div class="mb" style="left:38px"><b style="margin-right:12px">Finder</b>{"".join(f"<span>{w}</span>" for w in menu_left)}</div>
            <svg class="mb-mark" style="left:1158px" viewBox="64 64 404 128"><path fill="#0a0a0b" fill-rule="evenodd" d="{menu_mark_d}"/></svg>
            <img class="sym" style="left:1190px" src="assets/ui/sym-battery.75percent-black.png" alt="" />
            <img class="sym" style="left:1224px" src="assets/ui/sym-wifi-black.png" alt="" />
            <img class="sym" style="left:1256px" src="assets/ui/sym-magnifyingglass-black.png" alt="" />
            <img class="sym" style="left:1286px" src="assets/ui/sym-switch.2-black.png" alt="" />
            <div class="mb" style="left:1328px; font-weight:500">Fri 23 Oct&nbsp;&nbsp;10:30</div>
          </div>
          <div class="dock">{"".join(dock_html)}</div>
        </div>
        <div class="flood" id="flood-paper"></div>
        <svg id="reveal" width="{SCREEN_W}" height="{SCREEN_H}" viewBox="0 0 {SCREEN_W} {SCREEN_H}">
          <rect id="reveal-rect" x="505" y="-30" width="460" height="140" rx="30" ry="30" fill="#000" opacity="0" />
        </svg>
        <div id="island">
          {chr(10).join("          " + h for h in island_html)}
        </div>
        <div class="cursor" id="cur">
          <div class="desk-file" id="drag-file" style="left:-48px;top:-40px;opacity:0"><img src="assets/ui/doc-pdf.png" alt="" /><div>Q4 Proposal.pdf</div></div>
          <img id="cur-arrow" src="assets/ui/cursor-arrow.png" alt="" style="left:-5px;top:-5px;width:28px;height:40px" />
          <img id="cur-hand" src="assets/ui/cursor-hand.png" alt="" style="left:-12px;top:-8px;width:32px;height:32px;opacity:0" />
          <img id="cur-grab" src="assets/ui/cursor-grab.png" alt="" style="left:-15px;top:-16px;width:32px;height:32px;opacity:0" />
        </div>
      </div></div></div>
    </div>
    <div id="endcard">
      <svg width="1920" height="1080" viewBox="0 0 1920 1080">
        <defs>
          <filter id="goo" x="-10%" y="-60%" width="120%" height="220%" color-interpolation-filters="sRGB">
            <feGaussianBlur in="SourceGraphic" stdDeviation="9" />
            <feColorMatrix values="1 0 0 0 0  0 1 0 0 0  0 0 1 0 0  0 0 0 40 -19" />
          </filter>
        </defs>
        <g id="goo-g" filter="url(#goo)" opacity="0">
          <path id="goo-tab" d="{notch_d}" fill="#0a0a0b" />
          <rect id="goo-pill" x="{body_x:.2f}" y="-40" width="{body_w:.2f}" height="{notch_h + 40:.2f}" rx="{10 * END_S:.2f}" fill="#0a0a0b" />
        </g>
        <g id="mark-g" opacity="0">
          <rect x="{mark_x:.2f}" y="{mark_y:.2f}" width="{mark_w:.2f}" height="{mark_h:.2f}" rx="{mark_h / 2:.2f}" fill="#0a0a0b" />
          <g transform="translate({LX:.3f} {LY:.3f}) scale({LK:.5f})">
            <path id="star" d="{star_d}" fill="#ffffff" />
          </g>
        </g>
      </svg>
      <div id="word-wrap" style="position:absolute;left:{LX:.2f}px;top:{LY:.2f}px;width:{787 * LK:.2f}px;height:{439 * LK:.2f}px">
        <svg width="{787 * LK:.2f}" height="{439 * LK:.2f}" viewBox="0 0 787 439">{word_svg}</svg>
      </div>
    </div>
  </div>
  <script>
    // Every tween here is lazy: a later fromTo must not stamp its start state over earlier shots at load.
    const tl = gsap.timeline({{ paused: true, defaults: {{ immediateRender: false }} }});
    const cam = (t, s, fx, fy, d, ease) => {{
      if (!d) {{
        tl.set("#cam-scale", {{ scale: s }}, t);
        tl.set("#cam-focus", {{ x: -fx, y: -fy }}, t);
      }} else {{
        tl.to("#cam-scale", {{ scale: s, duration: d, ease }}, t);
        tl.to("#cam-focus", {{ x: -fx, y: -fy, duration: d, ease }}, t);
      }}
    }};
    gsap.set("#cam-scale", {{ scale: 2.6, transformOrigin: "0 0" }});
    gsap.set("#cam-focus", {{ x: -735, y: -184 }});
    gsap.set("#cur", {{ x: 1120, y: 520 }});
    gsap.set("#star", {{ scaleX: 0, scaleY: 0, svgOrigin: "393.83 128" }});
    gsap.set("#word-wrap", {{ clipPath: "inset(0px 100% 0px 0px)" }});
    gsap.set("#goo-tab", {{ svgOrigin: "{notch_fx + notch_w / 2:.2f} 0" }});
    gsap.set("#cur", {{ opacity: 0 }});

    // Hook: the notch macro, then a push to it.
    cam(0, 2.6, 735, 184);
    cam(1.3, 3.2, 735, 150, 1.0, "power2.inOut");
    // Wake: the song blooms; ease back a touch for room.
    cam(6.5, 3.0, 735, 160, 1.5, "power2.out");

    // Name: the island's black grows past the frame, then shrinks back into the meeting.
    tl.set("#reveal-rect", {{ attr: {{ x: 505, y: -30, width: 460, height: 140, rx: 30, ry: 30 }}, opacity: 1 }}, 8.0);
    tl.to("#reveal-rect", {{ attr: {{ x: 0, y: -400, width: 1470, height: 1100, rx: 0, ry: 0 }}, duration: 0.65, ease: "power2.inOut" }}, 8.0);
    tl.to("#island", {{ opacity: 0, filter: "blur(15px)", duration: 0.3, ease: "power1.in" }}, 8.0);
    tl.to("#reveal-rect", {{ attr: {{ x: 591.7, y: -30, width: 287, height: 62, rx: 10, ry: 10 }}, duration: 0.5, ease: "power3.inOut" }}, 11.85);
    tl.set("#island", {{ opacity: 1, filter: "blur(0px)" }}, 12.24);
    tl.set("#reveal-rect", {{ opacity: 0 }}, 12.36);

    // Join: the cursor hovers the meeting, clicks Join on the bar.
    tl.set("#cur", {{ opacity: 1 }}, 12.4);
    tl.fromTo("#cur", {{ x: 1120, y: 520 }}, {{ x: 790, y: 17, duration: 0.6, ease: "power3.inOut" }}, 12.4);
    tl.to("#cur", {{ x: 906, y: 58, duration: 0.45, ease: "power3.inOut" }}, 13.45);
    tl.set("#cur-arrow", {{ opacity: 0 }}, 13.9);
    tl.set("#cur-hand", {{ opacity: 1 }}, 13.9);
    tl.to("#cur-hand", {{ scale: 0.86, duration: 0.05, ease: "none", transformOrigin: "12px 8px" }}, 13.967);
    tl.to("#cur-hand", {{ scale: 1, duration: 0.12, ease: "power2.out" }}, 14.033);
    cam(14.0333, 3.3, 760, 150);
    cam(14.0667, 3.0, 735, 160, 0.45, "expo.out");
    tl.to("#cur", {{ x: 1160, y: 420, duration: 0.55, ease: "power3.in" }}, 14.35);
    tl.set("#cur-hand", {{ opacity: 0 }}, 14.95);
    tl.set("#cur", {{ opacity: 0 }}, 14.95);

    // Whip into Flow.
    tl.to("#cam-whip", {{ x: -900, filter: "blur(24px)", duration: 0.1, ease: "power3.in" }}, 16.0);
    cam(16.1, 2.6, 735, 185);
    tl.fromTo("#cam-whip", {{ x: 900, filter: "blur(24px)" }}, {{ x: 0, filter: "blur(0px)", duration: 0.15, ease: "power3.out" }}, 16.1);
    // Flow closes to the timer; push in for the split.
    cam(20.0, 3.2, 735, 150, 0.8, "power2.inOut");

    // Build: indigo floods the screen from the notch, then recedes.
    tl.fromTo("#flood-indigo", {{ clipPath: "circle(0px at 735px 0px)" }}, {{ clipPath: "circle(1800px at 735px 0px)", duration: 0.45, ease: "power2.inOut" }}, 22.5);
    tl.to("#flood-indigo", {{ clipPath: "circle(0px at 735px 0px)", duration: 0.45, ease: "power2.inOut" }}, 25.4);

    // AirPods: a punch-in on the beat, back out as it closes.
    cam(26.0, 3.5, 735, 140);
    cam(27.5, 3.2, 735, 150);

    // Drop: ease back to 2.6x; the cursor carries Q4 Proposal.pdf in from off-screen into the notch: Hold on Shelf.
    cam(28.0, 2.6, 735, 185, 0.5, "power2.inOut");
    tl.set("#cur-arrow", {{ opacity: 0 }}, 28.3);
    tl.set("#cur-grab", {{ opacity: 1 }}, 28.3);
    tl.set("#drag-file", {{ opacity: 1, scale: 1 }}, 28.3);
    tl.set("#cur", {{ opacity: 1 }}, 28.3);
    tl.fromTo("#cur", {{ x: 1150, y: 500 }}, {{ x: 626, y: 76, duration: 1.05, ease: "power2.inOut" }}, 28.3);
    tl.to("#drag-file", {{ scale: 0.72, duration: 1.05, ease: "power2.inOut" }}, 28.3);
    // released: the file stays over Hold on Shelf and drops into it while the cursor moves on
    tl.to("#drag-file", {{ x: 35, y: -214, scale: 0.12, duration: 0.26, ease: "power3.in" }}, 29.6333);
    tl.to("#drag-file", {{ opacity: 0, duration: 0.08, ease: "none" }}, 29.82);
    tl.set("#cur-grab", {{ opacity: 0 }}, 29.6333);
    tl.set("#cur-arrow", {{ opacity: 1 }}, 29.6333);
    tl.to("#cur", {{ x: 700, y: 230, duration: 0.35, ease: "power2.out" }}, 29.6333);
    tl.set("#cur", {{ opacity: 0 }}, 30.0);

    // Montage: punch on every beat.
    [[30.0, 2.8, 171], [30.5, 3.05, 160], [31.0, 2.8, 171], [31.5, 3.05, 160], [32.0, 2.8, 171], [32.5, 3.05, 160]]
      .forEach(([t, s, fy]) => cam(t, s, 735, fy));
    // Payoff: Home opens as the camera pulls back to the whole Mac.
    cam(33.0, 1.04, 735, 481, 2.2, "power2.inOut");
    // Claim: back in.
    cam(36.5, 2.6, 735, 185, 1.2, "power2.inOut");

    // End: the island sleeps, paper floods from the notch, the notch lifts into the mark.
    tl.to("#isl-fadeout", {{ opacity: 0, duration: 0.1, ease: "none" }}, 40.0);
    cam(40.0, {END_S}, 735, {END_FY:.3f}, 0.5, "power2.inOut");
    tl.fromTo("#flood-paper", {{ clipPath: "circle(0px at 1135px 400px)" }}, {{ clipPath: "circle(2600px at 1135px 400px)", duration: 0.45, ease: "power2.inOut" }}, 40.3);
    tl.set("#goo-g", {{ opacity: 1 }}, 40.75);
    tl.to("#goo-tab", {{ scaleY: 0, duration: 0.55, ease: "power2.in" }}, 40.8);
    tl.to("#goo-pill", {{ attr: {{ x: {mark_x:.2f}, y: {mark_y:.2f}, width: {mark_w:.2f}, height: {mark_h:.2f}, rx: {mark_h / 2:.2f} }}, duration: 1.05, ease: "power3.inOut" }}, 40.8);
    tl.set("#goo-g", {{ opacity: 0 }}, 41.85);
    tl.set("#mark-g", {{ opacity: 1 }}, 41.85);
    tl.to("#star", {{ scaleY: 1, duration: 0.24, ease: "back.out(2.2)" }}, 42.0);
    tl.to("#star", {{ scaleX: 1, duration: 0.6, ease: "expo.out" }}, 42.03);
    tl.to("#word-wrap", {{ clipPath: "inset(0px 0% 0px 0px)", duration: 0.65, ease: "power3.out" }}, 42.3);
    tl.set({{}}, {{}}, {DUR});
    window.__timelines["stage"] = tl;
  </script>
</template>
"""

# ---------------------------------------------------------------- titles.html

LINES = [
    # id, text, start, end, style, entrance
    ("t-look", "Look up.", 0.0, 1.45, "hook", "words-blur-first-in"),
    ("t-notch", "That notch?", 2.2, 3.8, "hook", "words-grey"),
    ("t-nothing", "It’s been doing nothing.", 3.9, 5.85, "hook-long", "line-blur"),
    ("t-sub", "A Dynamic Island for your Mac’s notch.", 9.25, 11.85, "sub", "words-grey-dark"),
    ("t-click", "One click. You’re in.", 14.3, 16.05, "left-mid", "words-blur"),
    ("t-tell", "Just tell Flow.", 16.5, 18.45, "left-low", "words-blur"),
    ("t-private", "On-device. Private.", 18.55, 20.1, "left-low", "line-blur"),
    ("t-two", "Two at once.", 21.0, 22.6, "center-mid", "words-grey"),
    ("t-builds", "Even your builds.", 23.4, 25.15, "left-build", "words-blur"),
    ("t-airpods", "AirPods, at a glance.", 26.1, 27.95, "right-mid", "words-grey"),
    ("t-drop", "Drop it on the notch.", 28.3, 30.0, "left-drop", "words-blur"),
    ("t-live", "Everything live.", 37.0, 38.5, "claim", "words-grey"),
    ("t-lookup", "Just look up.", 38.55, 40.05, "claim", "line-blur"),
    ("t-cta", "For macOS 14 or later", 43.3, DUR, "cta", "words-grey-cta"),
]

STYLE = {
    "hook": "left:0;width:1920px;top:540px;text-align:center;font-size:132px;color:#0a0a0b",
    "hook-long": "left:0;width:1920px;top:540px;text-align:center;font-size:112px;color:#0a0a0b",
    "sub": "left:0;width:1920px;top:650px;text-align:center;font-size:46px;font-weight:500;color:#ffffff;letter-spacing:-0.01em",
    "left-mid": "left:190px;width:1540px;top:560px;font-size:84px;color:#0a0a0b",
    "left-low": "left:190px;width:1540px;top:905px;font-size:84px;color:#0a0a0b",
    "center-mid": "left:0;width:1920px;top:520px;text-align:center;font-size:96px;color:#0a0a0b",
    "left-build": "left:190px;width:1540px;top:600px;font-size:96px;color:#ffffff",
    "right-mid": "left:190px;width:1540px;top:600px;text-align:right;font-size:84px;color:#0a0a0b",
    "left-drop": "left:150px;width:1000px;top:760px;font-size:84px;color:#0a0a0b",
    "claim": "left:0;width:1920px;top:560px;text-align:center;font-size:132px;color:#0a0a0b",
    "cta": "left:0;width:1920px;top:690px;text-align:center;font-size:34px;font-weight:500;color:#636467;letter-spacing:0",
}

title_html, title_js = [], []
for lid, text, s, e, style, ent in LINES:
    words = text.split(" ")
    spans = " ".join(f'<span class="w" id="{lid}-w{i}">{w}</span>' for i, w in enumerate(words))
    title_html.append(f'<div id="{lid}" class="clip line" data-start="{r4(s)}" data-duration="{r4(e - s)}" '
                      f'style="{STYLE[style]}"><div class="in" id="{lid}-in">{spans}</div></div>')
    ws = [f"#{lid}-w{i}" for i in range(len(words))]
    if ent in ("words-blur", "words-blur-first-in"):
        first = 1 if ent == "words-blur-first-in" else 0
        for i, w in enumerate(ws):
            if i < first:
                continue
            title_js.append(f'tl.fromTo("{w}", {{opacity: 0, filter: "blur(6px)"}}, {{opacity: 1, filter: "blur(0px)", duration: 0.13, ease: "power2.out"}}, {r4(s + 0.04 + (i - first) * 0.067 + (0.06 if first else 0))});')
    elif ent.startswith("words-grey"):
        c0, c1 = {"words-grey": ("#e9d9cc", "#0a0a0b"), "words-grey-dark": ("#2c2c2e", "#ffffff"),
                  "words-grey-cta": ("#e6e6e9", "#636467")}[ent]
        if style in ("left-build",):
            c0, c1 = ("#8f8df0", "#ffffff")
        for i, w in enumerate(ws):
            title_js.append(f'tl.fromTo("{w}", {{color: "{c0}"}}, {{color: "{c1}", duration: 0.16, ease: "power1.out"}}, {r4(s + 0.02 + i * 0.08)});')
    elif ent == "line-blur":
        title_js.append(f'tl.fromTo("#{lid}-in", {{opacity: 0, filter: "blur(8px)"}}, {{opacity: 1, filter: "blur(0px)", duration: 0.18, ease: "power2.out"}}, {r4(s + 0.02)});')
    if e < DUR - 0.01:
        title_js.append(f'tl.to("#{lid}-in", {{opacity: 0, filter: "blur(8px)", duration: 0.15, ease: "power1.in"}}, {r4(e - 0.16)});')

wordmark_dark = open(os.path.join(ROOT, "assets/brand/macflow-wordmark-dark.svg")).read()
wm_paths = "".join(f'<path fill="{c}" d="{d}"/>' for c, d in re.findall(r'<path fill="(#[0-9A-Fa-f]{6})" d="([^"]+)"', wordmark_dark))

titles = f"""<template>
  <style>
    @font-face {{ font-family: "SF Pro"; src: url("assets/fonts/SFNS.ttf"); font-weight: 1 1000; }}
    #root {{ position: absolute; inset: 0; font-family: "SF Pro"; }}
    .line {{ position: absolute; font-weight: 600; letter-spacing: -0.022em; line-height: 1.05; transform: translateY(-50%); white-space: nowrap; }}
    .line .in {{ display: inline-block; }}
    #name {{ position: absolute; left: 0; top: 0; width: 1920px; height: 1080px; }}
    #name svg {{ position: absolute; left: 412px; top: 300px; width: 1096px; height: 340px; }}
  </style>
  <div id="root" data-composition-id="titles" data-width="1920" data-height="1080">
    <div id="name" class="clip" data-start="8.5" data-duration="3.35"><div id="name-in"><svg viewBox="0 0 787 244">{wm_paths}</svg></div></div>
    {chr(10).join("    " + h for h in title_html)}
  </div>
  <script>
    const tl = gsap.timeline({{ paused: true }});
    tl.fromTo("#name-in", {{ opacity: 0, filter: "blur(10px)" }}, {{ opacity: 1, filter: "blur(0px)", duration: 0.28, ease: "power2.out" }}, 8.55);
    tl.to("#name-in", {{ opacity: 0, filter: "blur(8px)", duration: 0.15, ease: "power1.in" }}, 11.68);
    {chr(10).join("    " + j for j in title_js)}
    tl.set({{}}, {{}}, {DUR});
    window.__timelines["titles"] = tl;
  </script>
</template>
"""

# ---------------------------------------------------------------- index.html

SFX = [  # id, file, start, volume, duration — each placed so its measured peak lands one frame after its picture
    ("sfx-reveal", "whoosh-cinematic.mp3", 5.9, 0.32, None),
    ("sfx-click", "click.mp3", 13.96, 0.6, None),
    ("sfx-whip", "whoosh.mp3", 15.97, 0.45, None),
    ("sfx-keys", "typing.mp3", 16.43, 0.5, 1.2),
    ("sfx-pop1", "pop.mp3", 17.913, 0.4, None),
    ("sfx-pop2", "pop.mp3", 18.413, 0.34, None),
    ("sfx-pop3", "pop.mp3", 24.71, 0.4, None),
    ("sfx-drag", "whoosh-low.wav", 28.6, 0.25, None),
    ("sfx-impact", "impact-bass-1.mp3", 41.96, 0.38, None),
]
audio_html = ['<audio id="score" class="clip" data-start="0" data-duration="46.5" data-track-index="10" data-volume="1" src="assets/audio/score.wav"></audio>']
for n, (aid, f, s, v, d) in enumerate(SFX):
    dur = f' data-duration="{r4(d)}"' if d else ""
    audio_html.append(f'<audio id="{aid}" class="clip" data-start="{r4(s)}"{dur} data-track-index="{11 + n}" data-volume="{v}" src="assets/audio/sfx/{f}"></audio>')

index = f"""<!doctype html>
<html lang="en" data-resolution="landscape" data-composition-variables='[
  {{"id":"color-ground","type":"color","label":"Ground","default":"#0a0a0b"}},
  {{"id":"color-ink","type":"color","label":"Ink","default":"#0a0a0b"}},
  {{"id":"color-paper","type":"color","label":"Paper","default":"#ffffff"}},
  {{"id":"color-accent","type":"color","label":"Build world","default":"#5e5ce6"}},
  {{"id":"font-display","type":"string","label":"Display font","default":"SF Pro"}}
]'>
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=1920, height=1080" />
    <title>Mac Flow — Look up</title>
    <script src="https://cdn.jsdelivr.net/npm/gsap@3.14.2/dist/gsap.min.js"></script>
    <style>
      * {{ margin: 0; padding: 0; box-sizing: border-box; }}
      html, body {{ margin: 0; width: 1920px; height: 1080px; overflow: hidden; background: #0a0a0b; }}
      #root {{ position: relative; width: 1920px; height: 1080px; }}
    </style>
  </head>
  <body>
    <div id="root" data-composition-id="main" data-start="0" data-duration="{DUR}" data-width="1920" data-height="1080">
      <div id="stage" data-composition-id="stage" data-composition-src="compositions/stage.html" data-start="0" data-duration="{DUR}"
           data-track-index="1" data-track-kind="graphics" data-width="1920" data-height="1080" style="z-index:1"></div>
      <div id="titles" data-composition-id="titles" data-composition-src="compositions/titles.html" data-start="0" data-duration="{DUR}"
           data-track-index="2" data-track-kind="graphics" data-width="1920" data-height="1080" style="z-index:2"></div>
      {chr(10).join("      " + a for a in audio_html)}
    </div>
    <script>
      window.__timelines = window.__timelines || {{}};
      const tl = gsap.timeline({{ paused: true }});
      tl.set({{}}, {{}}, {DUR});
      window.__timelines["main"] = tl;
    </script>
  </body>
</html>
"""

os.makedirs(os.path.join(ROOT, "compositions"), exist_ok=True)
open(os.path.join(ROOT, "compositions/stage.html"), "w").write(stage)
open(os.path.join(ROOT, "compositions/titles.html"), "w").write(titles)
open(os.path.join(ROOT, "index.html"), "w").write(index)
print(f"island clips: {len(clips)}  unique frames: {len(used)}")
