"""Mac Flow v3 — "One day". Generates index.html, compositions/*.html and assets/audio/cues.json.

Picture: the real app — island frames rendered at 5x (assets/frames, from the film harness), StandBy pages at 3x
(assets/standby) — on the app's own wallpapers (assets/img), and a Three.js MacBook (tools/mac3d.template.html).
Sound: "AMALGAM" (Rockot, Pixabay) cut on its downbeats (tools/music_edit.py); Pixabay effects (tools/mixdown.py).
Every cut and click lands on the music's grid (assets/audio/grid.json). See SPEC.md for the shot list.
Run from promo/v3:  python3 tools/build_v3.py
"""
import json
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FPS = 30
DUR = 70.0
M = json.load(open(os.path.join(ROOT, "assets/frames/manifest.json")))
G = json.load(open(os.path.join(ROOT, "assets/audio/grid.json")))
DB = G["downbeats"]
PEAK = json.load(open(os.path.join(ROOT, "assets/audio/sfx/peaks.json")))
OX = 735 - 804 / 2  # the island canvas (804 pt) centred on the screen (1470 pt)
VIOLET = "#9E85FF"
CUES = []


def r4(x):
    s = f"{x:.4f}".rstrip("0").rstrip(".")
    return s if s not in ("", "-0") else "0"


def n(seq):
    return M[seq]["count"]


def secs(seq, rate=1.0):
    return n(seq) / FPS / rate


# The bed is loud (-10 LUFS in the drops), so quiet files need real gain and the bed must step aside: GAIN scales the volume
# given at each call, DUCK is the least the bed ducks (dB), TAIL caps a long tail. Tuned so UI sounds sit 3-6 dB over the bed.
GAIN = {"click-mouse": 2.9, "click-ui-button": 1.9, "soft-notification": 1.9, "pop-bubble-06": 1.5, "shine-11": 3.6,
        "ui-interface-03": 1.0, "swoosh-015": 1.9, "swoosh-010": 1.8, "whoosh-simple": 1.9, "whoosh-cinematic": 1.7, "reverse-cymbal": 1.5}
DUCK = {"click-mouse": 5, "click-ui-button": 4, "soft-notification": 4, "pop-bubble-06": 3, "shine-11": 4, "swoosh-015": 3,
        "swoosh-010": 3, "whoosh-simple": 3, "whoosh-cinematic": 3, "ui-interface-03": 2}
TAIL = {"shine-11": 1.8, "soft-notification": 1.2}


def cue(name, t, vol=0.7, duck=0.0, dur=None):
    """An effect whose measured peak lands one frame after its picture at film time t."""
    CUES.append({"name": name, "file": f"assets/audio/sfx/{name}.mp3", "start": round(t + 1 / FPS - PEAK[name]["peak"], 3),
                 "volume": round(vol * GAIN.get(name, 1.0), 3), "duration": dur or TAIL.get(name), "duck": max(duck, DUCK.get(name, 0)),
                 "peak": PEAK[name]["peak"]})


# ------------------------------------------------------------------------------------------------ type

FONT_CSS = '@font-face { font-family: "SF Pro"; src: url("assets/fonts/SFNS.ttf"); font-weight: 1 1000; }'
TYPE_CSS = """
    .h { position: absolute; color: #fff; font-family: "SF Pro"; font-weight: 600; letter-spacing: -0.028em; line-height: 1.04;
         white-space: nowrap; text-shadow: 0 0 24px rgba(0,0,0,0.35); }
    .h .w { opacity: 0; display: inline-block; white-space: pre; }
    .gw { background: linear-gradient(100deg, #d9ccff 0%, #9e85ff 42%, #e58ad0 100%); -webkit-background-clip: text;
          background-clip: text; color: transparent; text-shadow: none; }
"""


class Scene:
    """One sub-composition: markup, css and timeline statements, in scene-local seconds."""

    def __init__(self, sid, dur, bg="#000"):
        self.id, self.dur, self.bg = sid, dur, bg
        self.html, self.css, self.js, self.pre, self.extra = [], [TYPE_CSS], [], [], []
        self.n = 0

    def uid(self, p):
        self.n += 1
        return f"{self.id}-{p}{self.n}"

    def words(self, parts, t0, t_out, y=820, size=100, x=160, align="left", gap=0.075, color=None, weight=600):
        """Apple's per-word reveal: each word un-blurs into place, then the line holds still until it blurs out."""
        lid = self.uid("w")
        spans, k = [], 0
        for text, cls in parts:
            ws = [w for w in text.split(" ") if w]
            extra = " gw" if cls == "grad" else ""
            spans.append("".join(f'<span class="w{extra}" id="{lid}-{k + i}">{w} </span>' for i, w in enumerate(ws)))
            k += len(ws)
        col = f"color:{color};" if color else ""
        width = 1600 if align == "left" else 1920
        left = x if align == "left" else 0
        style = (f"top:{y}px;left:{left}px;width:{width}px;font-size:{size}px;font-weight:{weight};text-align:{align};"
                 f"{col}transform:translateY(-50%)")
        self.html.append(f'<div class="h" id="{lid}" style="{style}"><span id="{lid}-in" style="display:inline-block;margin-right:-0.25em">'
                         f'{"".join(spans)}</span></div>')
        for i in range(k):
            self.js.append(f'tl.fromTo("#{lid}-{i}", {{opacity: 0, filter: "blur(12px)", y: 6}}, '
                           f'{{opacity: 1, filter: "blur(0px)", y: 0, duration: 0.22, ease: "power3.out"}}, {r4(t0 + i * gap)});')
        if t_out is not None:
            self.js.append(f'tl.fromTo("#{lid}-in", {{opacity: 1, filter: "blur(0px)"}}, '
                           f'{{opacity: 0, filter: "blur(10px)", duration: 0.2, ease: "power1.in"}}, {r4(t_out - 0.2)});')
        return lid

    def render(self):
        return f"""<template>
  <style>
    {FONT_CSS}
    #root {{ position: absolute; inset: 0; overflow: hidden; background: {self.bg}; font-family: "SF Pro"; }}
    {"".join(self.css)}
  </style>
  <div id="root" data-composition-id="{self.id}" data-width="1920" data-height="1080" data-duration="{r4(self.dur)}">
    {chr(10).join("    " + h for h in self.html)}
  </div>
  <script>
    {chr(10).join("    " + p for p in self.pre)}
    const tl = gsap.timeline({{ paused: true, defaults: {{ immediateRender: false }} }});
    {chr(10).join("    " + j for j in self.js)}
    tl.set({{}}, {{}}, {r4(self.dur)});
    window.__timelines["{self.id}"] = tl;
  </script>
</template>
"""


# ------------------------------------------------------------------------------------------------ the desktop stage

STAGE_CSS = """
    .stage { position: absolute; inset: 0; perspective: 2400px; perspective-origin: 960px 540px; }
    .cam-c { position: absolute; left: 960px; top: 540px; width: 0; height: 0; transform-style: preserve-3d; }
    .cam-r, .cam-s { position: absolute; left: 0; top: 0; width: 0; height: 0; transform-style: preserve-3d; }
    .cam-f { position: absolute; left: 0; top: 0; width: 0; height: 0; }
    .cam-z { position: absolute; left: 0; top: 0; width: 1470px; height: 956px; zoom: 3; }
    .scr { position: absolute; left: 0; top: 0; width: 1470px; height: 956px; overflow: hidden; background: #000; }
    .scr img.wall { position: absolute; left: 0; top: 0; width: 1470px; height: 956px; object-fit: cover; }
    .mb { position: absolute; top: 0; height: 32px; line-height: 32px; color: rgba(255,255,255,0.92); font-size: 13px;
          font-weight: 500; white-space: nowrap; letter-spacing: -0.005em; }
    .mb b { font-weight: 700; margin-right: 12px; }
    .mb span { margin-right: 12px; }
    .isl { position: absolute; }
    .cur { position: absolute; left: 0; top: 0; }
    .cur img { position: absolute; left: -3px; top: -3px; width: 22px; height: 31px; }
    .dof { position: absolute; inset: 0; pointer-events: none; backdrop-filter: blur(7px); -webkit-backdrop-filter: blur(7px);
           -webkit-mask-image: radial-gradient(ellipse 54% 48% at 50% 36%, transparent 58%, #000 100%);
           mask-image: radial-gradient(ellipse 54% 48% at 50% 36%, transparent 58%, #000 100%); }
"""
ZOOM = 3  # laid out at 3x with CSS zoom so Chrome rasterizes the island sharp at 4K; camera scales stay at or under 1x


def stage_html(sc, walls, clocks, frames_html, extra=""):
    """The Mac's screen: wallpapers stacked (later ones fade in over earlier), the menu bar, the island, the cursor."""
    p = sc.id
    menu = "".join(f"<span>{w}</span>" for w in ["File", "Edit", "View", "Go", "Window", "Help"])
    clock_html = "".join(f'<div class="mb" id="{p}-clock{i}" style="right:14px;text-align:right;opacity:{1 if i == 0 else 0}">{c}</div>'
                         for i, c in enumerate(clocks))
    extra = extra + "".join(sc.extra)
    wall_html = "".join(f'<img class="wall" id="{p}-wall{i}" src="assets/img/{w}.jpg" alt="" style="opacity:{1 if i == 0 else 0}" />'
                        for i, w in enumerate(walls))
    return f"""<div class="stage" id="{p}-stage"><div class="cam-c" id="{p}-c"><div class="cam-r" id="{p}-r"><div class="cam-s" id="{p}-s"><div class="cam-f" id="{p}-f"><div class="cam-z">
      <div class="scr">{wall_html}
        <div id="{p}-night" style="position:absolute;inset:0;background:#000;opacity:0"></div>
        <img src="assets/ui/sym-apple.logo-white.png" alt="" style="position:absolute;left:6px;top:5px;width:30px;height:22px" />
        <div class="mb" style="left:46px"><b>Finder</b>{menu}</div>
        {clock_html}
      </div>
      {frames_html}
      {extra}
    </div></div></div></div></div></div>
    <div class="dof" id="{p}-dof"></div>"""


def clock_to(sc, t, i, count):
    for k in range(count):
        sc.js.append(f'tl.set("#{sc.id}-clock{k}", {{opacity: {1 if k == i else 0}}}, {r4(t)});')


def cam(sc, t, rx, ry, s, fx, fy, d=0, ease="power2.inOut"):
    """Put screen point (fx, fy) at the frame's centre at scale s (1 = the 1470 pt screen 1470 px wide)."""
    p = sc.id
    s, fx, fy = s / ZOOM, fx * ZOOM, fy * ZOOM
    if d == 0:
        sc.js.append(f'tl.set("#{p}-r", {{rotationX: {rx}, rotationY: {ry}}}, {r4(t)});')
        sc.js.append(f'tl.set("#{p}-s", {{scale: {s:.4f}}}, {r4(t)});')
        sc.js.append(f'tl.set("#{p}-f", {{x: {-fx:.2f}, y: {-fy:.2f}}}, {r4(t)});')
    else:
        sc.js.append(f'tl.to("#{p}-r", {{rotationX: {rx}, rotationY: {ry}, duration: {r4(d)}, ease: "{ease}"}}, {r4(t)});')
        sc.js.append(f'tl.to("#{p}-s", {{scale: {s:.4f}, duration: {r4(d)}, ease: "{ease}"}}, {r4(t)});')
        sc.js.append(f'tl.to("#{p}-f", {{x: {-fx:.2f}, y: {-fy:.2f}, duration: {r4(d)}, ease: "{ease}"}}, {r4(t)});')


def cam_init(sc, rx, ry, s, fx, fy):
    p = sc.id
    s, fx, fy = s / ZOOM, fx * ZOOM, fy * ZOOM
    sc.pre.append(f'gsap.set("#{p}-s", {{scale: {s:.4f}, transformOrigin: "0 0"}}); gsap.set("#{p}-r", {{rotationX: {rx}, rotationY: {ry}, '
                  f'transformOrigin: "0 0"}}); gsap.set("#{p}-f", {{x: {-fx:.2f}, y: {-fy:.2f}}});')


def whip(sc, t, dur=0.36):
    """A fast camera move reads as one gesture: blur peaks mid-move."""
    sc.js.append(f'tl.fromTo("#{sc.id}-stage", {{filter: "blur(0px)"}}, {{filter: "blur(16px)", duration: {r4(dur / 2)}, ease: "power2.in"}}, {r4(t)});')
    sc.js.append(f'tl.to("#{sc.id}-stage", {{filter: "blur(0px)", duration: {r4(dur / 2)}, ease: "power2.out"}}, {r4(t + dur / 2)});')


class Frames:
    """Island frame clips inside the stage, in scene-local seconds."""

    def __init__(self, sc):
        self.sc, self.clips = sc, []

    def play(self, seq, t0, rate=1.0, hold_until=None, idxs=None):
        """Plays a rendered sequence at 30 fps x rate from t0; the last frame holds until hold_until."""
        idxs = list(range(n(seq))) if idxs is None else idxs
        step = 1 / (FPS * rate)
        for k, i in enumerate(idxs):
            s, e = t0 + k * step, t0 + (k + 1) * step
            if k == len(idxs) - 1 and hold_until is not None:
                e = max(e, hold_until)
            self.clips.append((seq, i, s, e))
        return t0 + len(idxs) * step

    def hold(self, seq, i, t0, t1):
        self.clips.append((seq, i, t0, t1))

    def html(self):
        out = []
        for k, (seq, i, s, e) in enumerate(sorted(self.clips, key=lambda c: c[2])):
            m = M[seq]
            s2, e2 = max(0.0, s - 0.25 / FPS), e - 0.25 / FPS
            out.append(f'<img id="{self.sc.id}-i{k}" class="clip isl" data-start="{r4(s2)}" data-duration="{r4(e2 - s2)}" '
                       f'src="assets/frames/{seq}/{i:04d}.png" alt="" style="left:{r4(735 - m.get("cw", 804) / 2 + m["x"])}px;top:{r4(m["y"])}px;'
                       f'width:{r4(m["w"])}px;height:{r4(m["h"])}px" />')
        return "\n      ".join(out)


def cursor_html(sc):
    return (f'<div class="cur" id="{sc.id}-cur" style="opacity:0"><div id="{sc.id}-press">'
            f'<img src="assets/ui/cursor-arrow.png" alt="" /></div></div>')


def cursor_to(sc, t, x, y, d=0.55, ease="power3.inOut", show=True):
    if show:
        sc.js.append(f'tl.set("#{sc.id}-cur", {{opacity: 1}}, {r4(t)});')
    sc.js.append(f'tl.to("#{sc.id}-cur", {{x: {x}, y: {y}, duration: {r4(d)}, ease: "{ease}"}}, {r4(t)});')


def cursor_at(sc, t, x, y):
    sc.js.append(f'tl.set("#{sc.id}-cur", {{x: {x}, y: {y}}}, {r4(t)});')


def click(sc, t, film_t, sound=True, vol=0.9):
    """The press lands on the frame the UI reacts."""
    sc.js.append(f'tl.to("#{sc.id}-press", {{scale: 0.86, duration: 0.06, ease: "power2.out", transformOrigin: "0 0"}}, {r4(t - 0.06)});')
    sc.js.append(f'tl.to("#{sc.id}-press", {{scale: 1, duration: 0.14, ease: "power2.out"}}, {r4(t)});')
    if sound:
        cue("click-mouse", film_t, vol=vol, duck=3)


def cursor_hide(sc, t):
    sc.js.append(f'tl.to("#{sc.id}-cur", {{opacity: 0, duration: 0.15}}, {r4(t)});')


def btn(seq, px, py):
    """A point in a rendered frame (pixels of the full 5x canvas) in screen points."""
    return round(OX + px / 5, 1), round(py / 5, 1)


scenes = {}

# ================================================================================================ 2. the workday
# 8.66 (drop A) -> 28.57 (calm). Desktop on Dunes. The planner, the room, Lens, Claude, the meeting and its notes.
T0 = DB[4]
sc = Scene("workday", DB[13] - T0)
sc.css.append(STAGE_CSS)
sc.css.append("""
    #workday-copyw { position: absolute; left: 735px; top: 262px; transform: translate(-50%, -50%); }
    #workday-note { position: relative; width: 520px; padding: 0 0 22px; border-radius: 16px; opacity: 0; font-family: "SF Pro";
                    background: rgba(24,24,28,0.74); backdrop-filter: blur(30px); -webkit-backdrop-filter: blur(30px);
                    box-shadow: inset 0 0 0 1px rgba(255,255,255,0.14), 0 28px 60px rgba(0,0,0,0.38); color: #fff; }
    #workday-note .bar { height: 38px; display: flex; align-items: center; gap: 8px; padding: 0 16px; }
    #workday-note .bar i { width: 11px; height: 11px; border-radius: 50%; background: #5a5a60; display: block; }
    #workday-note .bar b { margin-left: 8px; font-size: 14px; font-weight: 600; color: #98989d; }
    #workday-note .ln { padding: 7px 28px; font-size: 24px; font-weight: 500; letter-spacing: -0.01em; color: #d1d1d6; white-space: nowrap; }
    #workday-note .ln.hd { font-size: 15px; font-weight: 700; letter-spacing: 0.06em; color: #8e8e93; padding-top: 12px; }
    #workday-copy { position: relative; display: inline-block; color: #fff; isolation: isolate; }
    #workday-sel { position: absolute; left: -5px; top: -3px; bottom: -3px; width: 0; background: rgba(52,120,246,0.7); border-radius: 4px; z-index: -1; }
    .key { display: inline-block; height: 44px; min-width: 44px; padding: 0 10px; border-radius: 9px; line-height: 44px; text-align: center;
           background: rgba(30,30,32,0.88); box-shadow: inset 0 0 0 1px rgba(255,255,255,0.18), 0 6px 18px rgba(0,0,0,0.35);
           color: #fff; font-size: 24px; font-weight: 600; margin: 0 5px; }
    #workday-keysw { position: absolute; left: 735px; top: 388px; transform: translate(-50%, -50%); }
    #workday-keys { position: relative; font-family: "SF Pro"; opacity: 0; white-space: nowrap; }
""")
F = Frames(sc)
L = lambda film: film - T0  # film time -> scene time

# ---- the plan (8.66 -> 13.04): Start My Day on the bar at 10.85, Set the Room on the bar at 13.04
F.hold("p_hold", 0, 0, L(DB[5]))
t = F.play("p_close", L(DB[5]))
F.hold("p_close", n("p_close") - 1, t, L(DB[5]) + 0.62)
t = F.play("n_open", L(DB[5]) + 0.62, hold_until=None)
F.hold("n_hold", 0, t, L(DB[6]))
t = F.play("n_close", L(DB[6]))
t = F.play("n_tick", t, rate=1 / 30)
F.hold("n_tick", n("n_tick") - 1, t, L(DB[6]) + 2.3)
cam_init(sc, 7, -5, 2.42, 735, 205)
cam(sc, 0, 3, 2, 2.5, 735, 200, d=2.1, ease="power1.out")
cam(sc, L(DB[5]) + 0.3, 4, -2, 2.45, 735, 180, d=1.0)
sx, sy = btn("p_hold", 3065, 1381)          # Start My Day
cursor_at(sc, 0, 1180, 560)
cursor_to(sc, 0.25, sx + 6, sy + 4, d=1.55)
click(sc, L(DB[5]), DB[5], vol=0.55)
rx, ry = btn("n_hold", 3003, 316)           # Set the Room
cursor_to(sc, L(DB[5]) + 0.5, rx + 6, ry + 4, d=1.25, show=False)
click(sc, L(DB[6]), DB[6], vol=1.2)
cursor_to(sc, L(DB[6]) + 0.15, 1240, 520, d=0.6, ease="power2.in", show=False)
cursor_hide(sc, L(DB[6]) + 0.7)
sc.words([("Planned before you are.", "")], 0.35, L(DB[5]) - 0.05)
cue("whoosh-cinematic", DB[4], vol=0.3)

# ---- Flow Lens (13.04 -> 17.66): a line copied, ⌘C, Add to Calendar on 15.47
lens_at = L(DB[6]) + 1.66
cam(sc, L(DB[6]) + 0.2, 6, 3, 2.05, 735, 210, d=1.0)
sc.extra.append('<div id="workday-copyw"><div id="workday-note"><div class="bar"><i></i><i></i><i></i><b>Notes</b></div>'
                '<div class="ln hd">TODAY</div><div class="ln">Send the deck to Sam</div>'
                '<div class="ln"><span id="workday-copy"><span id="workday-sel"></span>Lunch with Sam tomorrow at 1pm</span></div>'
                '<div class="ln">Review Priya’s PR</div></div></div>')
sc.extra.append('<div id="workday-keysw"><div id="workday-keys"><span class="key">⌘</span><span class="key">C</span></div></div>')
sc.js.append(f'tl.fromTo("#workday-note", {{opacity: 0, y: 14, scale: 0.97}}, {{opacity: 1, y: 0, scale: 1, duration: 0.34, ease: "power2.out"}}, {r4(L(DB[6]) + 0.02)});')
sc.js.append(f'tl.to("#workday-sel", {{width: "calc(100% + 12px)", duration: 0.32, ease: "power2.inOut"}}, {r4(L(DB[6]) + 0.55)});')
sc.js.append(f'tl.fromTo("#workday-keys", {{opacity: 0, scale: 0.9}}, {{opacity: 1, scale: 1, duration: 0.16, ease: "back.out(2)"}}, {r4(L(DB[6]) + 1.05)});')
sc.js.append(f'tl.to(["#workday-keys", "#workday-note"], {{opacity: 0, y: 26, duration: 0.3, ease: "power2.in"}}, {r4(lens_at - 0.05)});')
cue("click-ui-button", T0 + L(DB[6]) + 1.05, vol=0.8)
t = F.play("l_open", lens_at)
F.hold("l_hold", 0, t, L(DB[7]))
t = F.play("l_added", L(DB[7]))
F.hold("l_addedHold", 0, t, L(DB[7]) + 0.7)
t = F.play("l_close", L(DB[7]) + 0.7)
cue("soft-notification", T0 + lens_at + 0.15, vol=0.6)
ax, ay = btn("l_hold", 2424, 310)            # Add to Calendar
cursor_at(sc, lens_at, 1250, 520)
cursor_to(sc, lens_at + 0.05, ax + 6, ay + 4, d=0.7)
click(sc, L(DB[7]), DB[7], vol=2.0)
cue("pop-bubble-06", DB[7] + 0.35, vol=0.6)
cursor_to(sc, L(DB[7]) + 0.2, 1260, 540, d=0.6, ease="power2.in", show=False)
cursor_hide(sc, L(DB[7]) + 0.75)
sc.words([("It reads what you copy.", "")], L(DB[7]) - 0.35, L(DB[8]) - 0.05)

# ---- Claude (17.66 -> 22.02): finishes something long while you focus
F.hold("l_close", n("l_close") - 1, t, L(DB[8]) + 0.5)
cam(sc, L(DB[8]) - 0.1, 4, -3, 2.6, 735, 150, d=0.9)
t = F.play("c_open", L(DB[8]) + 0.5)
F.hold("c_hold", 0, t, L(DB[10]) - 0.75)
t = F.play("c_close", L(DB[10]) - 0.75)
F.hold("c_close", n("c_close") - 1, t, L(DB[10]))
cue("shine-11", DB[8] + 0.62, vol=0.5)
sc.words([("It keeps an eye on Claude.", "")], L(DB[8]) + 1.0, L(DB[10]) - 0.1)

# ---- the meeting (22.02 -> 28.57): a whip to 1:55 PM, Join on 24.20, Start Notes on the half bar, the words as said
whip(sc, L(DB[10]) - 0.18)
clock_to(sc, L(DB[10]), 1, 2)
cam(sc, L(DB[10]) - 0.18, 0, 0, 1.3, 760, 250, d=0.36, ease="expo.inOut")
cam(sc, L(DB[10]) + 0.45, 5, 3, 2.35, 735, 205, d=1.1)
cue("swoosh-015", DB[10], vol=0.6)
F.hold("m_open", 0, L(DB[10]), L(DB[10]) + 0.42)
t = F.play("m_open", L(DB[10]) + 0.42)
F.hold("m_hold", 0, t, L(DB[11]))
t = F.play("m_call", L(DB[11]))
notes_at = L(DB[11]) + 1.09
F.hold("m_consent", 0, t, notes_at)
t = F.play("m_rec", notes_at)
t = F.play("m_notes", t + 0.1, rate=0.19)
F.hold("m_notes", n("m_notes") - 1, t, sc.dur)
jx, jy = btn("m_hold", 3088, 316)            # Join
cursor_at(sc, L(DB[10]) + 0.6, 1230, 520)
cursor_to(sc, L(DB[10]) + 0.7, jx + 6, jy + 4, d=1.2)
click(sc, L(DB[11]), DB[11], vol=2.0)
nx, ny = btn("m_consent", 2830, 611)          # Start Notes
cursor_to(sc, L(DB[11]) + 0.25, nx + 6, ny + 4, d=0.72, show=False)
click(sc, notes_at, T0 + notes_at, vol=2.0)
cursor_to(sc, notes_at + 0.15, 1260, 560, d=0.6, ease="power2.in", show=False)
cursor_hide(sc, notes_at + 0.7)
cam(sc, notes_at + 0.2, 4, -2, 2.55, 735, 140, d=1.4)
sc.words([("It takes the notes.", "")], notes_at + 0.5, sc.dur - 0.1)

MEET_CLOCK = open(os.path.join(ROOT, "assets/frames/meet-clock.txt")).read().strip() if os.path.exists(os.path.join(ROOT, "assets/frames/meet-clock.txt")) else "Mon 26 Oct  1:55 PM"
sc.html.insert(0, stage_html(sc, ["dunes"], ["Mon 26 Oct  10:22 AM", MEET_CLOCK], F.html(), cursor_html(sc)))
scenes["workday"] = (sc, T0)

# ================================================================================================ 3. the evening
# 28.57 (calm) -> 46.0 (drop B). Dusk on Horizon. Ask, the day ring, Rewind; then the hush, and the Mac goes dark.
T0 = DB[13]
sc = Scene("evening", DB[21] - T0)
sc.css.append(STAGE_CSS)
sc.css.append("""
    #evening-ring { position: absolute; left: 0; top: 0; width: 44px; height: 44px; margin: -22px 0 0 -22px; opacity: 0; }
""")
F = Frames(sc)
L = lambda film: film - T0
cam_init(sc, 0, 0, 1.18, 735, 300)
sc.js.append('tl.fromTo("#evening-wall1", {opacity: 0}, {opacity: 1, duration: 0.9, ease: "power1.inOut"}, 0);')
cam(sc, 0.15, 6, 2, 2.45, 735, 170, d=1.5)
cue("whoosh-simple", DB[13], vol=0.28)
# hold the notch: the cursor presses, a ring fills, Flow listens
press = L(DB[14]) - 0.9
F.hold("v_open", 0, 0, press + 0.45)
t = F.play("v_open", press + 0.45)
t = F.play("v_talk", t + 0.1, rate=0.17)
F.hold("v_talk", n("v_talk") - 1, t, L(DB[15]))
cursor_at(sc, 0.3, 1100, 470)
cursor_to(sc, 0.35, 742, 20, d=0.95)
sc.js.append(f'tl.to("#evening-press", {{scale: 0.86, duration: 0.08, ease: "power2.out", transformOrigin: "0 0"}}, {r4(press)});')
sc.js.append(f'tl.to("#evening-press", {{scale: 1, duration: 0.14}}, {r4(press + 0.45)});')
sc.js.append(f'tl.set("#evening-ring", {{x: 742, y: 20, opacity: 1}}, {r4(press)});')
sc.js.append(f'tl.fromTo("#evening-arc", {{attr: {{"stroke-dashoffset": 120}}}}, {{attr: {{"stroke-dashoffset": 0}}, duration: 0.45, ease: "none"}}, {r4(press)});')
sc.js.append(f'tl.to("#evening-ring", {{opacity: 0, duration: 0.12}}, {r4(press + 0.47)});')
cursor_to(sc, press + 0.5, 1150, 520, d=0.6, ease="power2.in", show=False)
cursor_hide(sc, press + 1.05)
cue("ui-interface-03", T0 + press + 0.45, vol=0.55, duck=2)
sc.words([("Just ask.", "")], L(DB[14]) - 0.2, L(DB[15]) - 0.1)

# the day, drawn as a ring
t = F.play("d_open", L(DB[15]))
t = F.play("d_draw", t)
F.hold("d_draw", n("d_draw") - 1, t, L(DB[17]))
cam(sc, L(DB[15]) - 0.1, 5, -3, 2.3, 735, 175, d=0.9)
cam(sc, L(DB[15]) + 1.0, 3, 2, 2.4, 735, 170, d=3.2, ease="sine.inOut")
cue("shine-11", DB[15] + 0.7, vol=0.2)
sc.words([("Your day, drawn.", "")], L(DB[15]) + 0.55, L(DB[17]) - 0.1)

# Rewind: the playhead scrubs from nine to half past three
t = F.play("r_open", L(DB[17]))
t = F.play("r_scrub", t + 0.25, rate=0.3)
F.hold("r_scrub", n("r_scrub") - 1, t, L(DB[20]) - 0.62)
t = F.play("r_close", L(DB[20]) - 0.62)
F.hold("r_close", n("r_close") - 1, t, sc.dur)
cam(sc, L(DB[17]) - 0.1, 4, 3, 2.35, 735, 170, d=0.9)
sc.words([("Rewind any moment.", "")], L(DB[17]) + 0.6, L(DB[20]) - 0.55)

# the hush: the Mac goes dark around the notch; 11:54 PM
cam(sc, L(DB[20]) - 0.5, 0, 0, 1.55, 735, 330, d=1.6, ease="power2.inOut")
sc.js.append(f'tl.to("#evening-night", {{opacity: 0.8, duration: 0.9, ease: "power2.in"}}, {r4(L(DB[20]) - 0.4)});')
sc.js.append(f'tl.to("#evening-clock0", {{opacity: 0, duration: 0.25}}, {r4(L(DB[20]) + 0.25)});')
sc.js.append(f'tl.fromTo("#evening-clock1", {{opacity: 0}}, {{opacity: 1, duration: 0.35}}, {r4(L(DB[20]) + 0.55)});')
cue("reverse-cymbal", DB[21] - 0.02, vol=0.55)

ring = ('<svg id="evening-ring" viewBox="0 0 44 44"><circle cx="22" cy="22" r="19" fill="none" stroke="rgba(255,255,255,0.25)" stroke-width="3"/>'
        '<circle id="evening-arc" cx="22" cy="22" r="19" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round" '
        'stroke-dasharray="120" stroke-dashoffset="120" transform="rotate(-90 22 22)"/></svg>')
sc.html.insert(0, stage_html(sc, ["dunes", "horizon"], ["Mon 26 Oct  7:42 PM", "Mon 26 Oct  11:54 PM"], F.html(), ring + cursor_html(sc)))
scenes["evening"] = (sc, T0)

# ================================================================================================ 4. StandBy
# 46.0 (drop B) -> 55.0. The clock in Liquid Glass behind the dune; then Now Playing, its lyrics rising on the half bar.
T0 = DB[21]
sc = Scene("standby", DB[25] - T0)
sc.css.append("""
    .sb { position: absolute; left: 50%; top: 50%; width: 1920px; height: 1249px; margin: -548px 0 0 -960px; opacity: 0; }
""")
L = lambda film: film - T0
sc.html.append('<div id="standby-flash" style="position:absolute;inset:0;background:#fff;opacity:0;z-index:5"></div>')
shots = [("glass-dunes", 0, L(DB[23]))] + [(f"lyrics-{k}", L(DB[23]) + k * (DB[24] - DB[23]) / 2, None) for k in range(4)]
for k, (img, a, _) in enumerate(shots):
    sc.html.append(f'<img class="sb" id="standby-{k}" src="assets/standby/{img}.jpg" alt="" />')
sc.js.append('tl.fromTo("#standby-0", {opacity: 0, scale: 1.16, filter: "blur(22px) brightness(1.6)"}, '
             '{opacity: 1, scale: 1.0, filter: "blur(0px) brightness(1)", duration: 0.7, ease: "expo.out"}, 0);')
sc.js.append('tl.fromTo("#standby-flash", {opacity: 0.0}, {opacity: 0.32, duration: 0.05}, 0);')
sc.js.append('tl.to("#standby-flash", {opacity: 0, duration: 0.5, ease: "power2.out"}, 0.05);')
sc.js.append(f'tl.to("#standby-0", {{scale: 1.045, duration: {r4(L(DB[23]) - 0.7)}, ease: "sine.inOut"}}, 0.7);')
cue("sub-bass-boom", DB[21], vol=0.75)
cue("impact-boom-03", DB[21], vol=0.8)
# Now Playing: a whip in, then each line change crossfades on the half bar while the cover stays put
sc.js.append(f'tl.fromTo("#standby-1", {{opacity: 0, scale: 1.06}}, {{opacity: 1, scale: 1.0, duration: 0.45, ease: "expo.out"}}, {r4(shots[1][1])});')
sc.js.append(f'tl.set("#standby-0", {{opacity: 0}}, {r4(shots[1][1] + 0.45)});')
cue("whoosh-simple", T0 + shots[1][1], vol=0.4)
for k in range(2, 5):
    sc.js.append(f'tl.fromTo("#standby-{k}", {{opacity: 0}}, {{opacity: 1, duration: 0.32, ease: "power1.inOut"}}, {r4(shots[k][1])});')
sc.js.append(f'tl.to("#standby-4", {{scale: 1.03, duration: {r4(sc.dur - shots[4][1])}, ease: "sine.inOut"}}, {r4(shots[4][1])});')
scenes["standby"] = (sc, T0)

# ================================================================================================ 5. the montage
# 61.55 -> 63.48: everything live, at twice the speed, closing into the pill on Silk.
T0 = DB[28]
sc = Scene("montage", DB[29] - T0)
sc.css.append(STAGE_CSS)
F = Frames(sc)
seqs = [f"m5_{i:02d}" for i in range(10)]
t = 0.0
for s in seqs:
    t = F.play(s, t, rate=1.0, idxs=list(range(0, n(s), 2)))
F.hold("v2notch", 0, t, sc.dur)
cam_init(sc, 3, -2, 2.55, 735, 62)
cam(sc, 0, -2, 2, 2.9, 735, 54, d=sc.dur, ease="sine.inOut")
sc.html.insert(0, stage_html(sc, ["silk"], ["Mon 26 Oct  11:58 PM"], F.html()))
cue("swoosh-010", DB[28], vol=0.5)
scenes["montage"] = (sc, T0)

# ================================================================================================ 6. the end card
# 63.48 (the final hit) -> 70: the star ignites, the pill grows around it into the mark, the wordmark wipes in.
T0 = DB[29]
sc = Scene("end", DUR - T0)
stacked = open(os.path.join(ROOT, "assets/brand/macflow-logo-stacked-dark.svg")).read()
paths = re.findall(r'<path fill="(#[0-9A-Fa-f]{6})"(?: fill-rule="evenodd")? d="([^"]+)"', stacked)
star_in_mark = "M" + paths[0][1].split("ZM", 1)[1]
word_svg = "".join(f'<path fill="{c}" d="{d}"/>' for c, d in paths[1:])
LK = 360 / 404
LX, LY = 960 - 393.83 * LK, 400 - 128 * LK
mx, my, mw, mh = 191.83 * LK + LX, 64 * LK + LY, 404 * LK, 128 * LK
cy = 128 * LK + LY
sc.html.append(f"""<svg width="1920" height="1080" viewBox="0 0 1920 1080" style="position:absolute;left:0;top:0;overflow:visible">
      <rect id="end-pill" x="{mx:.2f}" y="{my:.2f}" width="{mw:.2f}" height="{mh:.2f}" rx="{mh / 2:.2f}" fill="#fff" opacity="0"/>
      <g id="end-core-g"><path id="end-core" d="{star_in_mark}" fill="#fff" transform="translate({LX:.3f} {LY:.3f}) scale({LK:.5f})"/></g>
    </svg>
    <div id="end-word" style="position:absolute;left:{LX:.2f}px;top:{LY:.2f}px;width:{787 * LK:.2f}px;height:{439 * LK:.2f}px">
      <svg width="{787 * LK:.2f}" height="{439 * LK:.2f}" viewBox="0 0 787 439">{word_svg}</svg></div>""")
sc.pre.append(f'gsap.set("#end-core-g", {{scaleX: 0.02, scaleY: 0, svgOrigin: "960 {cy:.2f}"}});')
sc.pre.append('gsap.set("#end-word", {clipPath: "inset(0px 100% 0px 0px)"});')
sc.js.append(f'tl.to("#end-core-g", {{scaleY: 1, duration: 0.24, ease: "back.out(2.4)", svgOrigin: "960 {cy:.2f}"}}, 0);')
sc.js.append(f'tl.to("#end-core-g", {{scaleX: 1, duration: 0.62, ease: "expo.out", svgOrigin: "960 {cy:.2f}"}}, 0.03);')
sc.js.append(f'tl.fromTo("#end-pill", {{opacity: 1, scaleX: 0.08, scaleY: 0.5, svgOrigin: "960 {cy:.2f}"}}, '
             f'{{scaleX: 1, scaleY: 1, duration: 0.55, ease: "expo.out"}}, 0.22);')
sc.js.append('tl.set("#end-core", {attr: {fill: "#000"}}, 0.22);')
sc.js.append('tl.to("#end-word", {clipPath: "inset(0px 0% 0px 0px)", duration: 0.7, ease: "power3.out"}, 0.62);')
sc.words([("Free and open source.", "")], 1.45, None, y=720, size=40, align="center", gap=0.07, color="#d1d1d6", weight=600)
sc.words([("macOS 14 or later · github.com/Bmorp/macFLOW", "")], 1.9, None, y=782, size=30, align="center", gap=0.06,
         color="#8e8e93", weight=500)
sc.html.append('<div id="end-black" style="position:absolute;inset:0;background:#000;opacity:0"></div>')
sc.js.append(f'tl.fromTo("#end-black", {{opacity: 0}}, {{opacity: 1, duration: 0.45, ease: "power1.in"}}, {r4(sc.dur - 0.5)});')
cue("impact-boom-05", DB[29], vol=0.6)
cue("sub-bass-boom", DB[29], vol=0.55)
scenes["end"] = (sc, T0)

# ================================================================================================ titles over the 3D shots
sc = Scene("titles", DUR, bg="transparent")
sc.words([("Your day", "")], 0.55, 2.2, y=165, size=104, align="center", gap=0.12)
sc.words([("starts at the ", ""), ("notch.", "grad")], 2.3, 4.05, y=165, size=104, align="center", gap=0.12)
sc.words([("Your whole day.", "")], DB[25] + 0.45, DB[27] - 0.2, y=170, size=108, align="center", gap=0.13)
sc.words([("In the ", ""), ("notch.", "grad")], DB[27] + 0.05, DB[28] - 0.05, y=170, size=108, align="center", gap=0.16)
scenes["titles"] = (sc, 0.0)

# ================================================================================================ the 3D MacBook
os.makedirs(os.path.join(ROOT, "compositions"), exist_ok=True)
MAC = open(os.path.join(ROOT, "tools/mac3d.template.html")).read()


def mac_scene(sid, dur, shot, screen):
    used = {l[0] for l in screen["layers"]}
    html = (MAC.replace("__ID__", sid).replace("__DUR__", r4(dur)).replace("__SHOT__", shot)
            .replace("__MANIFEST__", json.dumps({k: M[k] for k in used})).replace("__SCREEN__", json.dumps(screen))
            .replace('data-hf-id="hf-uzmr" ', "").replace('data-hf-id="hf-s287" ', ""))
    open(os.path.join(ROOT, f"compositions/{sid}.html"), "w").write(html)


dawn_open = 3.2
mac_scene("dawn", DB[4], "dawn", {"wall": "assets/img/dunes.jpg", "full": False, "clock": "Mon 26 Oct  7:58 AM",
                                   "layers": [["p_open", 0, 1, 0], ["p_open", "seq", n("p_open"), dawn_open],
                                              ["p_hold", 0, 1, dawn_open + secs("p_open")]]})
mac_scene("night", DB[28] - DB[25], "night", {"wall": "assets/standby/glass-dunes.jpg", "full": True, "clock": "", "layers": []})
cue("shine-11", dawn_open + 0.1, vol=0.35)
cue("whoosh-cinematic", DB[25], vol=0.45)

# ================================================================================================ write it all
os.makedirs(os.path.join(ROOT, "compositions"), exist_ok=True)
for sid, (sc, _) in scenes.items():
    open(os.path.join(ROOT, f"compositions/{sid}.html"), "w").write(sc.render())

hosts = [("dawn", 0.0, DB[4], 1), ("workday", DB[4], DB[13] - DB[4], 2), ("evening", DB[13], DB[21] - DB[13], 3),
         ("standby", DB[21], DB[25] - DB[21], 4), ("night", DB[25], DB[28] - DB[25], 5), ("montage", DB[28], DB[29] - DB[28], 6),
         ("end", DB[29], DUR - DB[29], 7), ("titles", 0.0, DUR, 50)]
host_html = "\n".join(
    f'      <div id="{h}" data-composition-id="{h}" data-composition-src="compositions/{h}.html" data-start="{r4(s)}" '
    f'data-duration="{r4(d)}" data-track-index="{z}" data-track-kind="graphics" data-width="1920" data-height="1080" style="z-index:{z}"></div>'
    for h, s, d, z in hosts)
open(os.path.join(ROOT, "index.html"), "w").write(f"""<!doctype html>
<html lang="en" data-resolution="landscape">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=1920, height=1080" />
    <title>Mac Flow — One day</title>
    <script src="https://cdn.jsdelivr.net/npm/gsap@3.14.2/dist/gsap.min.js"></script>
    <style>
      * {{ margin: 0; padding: 0; box-sizing: border-box; }}
      html, body {{ width: 1920px; height: 1080px; overflow: hidden; background: #000; }}
      #root {{ position: relative; width: 1920px; height: 1080px; background: #000; }}
    </style>
  </head>
  <body>
    <div id="root" data-composition-id="main" data-start="0" data-duration="{r4(DUR)}" data-width="1920" data-height="1080">
{host_html}
      <audio id="mix" class="clip" data-start="0" data-duration="{r4(DUR)}" data-track-index="60" data-volume="1" src="assets/audio/mix.wav"></audio>
    </div>
    <script>
      window.__timelines = window.__timelines || {{}};
      const tl = gsap.timeline({{ paused: true }});
      tl.set({{}}, {{}}, {r4(DUR)});
      window.__timelines["main"] = tl;
    </script>
  </body>
</html>
""")

json.dump({"music": {"file": "assets/audio/music-master.wav", "volume": 0.62, "fade_out": 0.0, "duration": DUR},
           "sfx": sorted(CUES, key=lambda c: c["start"])}, open(os.path.join(ROOT, "assets/audio/cues.json"), "w"), indent=1)
print(f"built {len(scenes) + 2} scenes, {len(CUES)} sound cues")
