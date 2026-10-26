"""Crop each rendered island sequence to its union alpha box, write a manifest (sizes in points), merge into assets/frames.
python tools/crop_frames.py <rendered dir> <assets/frames> <scale>   (the film harness renders at FILM_SCALE=5)"""
import glob
import json
import os
import shutil
import sys
from PIL import Image

src, dst, SCALE = sys.argv[1], sys.argv[2], int(sys.argv[3])
CANVAS_PT = 804
os.makedirs(dst, exist_ok=True)
mpath = os.path.join(dst, "manifest.json")
man = json.load(open(mpath)) if os.path.exists(mpath) else {}
for d in sorted(glob.glob(src + "/*/")):
    name = os.path.basename(d.rstrip("/"))
    if name in ("extras", "standby"):
        continue
    files = sorted(glob.glob(d + "*.png"))
    box = None
    for f in files:
        bb = Image.open(f).getchannel("A").point(lambda a: 255 if a > 2 else 0).getbbox()
        if bb:
            box = bb if box is None else (min(box[0], bb[0]), min(box[1], bb[1]), max(box[2], bb[2]), max(box[3], bb[3]))
    if box is None:
        box = (0, 0, 3, 3)
    x0 = max(0, (box[0] - 6) // SCALE * SCALE)
    y0 = 0
    x1 = (box[2] + 6 + SCALE - 1) // SCALE * SCALE
    y1 = (box[3] + 6 + SCALE - 1) // SCALE * SCALE
    out = os.path.join(dst, name)
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    for i, f in enumerate(files):
        Image.open(f).crop((x0, y0, x1, y1)).save(os.path.join(out, f"{i:04d}.png"), optimize=True)
    man[name] = {"count": len(files), "x": x0 / SCALE, "y": y0 / SCALE, "w": (x1 - x0) / SCALE, "h": (y1 - y0) / SCALE, "cw": CANVAS_PT}
    print(name, man[name])
json.dump(man, open(mpath, "w"), indent=1)
