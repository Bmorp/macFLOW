"""Mac Flow v2 — "The notch that thinks". Generates index.html and compositions/*.html.

Picture: real island frames rendered from the app at 5x (assets/frames), a Three.js MacBook, vector hero moments.
Sound: "Creative Technology Showreel" (Pixabay) cut to 72 s on its bars (tools/music_edit.py), Pixabay effects.
Grid: 100 BPM -> beat 0.6 s, bar 2.4 s. Film bar n starts at 2.4 n.
Run from promo/v2:  python3 tools/build_v2.py
"""
import json
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FPS = 30
DUR = 70.0
M = json.load(open(os.path.join(ROOT, "assets/frames/manifest.json")))
PEAK = json.load(open(os.path.join(ROOT, "assets/audio/sfx/peaks.json")))
OX = 735 - 382  # canvas x 382 pt (island centre) sits on the screen's centre, 735 pt
SW, SH = 1470, 956
VIOLET = "#9E85FF"


def r4(x):
    s = f"{x:.4f}".rstrip("0").rstrip(".")
    return s if s not in ("", "-0") else "0"


def bar(n):
    return 2.4 * n


# ------------------------------------------------------------------------------------------------ shared pieces

FONT_CSS = '@font-face { font-family: "SF Pro"; src: url("assets/fonts/SFNS.ttf"); font-weight: 1 1000; }'
TYPE_CSS = """
    .h { position: absolute; left: 0; width: 1920px; text-align: center; color: #fff; font-family: "SF Pro";
         font-weight: 600; letter-spacing: -0.028em; line-height: 1.04; white-space: nowrap; }
    .h .c, .h .w { opacity: 0; display: inline-block; white-space: pre; }
    .grad, .gw { background: linear-gradient(100deg, #d9ccff 0%, #9e85ff 42%, #e58ad0 100%); -webkit-background-clip: text;
            background-clip: text; color: transparent; }
    .grad { display: inline-block; white-space: pre; }
"""


class Scene:
    """One sub-composition: markup, css and a list of timeline statements, all in scene-local seconds."""

    def __init__(self, sid, dur):
        self.id, self.dur = sid, dur
        self.html, self.css, self.js = [], [TYPE_CSS], []
        self.n = 0

    def uid(self, p):
        self.n += 1
        return f"{self.id}-{p}{self.n}"

    # ---- type ----
    def typed(self, parts, t0, y, size, rate=0.042, t_out=None, align="center", x=0, width=1920):
        """Letters appear one by one, like Apple's typed titles. parts: [(text, css class or '')]."""
        lid = self.uid("t")
        spans, k, segs = [], 0, []
        for text, cls in parts:
            if cls == "grad":
                sid = f"{lid}-g{len(segs)}"
                spans.append(f'<span class="grad" id="{sid}" style="clip-path:inset(-20% 100% -20% 0)">{text}</span>')
                segs.append((sid, k, len(text)))
                k += len(text)
                continue
            inner = "".join(f'<span class="c" id="{lid}-{k + i}">{ch}</span>' for i, ch in enumerate(text))
            spans.append(inner)
            k += len(text)
        style = f"top:{y}px;font-size:{size}px;text-align:{align};left:{x}px;width:{width}px;transform:translateY(-50%)"
        self.html.append(f'<div class="h" id="{lid}" style="{style}"><span id="{lid}-in" style="display:inline-block">{"".join(spans)}</span></div>')
        in_seg = {i for _, a, n in segs for i in range(a, a + n)}
        for i in range(k):
            if i not in in_seg:
                self.js.append(f'tl.set("#{lid}-{i}", {{opacity: 1}}, {r4(t0 + i * rate)});')
        for sid, a, n in segs:
            for j in range(n):
                right = 100 - (j + 1) / n * 100
                self.js.append(f'tl.set("#{sid}", {{clipPath: "inset(-20% {right:.2f}% -20% 0%)"}}, {r4(t0 + (a + j) * rate)});')
        if t_out is not None:
            self.js.append(f'tl.fromTo("#{lid}-in", {{opacity: 1, filter: "blur(0px)"}}, {{opacity: 0, filter: "blur(10px)", duration: 0.2, ease: "power1.in"}}, {r4(t_out - 0.2)});')
        return lid

    def words(self, parts, t0, y, size, gap=0.075, t_out=None, align="center", x=0, width=1920, color=None, mode="blur", weight=600):
        """Word by word: blur 10 -> 0 (Apple's per-word reveal), or grey -> white."""
        lid = self.uid("w")
        spans, k = [], 0
        for text, cls in parts:
            ws = [w for w in text.split(" ") if w]
            extra = " gw" if cls == "grad" else ""
            spans.append("".join(f'<span class="w{extra}" id="{lid}-{k + i}">{w} </span>' for i, w in enumerate(ws)))
            k += len(ws)
        col = f"color:{color};" if color else ""
        style = f"top:{y}px;font-size:{size}px;font-weight:{weight};text-align:{align};left:{x}px;width:{width}px;{col}transform:translateY(-50%)"
        self.html.append(f'<div class="h" id="{lid}" style="{style}"><span id="{lid}-in" style="display:inline-block;margin-right:-0.25em">{"".join(spans)}</span></div>')
        for i in range(k):
            t = r4(t0 + i * gap)
            if mode == "blur":
                self.js.append(f'tl.fromTo("#{lid}-{i}", {{opacity: 0, filter: "blur(12px)", y: 6}}, {{opacity: 1, filter: "blur(0px)", y: 0, duration: 0.22, ease: "power3.out"}}, {t});')
            else:
                self.js.append(f'tl.fromTo("#{lid}-{i}", {{opacity: 1, color: "#3a3a3e"}}, {{opacity: 1, color: "#ffffff", duration: 0.2, ease: "power1.out"}}, {t});')
        if t_out is not None:
            self.js.append(f'tl.fromTo("#{lid}-in", {{opacity: 1, filter: "blur(0px)"}}, {{opacity: 0, filter: "blur(10px)", duration: 0.2, ease: "power1.in"}}, {r4(t_out - 0.2)});')
        return lid

    def render(self):
        return f"""<template>
  <style>
    {FONT_CSS}
    #root {{ position: absolute; inset: 0; overflow: hidden; background: #000; font-family: "SF Pro"; }}
    {"".join(self.css)}
  </style>
  <div id="root" data-composition-id="{self.id}" data-width="1920" data-height="1080" data-duration="{r4(self.dur)}">
    {chr(10).join("    " + h for h in self.html)}
  </div>
  <script>
    const tl = gsap.timeline({{ paused: true, defaults: {{ immediateRender: false }} }});
    {chr(10).join("    " + j for j in self.js)}
    tl.set({{}}, {{}}, {r4(self.dur)});
    window.__timelines["{self.id}"] = tl;
  </script>
</template>
"""


# ------------------------------------------------------------------------------------------------ the UI stage

STAGE_CSS = """
    .stage { position: absolute; inset: 0; perspective: 2400px; perspective-origin: 960px 540px; }
    .cam-c { position: absolute; left: 960px; top: 540px; width: 0; height: 0; transform-style: preserve-3d; }
    .cam-r { position: absolute; left: 0; top: 0; width: 0; height: 0; transform-style: preserve-3d; }
    .cam-s { position: absolute; left: 0; top: 0; width: 0; height: 0; transform-style: preserve-3d; }
    .cam-f { position: absolute; left: 0; top: 0; width: 0; height: 0; }
    .cam-z { position: absolute; left: 0; top: 0; width: 1470px; height: 956px; zoom: 3; }
    .scr { position: absolute; left: 0; top: 0; width: 1470px; height: 956px; overflow: hidden; border-radius: 10px;
           background: #0a0710; box-shadow: 0 0 0 14px #050506, 0 0 0 15.5px #2a2b30; }
    .scr img.wall { position: absolute; left: 0; top: 0; width: 1470px; height: 956px; }
    .mb { position: absolute; top: 0; height: 32px; line-height: 32px; color: rgba(255,255,255,0.9); font-size: 13px;
          font-weight: 500; white-space: nowrap; letter-spacing: -0.005em; }
    .mb b { font-weight: 700; margin-right: 12px; }
    .mb span { margin-right: 12px; }
    .isl { position: absolute; }
    .cur { position: absolute; left: 0; top: 0; }
    .cur img { position: absolute; }
    .dof { position: absolute; inset: 0; pointer-events: none; backdrop-filter: blur(7px); -webkit-backdrop-filter: blur(7px);
           -webkit-mask-image: radial-gradient(ellipse 52% 46% at 50% 34%, transparent 55%, #000 100%);
           mask-image: radial-gradient(ellipse 52% 46% at 50% 34%, transparent 55%, #000 100%); }
"""


def stage_html(sc, frames_html, extra_inside=""):
    p = sc.id
    menu = "".join(f"<span>{w}</span>" for w in ["File", "Edit", "View", "Go", "Window", "Help"])
    return f"""<div class="stage" id="{p}-stage"><div class="cam-c" id="{p}-c"><div class="cam-r" id="{p}-r"><div class="cam-s" id="{p}-s"><div class="cam-f" id="{p}-f"><div class="cam-z">
      <div class="scr"><img class="wall" src="assets/img/wallpaper-dark.jpg" alt="" />
        <img src="assets/ui/sym-apple.logo-white.png" alt="" style="position:absolute;left:6px;top:5px;width:30px;height:22px" />
        <div class="mb" style="left:38px"><b>Finder</b>{menu}</div>
        <div class="mb" style="left:1338px">Fri 23 Oct&nbsp;&nbsp;10:30</div>
      </div>
      {frames_html}
      {extra_inside}
    </div></div></div></div></div></div>
    <div class="dof" id="{p}-dof"></div>"""


ZOOM = 3  # the stage is laid out at 3x with CSS zoom so Chrome rasterizes it sharp; transforms stay at or under 1x


def stage_cam(sc, t, rx, ry, s, fx, fy, d=0, ease="power2.inOut"):
    p = sc.id
    s, fx, fy = s / ZOOM, fx * ZOOM, fy * ZOOM
    if d == 0:
        sc.js.append(f'tl.set("#{p}-r", {{rotationX: {rx}, rotationY: {ry}}}, {r4(t)});')
        sc.js.append(f'tl.set("#{p}-s", {{scale: {s:.4f}}}, {r4(t)});')
        sc.js.append(f'tl.set("#{p}-f", {{x: {-fx:.2f}, y: {-fy:.2f}}}, {r4(t)});')
    else:
        sc.js.append(f'tl.to("#{p}-r", {{rotationX: {rx}, rotationY: {ry}, duration: {d}, ease: "{ease}"}}, {r4(t)});')
        sc.js.append(f'tl.to("#{p}-s", {{scale: {s:.4f}, duration: {d}, ease: "{ease}"}}, {r4(t)});')
        sc.js.append(f'tl.to("#{p}-f", {{x: {-fx:.2f}, y: {-fy:.2f}, duration: {d}, ease: "{ease}"}}, {r4(t)});')


def stage_init(sc, rx, ry, s, fx, fy):
    p = sc.id
    s, fx, fy = s / ZOOM, fx * ZOOM, fy * ZOOM
    sc.js.insert(0, f'gsap.set("#{p}-s", {{scale: {s:.4f}, transformOrigin: "0 0"}}); gsap.set("#{p}-r", {{rotationX: {rx}, rotationY: {ry}, transformOrigin: "0 0"}}); gsap.set("#{p}-f", {{x: {-fx:.2f}, y: {-fy:.2f}}});')


class Frames:
    """Island frame clips inside a stage, in scene-local seconds."""

    def __init__(self, sc):
        self.sc, self.clips = sc, []

    def show(self, seq, t0, idxs, step=1, hold_until=None):
        for k, i in enumerate(idxs):
            s = t0 + k * step / FPS
            e = t0 + (k + 1) * step / FPS
            if k == len(idxs) - 1 and hold_until is not None:
                e = max(e, hold_until)
            self.clips.append((seq, i, s, e))
        return t0 + len(idxs) * step / FPS

    def hold(self, seq, i, t0, t1):
        self.clips.append((seq, i, t0, t1))

    def html(self):
        out = []
        for n, (seq, i, s, e) in enumerate(sorted(self.clips, key=lambda c: c[2])):
            m = M[seq]
            s2, e2 = max(0.0, s - 0.25 / FPS), e - 0.25 / FPS
            out.append(f'<img id="{self.sc.id}-i{n}" class="clip isl" data-start="{r4(s2)}" data-duration="{r4(e2 - s2)}" '
                       f'src="assets/frames/{seq}/{i:04d}.png" alt="" style="left:{r4(OX + m["x"])}px;top:{r4(m["y"])}px;'
                       f'width:{r4(m["w"])}px;height:{r4(m["h"])}px" />')
        return "\n      ".join(out)


# ------------------------------------------------------------------------------------------------ vector pieces

STAR_D = "M166.40 64.24C166.40 113.12 209.04 115.20 263.12 115.20C209.04 115.20 166.40 117.28 166.40 166.16C166.40 117.28 123.76 115.20 69.68 115.20C123.76 115.20 166.40 113.12 166.40 64.24Z"
STAR_C = (166.40, 115.20)
STAR_W = 263.12 - 69.68


def star_svg(sid, cx, cy, width, color="#fff", glow=True):
    k = width / STAR_W
    tx, ty = cx - STAR_C[0] * k, cy - STAR_C[1] * k
    g = f"translate({tx:.2f} {ty:.2f}) scale({k:.4f})"
    glows = ""
    if glow:
        glows = (f'<g id="{sid}-g2" opacity="0" filter="url(#{sid}-b2)"><path d="{STAR_D}" fill="{VIOLET}" transform="{g}"/></g>'
                 f'<g id="{sid}-g1" opacity="0" filter="url(#{sid}-b1)"><path d="{STAR_D}" fill="#efe9ff" transform="{g}"/></g>')
    return f"""<svg width="1920" height="1080" viewBox="0 0 1920 1080" style="position:absolute;left:0;top:0;overflow:visible">
      <defs><filter id="{sid}-b1" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="14"/></filter>
            <filter id="{sid}-b2" x="-80%" y="-120%" width="260%" height="340%"><feGaussianBlur stdDeviation="46"/></filter></defs>
      {glows}
      <g id="{sid}-core-g"><path id="{sid}-core" d="{STAR_D}" fill="{color}" transform="{g}"/></g>
    </svg>"""


def ignite(sc, sid, t, cx, cy):
    """Flow's star lights up: the vertical points snap open, the horizontal hairlines stretch out like light escaping."""
    sc.js.insert(0, f'gsap.set("#{sid}-core-g", {{scaleX: 0.02, scaleY: 0, svgOrigin: "{cx} {cy}"}});')
    sc.js.append(f'tl.to("#{sid}-core-g", {{scaleY: 1, duration: 0.24, ease: "back.out(2.4)", svgOrigin: "{cx} {cy}"}}, {r4(t)});')
    sc.js.append(f'tl.to("#{sid}-core-g", {{scaleX: 1, duration: 0.62, ease: "expo.out", svgOrigin: "{cx} {cy}"}}, {r4(t + 0.03)});')
    sc.js.append(f'tl.fromTo("#{sid}-g1", {{opacity: 0}}, {{opacity: 1, duration: 0.08}}, {r4(t)});')
    sc.js.append(f'tl.to("#{sid}-g1", {{opacity: 0.5, duration: 0.9, ease: "power2.out"}}, {r4(t + 0.1)});')
    sc.js.append(f'tl.fromTo("#{sid}-g2", {{opacity: 0}}, {{opacity: 0.95, duration: 0.1}}, {r4(t)});')
    sc.js.append(f'tl.to("#{sid}-g2", {{opacity: 0.42, duration: 1.4, ease: "power2.out"}}, {r4(t + 0.12)});')


def streak(sc, sid, t, cy, color="#e9e3ff"):
    sc.html.append(f'<div id="{sid}" style="position:absolute;left:0;top:{cy - 1}px;width:1920px;height:2px;opacity:0;'
                   f'background:linear-gradient(90deg,transparent,{color} 30%,#fff 50%,{color} 70%,transparent);'
                   f'filter:drop-shadow(0 0 6px {VIOLET});transform-origin:960px 1px"></div>')
    sc.js.append(f'tl.fromTo("#{sid}", {{scaleX: 0, opacity: 1}}, {{scaleX: 1, opacity: 1, duration: 0.42, ease: "expo.out"}}, {r4(t)});')
    sc.js.append(f'tl.to("#{sid}", {{opacity: 0, duration: 0.8, ease: "power2.out"}}, {r4(t + 0.18)});')


def pill_path_halves(x, y, w, h):
    r = h / 2
    cx = x + w / 2
    right = f"M{cx} {y} L{x + w - r} {y} A{r} {r} 0 0 1 {x + w - r} {y + h} L{cx} {y + h}"
    left = f"M{cx} {y} L{x + r} {y} A{r} {r} 0 0 0 {x + r} {y + h} L{cx} {y + h}"
    length = (w - 2 * r) / 2 * 2 + 3.14159 * r
    return right, left, length


# ================================================================================================ scenes

scenes = {}

# ---- 1. open: the island drawn in light ------------------------------------------------------------------------
sc = Scene("open", 7.2)
PX, PY, PW, PH = 600, 300, 720, 228
right, left, L = pill_path_halves(PX, PY, PW, PH)
sc.css.append(f"""
    #open-svg {{ position: absolute; left: 0; top: 0; }}
""")
sc.html.append(f"""<svg id="open-svg" width="1920" height="1080" viewBox="0 0 1920 1080">
      <defs>
        <linearGradient id="open-rim" gradientUnits="userSpaceOnUse" x1="{PX}" y1="0" x2="{PX + PW}" y2="0">
          <stop offset="0" stop-color="#6f5cff"/><stop offset="0.35" stop-color="{VIOLET}"/><stop offset="0.7" stop-color="#e58ad0"/><stop offset="1" stop-color="#8fb6ff"/>
        </linearGradient>
        <filter id="open-b1" x="-20%" y="-60%" width="140%" height="220%"><feGaussianBlur stdDeviation="7"/></filter>
        <filter id="open-b2" x="-30%" y="-90%" width="160%" height="280%"><feGaussianBlur stdDeviation="26"/></filter>
      </defs>
      <g id="open-halo" opacity="0" filter="url(#open-b2)"><rect x="{PX}" y="{PY}" width="{PW}" height="{PH}" rx="{PH / 2}" fill="none" stroke="url(#open-rim)" stroke-width="16"/></g>
      <g id="open-soft" filter="url(#open-b1)">
        <path id="open-rs" d="{right}" fill="none" stroke="url(#open-rim)" stroke-width="6" stroke-dasharray="{L:.1f}" stroke-dashoffset="{L:.1f}"/>
        <path id="open-ls" d="{left}" fill="none" stroke="url(#open-rim)" stroke-width="6" stroke-dasharray="{L:.1f}" stroke-dashoffset="{L:.1f}"/>
      </g>
      <path id="open-r" d="{right}" fill="none" stroke="url(#open-rim)" stroke-width="2.5" stroke-linecap="round" stroke-dasharray="{L:.1f}" stroke-dashoffset="{L:.1f}"/>
      <path id="open-l" d="{left}" fill="none" stroke="url(#open-rim)" stroke-width="2.5" stroke-linecap="round" stroke-dasharray="{L:.1f}" stroke-dashoffset="{L:.1f}"/>
    </svg>""")
for pid in ["open-rs", "open-ls", "open-r", "open-l"]:
    sc.js.append(f'tl.to("#{pid}", {{attr: {{"stroke-dashoffset": 0}}, duration: 1.5, ease: "power2.inOut"}}, 0.5);')
sc.js.append('tl.fromTo("#open-halo", {opacity: 0}, {opacity: 0.85, duration: 0.5, ease: "power2.out"}, 2.4);')
sc.js.append('tl.to("#open-halo", {opacity: 0.5, duration: 2.0, ease: "power1.inOut"}, 2.9);')
sc.js.append(f'tl.fromTo("#open-rim", {{attr: {{gradientTransform: "rotate(0 960 414)"}}}}, {{attr: {{gradientTransform: "rotate(160 960 414)"}}, duration: 4.6, ease: "none"}}, 2.4);')
sc.typed([("Your notch", "")], 2.6, 690, 96, rate=0.05)
sc.typed([("just got ", ""), ("smart.", "grad")], 4.8, 800, 96, rate=0.045)
sc.html.append('<div id="open-black" style="position:absolute;inset:0;background:#000;opacity:0"></div>')
sc.js.append('tl.fromTo("#open-black", {opacity: 0}, {opacity: 1, duration: 0.25, ease: "power1.in"}, 6.95);')
scenes["open"] = (sc, 0.0)

# ---- 3. meet: Flow's star ignites ------------------------------------------------------------------------------
sc = Scene("meet", 4.8)
sc.html.append(star_svg("meet-star", 960, 430, 600))
streak(sc, "meet-streak", 0.0, 430)
ignite(sc, "meet-star", 0.0, 960, 430)
sc.words([("Meet", ""), ("Flow.", "grad")], 0.55, 760, 132, gap=0.16, t_out=4.4)
sc.js.append('tl.to(["#meet-star-core-g", "#meet-star-g1", "#meet-star-g2"], {y: -560, scale: 0.2, svgOrigin: "960 430", duration: 0.42, ease: "power3.in"}, 4.38);')
scenes["meet"] = (sc, bar(6))

# ---- 4. learns: how you work, at the depth you choose ----------------------------------------------------------
sc = Scene("learns", 4.8)
sc.css.append("""
    .chips { position: absolute; inset: 0; perspective: 1300px; perspective-origin: 960px 330px; }
    .chip { position: absolute; left: 0; top: 0; height: 64px; padding: 0 26px 0 20px; border-radius: 32px; display: flex; align-items: center;
            gap: 12px; background: rgba(255,255,255,0.08); box-shadow: inset 0 0 0 1px rgba(255,255,255,0.16); color: #fff;
            font-size: 28px; font-weight: 600; letter-spacing: -0.01em; white-space: nowrap; opacity: 0; }
    .chip img { width: 38px; height: 28px; object-fit: contain; }
    .lvl { position: absolute; top: 620px; height: 84px; line-height: 84px; font-size: 54px; font-weight: 600; color: #5d5d63; letter-spacing: -0.02em; }
    #learns-cap { position: absolute; top: 595px; height: 134px; border-radius: 67px; opacity: 0;
                  background: linear-gradient(100deg, rgba(158,133,255,0.32), rgba(229,138,208,0.26)); box-shadow: inset 0 0 0 1.5px rgba(185,166,255,0.6); }
""")
sc.html.append(f"""<svg width="1920" height="1080" style="position:absolute;left:0;top:0">
      <defs><filter id="learns-b" x="-30%" y="-90%" width="160%" height="280%"><feGaussianBlur stdDeviation="20"/></filter>
            <linearGradient id="learns-rim" x1="0" x2="1"><stop offset="0" stop-color="#6f5cff"/><stop offset="0.5" stop-color="{VIOLET}"/><stop offset="1" stop-color="#e58ad0"/></linearGradient></defs>
      <g id="learns-halo" opacity="0.45" filter="url(#learns-b)"><rect x="700" y="248" width="520" height="165" rx="82.5" fill="none" stroke="url(#learns-rim)" stroke-width="14"/></g>
      <rect id="learns-pill" x="700" y="248" width="520" height="165" rx="82.5" fill="#000" stroke="url(#learns-rim)" stroke-width="2"/>
    </svg>""")
sc.html.append(star_svg("learns-star", 960, 330.5, 150, glow=False))
modes = [("Coding", "chevron.left.forwardslash.chevron.right"), ("Writing", "pencil.line"), ("Designing", "paintbrush.pointed.fill"),
         ("In a meeting", "video.fill"), ("Messages & mail", "bubble.left.and.bubble.right.fill"), ("Researching", "magnifyingglass"),
         ("Planning", "calendar"), ("Watching & listening", "play.rectangle.fill"), ("Reading", "book.fill")]
starts = [(-620, -40), (560, -150), (-430, 210), (640, 170), (-700, 120), (260, 300), (-210, -260), (430, -300), (-60, 340)]
chips = []
for i, ((label, sym), (dx, dy)) in enumerate(zip(modes, starts)):
    cid = f"learns-chip{i}"
    chips.append(f'<div class="chip" id="{cid}"><img src="assets/ui/sym-{sym}-white.png" alt="" />{label}</div>')
    t0 = 0.15 + i * 0.13
    sc.js.append(f'tl.fromTo("#{cid}", {{x: {960 + dx - 120}, y: {330 + dy}, z: -1500, opacity: 0}}, {{z: 0, opacity: 1, duration: 0.55, ease: "power3.out"}}, {r4(t0)});')
    sc.js.append(f'tl.to("#{cid}", {{x: 840, y: 300, z: -80, scale: 0.15, opacity: 0, duration: 0.42, ease: "power3.in"}}, {r4(t0 + 0.75)});')
sc.html.append(f'<div class="chips">{"".join(chips)}</div>')
sc.js.append('tl.to("#learns-halo", {opacity: 1, duration: 1.1, ease: "power1.in"}, 1.15);')
sc.js.append('tl.to("#learns-halo", {opacity: 0.5, duration: 0.5, ease: "power2.out"}, 2.3);')
sc.words([("It learns how you work.", "")], 0.35, 880, 92, t_out=2.35)
# the depth you choose: the app's own three levels
sc.html.append('<div id="learns-cap"></div>')
lv = [("Essentials", 470), ("Context", 860), ("Everything", 1190)]
for i, (name, x) in enumerate(lv):
    sc.html.append(f'<div class="lvl" id="learns-l{i}" style="left:{x}px;opacity:0">{name}</div>')
    sc.js.append(f'tl.fromTo("#learns-l{i}", {{opacity: 0, filter: "blur(10px)"}}, {{opacity: 1, filter: "blur(0px)", duration: 0.25, ease: "power3.out"}}, {r4(2.45 + i * 0.08)});')
caps = [(440, 330), (830, 270), (1160, 330)]
sc.js.append(f'tl.fromTo("#learns-cap", {{opacity: 0, x: {caps[0][0]}, width: {caps[0][1]}}}, {{opacity: 1, duration: 0.2}}, 2.7);')
sc.js.append('tl.set("#learns-l0", {color: "#ffffff"}, 2.7);')
for i in (1, 2):
    t = 2.7 + i * 0.6
    sc.js.append(f'tl.to("#learns-cap", {{x: {caps[i][0]}, width: {caps[i][1]}, duration: 0.42, ease: "expo.out"}}, {r4(t)});')
    sc.js.append(f'tl.set("#learns-l{i - 1}", {{color: "#5d5d63"}}, {r4(t + 0.05)});')
    sc.js.append(f'tl.set("#learns-l{i}", {{color: "#ffffff"}}, {r4(t + 0.05)});')
sc.words([("You choose how much it sees.", "")], 2.85, 790, 44, gap=0.06, color="#a1a1a6", weight=500)
sc.html.append('<div id="learns-black" style="position:absolute;inset:0;background:#000;opacity:0"></div>')
sc.js.append('tl.fromTo("#learns-black", {opacity: 0}, {opacity: 1, duration: 0.3, ease: "power1.in"}, 4.5);')
sc.js.append('tl.to(["#learns-pill", "#learns-halo"], {scale: 2.6, y: -330, svgOrigin: "960 330", duration: 0.32, ease: "power3.in"}, 4.48);')
scenes["learns"] = (sc, bar(8))

# ---- 5. moments: it speaks up at the right moment --------------------------------------------------------------
sc = Scene("moments", 9.6)
sc.css.append(STAGE_CSS)
F = Frames(sc)
F.hold("v2notch", 0, 0.0, 0.0001)
F.show("sMeeting", 0.0, list(range(19)), hold_until=1.8)
F.show("sAccept", 1.8, list(range(16)))
F.hold("sWrapTick", 0, 1.8 + 16 / FPS, 2.4)
F.hold("sWrapTick", 1, 2.4, 4.8)
cards = ["sFocus", "sError", "sRoutine", "sMusic", "sBreak", "sResume", "sRecap", "sQuestion"]
for k, name in enumerate(cards):
    t0 = 4.8 + 0.6 * k
    F.show(name, t0, [3, 5, 7, 9, 11, 13, 15, 18], hold_until=t0 + 0.6 if k < len(cards) - 1 else 9.6)
cursor = """<div class="cur" id="moments-cur" style="opacity:0">
        <img id="moments-arrow" src="assets/ui/cursor-arrow.png" alt="" style="left:-5px;top:-5px;width:28px;height:40px" />
        <img id="moments-hand" src="assets/ui/cursor-hand.png" alt="" style="left:-12px;top:-8px;width:32px;height:32px;opacity:0" />
      </div>"""
sc.html.append(stage_html(sc, F.html(), cursor))
stage_init(sc, 12, -14, 2.65, 735, 132)
stage_cam(sc, 0.0, 9, -8, 2.85, 760, 128, d=1.8, ease="power1.inOut")
sc.typed([("You’ve been coding for 52 minutes.", "")], 0.42, 820, 64, rate=0.024, t_out=2.25, align="left", x=200, width=1600)
sc.js.append('tl.set("#moments-cur", {opacity: 1}, 0.7);')
sc.js.append('tl.fromTo("#moments-cur", {x: 1180, y: 420}, {x: 881, y: 58, duration: 0.85, ease: "power3.inOut"}, 0.7);')
sc.js.append('tl.set("#moments-arrow", {opacity: 0}, 1.52); tl.set("#moments-hand", {opacity: 1}, 1.52);')
sc.js.append('tl.to("#moments-hand", {scale: 0.86, duration: 0.05, ease: "none", transformOrigin: "12px 8px"}, 1.74);')
sc.js.append('tl.to("#moments-hand", {scale: 1, duration: 0.12, ease: "power2.out"}, 1.8);')
sc.js.append('tl.to("#moments-cur", {x: 1150, y: 360, duration: 0.5, ease: "power3.in"}, 2.0);')
sc.js.append('tl.set("#moments-cur", {opacity: 0}, 2.5);')
# headline over the defocused stage
sc.js.append('tl.to("#moments-stage", {filter: "blur(16px) brightness(0.45)", duration: 0.35, ease: "power2.inOut"}, 2.35);')
sc.words([("It speaks up", "")], 2.5, 470, 132, gap=0.09, t_out=4.75)
sc.words([("at the ", ""), ("right moment.", "grad")], 2.85, 620, 132, gap=0.09, t_out=4.75)
sc.js.append('tl.set("#moments-stage", {filter: "blur(0px) brightness(1)"}, 4.8);')
angles = [(10, -16, 2.9, 735, 104), (6, 14, 2.75, 760, 98), (14, -6, 3.1, 700, 110), (8, 18, 2.8, 735, 100),
          (12, -14, 3.0, 770, 106), (4, 10, 2.7, 735, 96), (10, -18, 2.9, 712, 104), (8, 8, 2.6, 735, 128)]
for k, (rx, ry, s, fx, fy) in enumerate(angles):
    t0 = 4.8 + 0.6 * k
    stage_cam(sc, t0, rx, ry, s, fx, fy)
    stage_cam(sc, t0 + 0.02, rx * 0.8, ry * 0.8, s + 0.08, fx, fy, d=0.56, ease="power1.out")
scenes["moments"] = (sc, bar(10))

# ---- 6. ask: just ask -------------------------------------------------------------------------------------------
sc = Scene("ask", 7.2)
sc.css.append(STAGE_CSS)
F = Frames(sc)
t = F.show("openFlow", 1.2, list(range(19)))
t = F.show("flowType", t, list(range(22)))
F.hold("flowChat", 0, t, 3.0)
F.hold("flowChat", 1, 3.0, 3.4)
F.hold("flowChat", 2, 3.4, 3.6)
F.show("flowChat", 3.6, list(range(3, 12)), step=2)
F.hold("flowChat", 12, 3.6 + 18 / FPS, 4.8)
t = F.show("aOpen", 4.8, list(range(16)))
F.hold("aStream", 0, t, 5.6)
F.show("aStream", 5.6, list(range(1, 17)), step=2, hold_until=7.2)
sc.html.append(stage_html(sc, F.html()))
sc.html.append('<div id="ask-black" style="position:absolute;inset:0;background:#000"></div>')
sc.typed([("Just ask.", "")], 0.12, 540, 150, rate=0.07, t_out=1.15)
sc.js.append('tl.set("#ask-black", {opacity: 0}, 1.2);')
stage_init(sc, 10, 12, 2.0, 735, 165)
stage_cam(sc, 1.2, 8, 6, 2.2, 735, 158, d=3.6, ease="power1.inOut")
stage_cam(sc, 4.8, 10, -11, 1.85, 735, 182)
stage_cam(sc, 4.82, 7, -6, 1.98, 735, 178, d=2.38, ease="power1.inOut")
sc.words([("Ask about your day.", "")], 4.95, 935, 64, gap=0.07, t_out=7.15)
scenes["ask"] = (sc, bar(14))

# ---- 8. build: and that's just the brain -----------------------------------------------------------------------
sc = Scene("build", 4.8)
sc.css.append("""
    #build-edge { position: absolute; inset: 0; overflow: hidden; opacity: 0; }
    #build-conic { position: absolute; left: -440px; top: -980px; width: 2800px; height: 2800px; border-radius: 50%;
                   background: conic-gradient(from 0deg, #6f5cff, #9e85ff, #e58ad0, #ff9f6b, #8fb6ff, #6f5cff); filter: blur(46px); }
    #build-inner { position: absolute; left: 34px; top: 34px; width: 1852px; height: 1012px; border-radius: 46px; background: #000;
                   box-shadow: 0 0 46px 26px #000; }
    .bw { position: absolute; left: 0; width: 1920px; top: 540px; transform: translateY(-50%); text-align: center; color: #fff;
          font-size: 168px; font-weight: 700; letter-spacing: -0.035em; opacity: 0; }
""")
sc.html.append('<div id="build-edge"><div id="build-conic"></div><div id="build-inner"></div></div>')
sc.html.append(star_svg("build-star", 960, 470, 160))
sc.js.append('tl.fromTo("#build-edge", {opacity: 0}, {opacity: 1, duration: 2.3, ease: "power2.in"}, 0.0);')
sc.js.append('tl.fromTo("#build-conic", {rotation: 0}, {rotation: 300, duration: 4.8, ease: "none"}, 0.0);')
sc.js.append('tl.fromTo(["#build-star-g1", "#build-star-g2"], {opacity: 0.2}, {opacity: 0.9, duration: 2.3, ease: "power2.in"}, 0.0);')
sc.words([("And that’s just the ", ""), ("brain.", "grad")], 0.25, 700, 88, gap=0.08, t_out=2.3)
sc.js.append('tl.to(["#build-star-core-g", "#build-star-g1", "#build-star-g2"], {opacity: 0, duration: 0.12}, 2.3);')
for i, (w, tw) in enumerate([("Music.", 2.4), ("Calls.", 3.0), ("Timers.", 3.6), ("AirPods.", 4.2)]):
    wid = f"build-w{i}"
    sc.html.append(f'<div class="bw" id="{wid}">{w}</div>')
    sc.js.append(f'tl.fromTo("#{wid}", {{opacity: 1, scale: 1.12, filter: "blur(10px)"}}, {{scale: 1, filter: "blur(0px)", duration: 0.22, ease: "expo.out"}}, {r4(tw)});')
    sc.js.append(f'tl.set("#{wid}", {{opacity: 0}}, {r4(tw + 0.6 if i < 3 else 4.8)});')
    sc.js.append(f'tl.set("#build-inner", {{boxShadow: "0 0 26px 8px #000"}}, {r4(tw)});')
    sc.js.append(f'tl.to("#build-inner", {{boxShadow: "0 0 46px 26px #000", duration: 0.5, ease: "power2.out"}}, {r4(tw + 0.01)});')
scenes["build"] = (sc, bar(18))

# ---- 9. live: plus everything live -----------------------------------------------------------------------------
sc = Scene("live", 4.8)
sc.css.append(STAGE_CSS)
F = Frames(sc)
for k in range(10):
    F.show(f"m5_{k:02d}", 0.3 * k, list(range(9)))
F.show("home5", 3.0, list(range(49)), hold_until=4.8)
sc.html.append(stage_html(sc, F.html()))
stage_init(sc, 8, -12, 2.75, 735, 112)
for b in range(5):
    t0 = 0.6 * b
    if b % 2:
        stage_cam(sc, t0, 6, 12, 3.0, 745, 106)
    else:
        stage_cam(sc, t0, 9, -12, 2.75, 725, 112)
stage_cam(sc, 3.0, 4, 0, 1.32, 735, 300, d=1.8, ease="power2.inOut")
sc.words([("Plus everything ", ""), ("live.", "grad")], 0.3, 900, 92, gap=0.09, t_out=2.95, align="left", x=190, width=1600)
scenes["live"] = (sc, bar(20))

# ---- 11. end: the notch that thinks -----------------------------------------------------------------------------
sc = Scene("end", 10.0)
sc.words([("The notch that ", ""), ("thinks.", "grad")], 0.05, 540, 124, gap=0.14, t_out=2.3, mode="blur")
stacked = open(os.path.join(ROOT, "assets/brand/macflow-logo-stacked-dark.svg")).read()
paths = re.findall(r'<path fill="(#[0-9A-Fa-f]{6})"(?: fill-rule="evenodd")? d="([^"]+)"', stacked)
star_in_mark = "M" + paths[0][1].split("ZM", 1)[1]
word_svg = "".join(f'<path fill="{c}" d="{d}"/>' for c, d in paths[1:])
LK = 360 / 404
LX, LY = 960 - 393.83 * LK, 420 - 128 * LK
mx, my, mw, mh = 191.83 * LK + LX, 64 * LK + LY, 404 * LK, 128 * LK
sc.html.append(f"""<svg width="1920" height="1080" viewBox="0 0 1920 1080" style="position:absolute;left:0;top:0;overflow:visible">
      <defs><filter id="end-b1" x="-50%" y="-80%" width="200%" height="260%"><feGaussianBlur stdDeviation="12"/></filter>
            <filter id="end-b2" x="-80%" y="-160%" width="260%" height="420%"><feGaussianBlur stdDeviation="40"/></filter></defs>
      <g id="end-g2" opacity="0" filter="url(#end-b2)"><path d="{star_in_mark}" fill="{VIOLET}" transform="translate({LX:.3f} {LY:.3f}) scale({LK:.5f})"/></g>
      <rect id="end-pill" x="{mx:.2f}" y="{my:.2f}" width="{mw:.2f}" height="{mh:.2f}" rx="{mh / 2:.2f}" fill="#fff" opacity="0"/>
      <g id="end-g1" opacity="0" filter="url(#end-b1)"><path d="{star_in_mark}" fill="#efe9ff" transform="translate({LX:.3f} {LY:.3f}) scale({LK:.5f})"/></g>
      <g id="end-core-g"><path id="end-core" d="{star_in_mark}" fill="#fff" transform="translate({LX:.3f} {LY:.3f}) scale({LK:.5f})"/></g>
    </svg>
    <div id="end-word" style="position:absolute;left:{LX:.2f}px;top:{LY:.2f}px;width:{787 * LK:.2f}px;height:{439 * LK:.2f}px">
      <svg width="{787 * LK:.2f}" height="{439 * LK:.2f}" viewBox="0 0 787 439">{word_svg}</svg></div>""")
cy = 128 * LK + LY
ignite(sc, "end", 2.4, 960, cy)
streak(sc, "end-streak", 2.4, cy)
sc.js.append(f'tl.fromTo("#end-pill", {{opacity: 1, scaleX: 0.08, scaleY: 0.5, svgOrigin: "960 {cy:.2f}"}}, {{scaleX: 1, scaleY: 1, duration: 0.55, ease: "expo.out"}}, 2.62);')
sc.js.append('tl.set("#end-core", {attr: {fill: "#000"}}, 2.62);')
sc.js.append('tl.to(["#end-g1", "#end-g2"], {opacity: 0, duration: 0.6, ease: "power2.out"}, 2.7);')
sc.js.append('gsap.set("#end-word", {clipPath: "inset(0px 100% 0px 0px)"});')
sc.js.append('tl.to("#end-word", {clipPath: "inset(0px 0% 0px 0px)", duration: 0.7, ease: "power3.out"}, 3.05);')
sc.words([("For macOS 14 or later", "")], 3.9, 700, 34, gap=0.06, color="#8e8e93", weight=500)
sc.html.append('<div id="end-black" style="position:absolute;inset:0;background:#000;opacity:0"></div>')
sc.js.append('tl.fromTo("#end-black", {opacity: 0}, {opacity: 1, duration: 0.45, ease: "power1.in"}, 9.5);')
scenes["end"] = (sc, bar(25))

# ---- titles over the 3D shots ----------------------------------------------------------------------------------
sc = Scene("titles", DUR)
sc.css.append("#root { background: transparent !important; } .h { text-shadow: 0 2px 24px rgba(0,0,0,0.6); }")
sc.words([("It thinks on your Mac.", "")], 40.95, 850, 80, t_out=43.15)
sc.words([("Nothing ", ""), ("leaves it.", "grad")], 41.6, 950, 80, t_out=43.15)
scenes["titles"] = (sc, 0.0)

# ================================================================================================ the 3D MacBook

MAC_TEMPLATE = open(os.path.join(ROOT, "tools/mac3d.template.html")).read()  # a standalone document: it loads Three.js itself


def mac_scene(sid, dur, shot, start):
    if shot == "glide":
        screen = {"layers": [["v2notch", 0, 0]]}
    elif shot == "privacy":
        screen = {"layers": [["aStream", 16, 0]]}
    else:
        screen = {"layers": [["home5", "seq", 49]]}
    html = (MAC_TEMPLATE.replace("__ID__", sid).replace("__DUR__", r4(dur)).replace("__SHOT__", shot)
            .replace("__MANIFEST__", json.dumps({k: M[k] for k in ("v2notch", "aStream", "home5")}))
            .replace("__SCREEN__", json.dumps(screen)))
    return html, start


mac = {
    "macglide": mac_scene("macglide", 7.2, "glide", bar(3)),
    "macprivacy": mac_scene("macprivacy", 2.4, "privacy", bar(17)),
    "machero": mac_scene("machero", 7.2, "hero", bar(22)),
}

# ================================================================================================ sound

def sfx(name, at, vol, peak=True, dur=None, duck=0):
    """Place an effect so its measured peak (or onset) lands one frame after `at`; duck the music by `duck` dB under it."""
    p = PEAK[name]["peak" if peak else "onset"]
    return (name, round(at + 1 / FPS - p, 3), vol, dur, duck)


# Levels set by measurement against the bed (tools/mixdown.py prints each effect over the music):
# hits +3..6 dB, UI sounds and clicks +2..5 dB with a short duck, whooshes and risers just under to level.
SFX = [
    sfx("swoosh-010", 0.75, 0.75),
    sfx("sub-bass-boom", 2.4, 0.3, peak=False),
    sfx("whoosh-cinematic", 7.2, 0.95, duck=2),
    sfx("riser-cinematic-03", 14.4, 0.7),
    sfx("impact-boom-05", 14.4, 1.0, peak=False, duck=3),
    sfx("shine-11", 14.42, 1.8, peak=False),
    sfx("swoosh-015", 19.2, 1.1, duck=2),
    sfx("click-ui-button", 21.9, 0.55, peak=False, duck=3),
    sfx("click-ui-button", 22.5, 0.95, peak=False, duck=4),
    sfx("click-ui-button", 23.1, 0.95, peak=False, duck=4),
    sfx("soft-notification", 24.05, 1.1, peak=False, duck=4),
    sfx("click-ui-button", 25.78, 1.3, peak=False, duck=6),
    sfx("swoosh-010", 26.4, 0.8, duck=2),
    sfx("whoosh-simple", 28.8, 0.8, duck=2),
    sfx("swoosh-015", 30.0, 0.95, duck=2),
    sfx("whoosh-simple", 31.2, 0.75, duck=2),
    sfx("swoosh-010", 32.4, 0.7, duck=2),
    ("keyboard-typing", round(bar(14) + 1.83 - 0.45, 3), 0.9, 0.8, 3),
    sfx("pop-bubble-06", bar(14) + 3.0, 0.32, peak=False),
    sfx("pop-bubble-06", bar(14) + 3.4, 0.3, peak=False),
    sfx("ui-interface-03", bar(14) + 4.8, 0.2, peak=False),
    sfx("whoosh-cinematic", bar(17), 0.45),
    sfx("reverse-cymbal", bar(19), 0.75),
    sfx("impact-boom-03", bar(19), 0.95, peak=False, duck=3),
    sfx("sub-bass-boom", bar(20), 0.55, peak=False),
    sfx("swoosh-015", bar(20) + 1.2, 0.85, duck=2),
    sfx("whoosh-simple", bar(20) + 2.4, 0.75, duck=2),
    sfx("swoosh-010", bar(22), 0.8, duck=2),
    sfx("riser-cinematic-03", bar(26), 0.7),
    sfx("impact-boom-05", bar(26), 1.05, peak=False, duck=3),
    sfx("shine-11", bar(26) + 0.02, 1.8, peak=False),
]

# ================================================================================================ write

os.makedirs(os.path.join(ROOT, "compositions"), exist_ok=True)
hosts = []
z = 1
for sid, (s, start) in scenes.items():
    open(os.path.join(ROOT, f"compositions/{sid}.html"), "w").write(s.render())
    zz = 50 if sid == "titles" else z
    hosts.append(f'<div id="{sid}" data-composition-id="{sid}" data-composition-src="compositions/{sid}.html" data-start="{r4(start)}" '
                 f'data-duration="{r4(s.dur)}" data-track-index="{zz}" data-track-kind="graphics" data-width="1920" data-height="1080" style="z-index:{zz}"></div>')
    z += 1
for sid, (html, start) in mac.items():
    open(os.path.join(ROOT, f"compositions/{sid}.html"), "w").write(html)
    dur = {"macglide": 7.2, "macprivacy": 2.4, "machero": 7.2}[sid]
    hosts.append(f'<div id="{sid}" data-composition-id="{sid}" data-composition-src="compositions/{sid}.html" data-start="{r4(start)}" '
                 f'data-duration="{r4(dur)}" data-track-index="{z}" data-track-kind="graphics" data-width="1920" data-height="1080" style="z-index:{z}"></div>')
    z += 1

# The cue sheet: tools/mixdown.py mixes the mastered music and every effect through a true-peak limiter into one
# master track (assets/audio/mix.wav), so loudness is set once, by us, and the renderer never has to pull it down.
json.dump({"music": {"file": "assets/audio/music-master.wav", "volume": 0.6, "fade_out": 1.4, "duration": DUR},
           "sfx": [{"name": n, "file": f"assets/audio/sfx/{n}.mp3", "start": max(0.0, at), "volume": v, "duration": d,
                    "duck": dk, "peak": PEAK[n]["peak"] if not d else 0.45}
                   for n, at, v, d, dk in SFX]},
          open(os.path.join(ROOT, "assets/audio/cues.json"), "w"), indent=1)
audio = [f'<audio id="mix" class="clip" data-start="0" data-duration="{r4(DUR)}" data-track-index="60" data-volume="1" src="assets/audio/mix.wav"></audio>']

index = f"""<!doctype html>
<html lang="en" data-resolution="landscape">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=1920, height=1080" />
    <title>Mac Flow — The notch that thinks</title>
    <script src="https://cdn.jsdelivr.net/npm/gsap@3.14.2/dist/gsap.min.js"></script>
    <style>
      * {{ margin: 0; padding: 0; box-sizing: border-box; }}
      html, body {{ width: 1920px; height: 1080px; overflow: hidden; background: #000; }}
      #root {{ position: relative; width: 1920px; height: 1080px; background: #000; }}
    </style>
  </head>
  <body>
    <div id="root" data-composition-id="main" data-start="0" data-duration="{r4(DUR)}" data-width="1920" data-height="1080">
      {chr(10).join("      " + h for h in hosts)}
      {chr(10).join("      " + a for a in audio)}
    </div>
    <script>
      window.__timelines = window.__timelines || {{}};
      const tl = gsap.timeline({{ paused: true }});
      tl.set({{}}, {{}}, {r4(DUR)});
      window.__timelines["main"] = tl;
    </script>
  </body>
</html>
"""
open(os.path.join(ROOT, "index.html"), "w").write(index)
print("scenes:", ", ".join(list(scenes) + list(mac)), "| sfx:", len(SFX))
