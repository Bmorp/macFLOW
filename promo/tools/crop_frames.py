"""Crop each rendered island sequence to its union alpha box and write a manifest (sizes in points)."""
import sys, os, glob, json, shutil
from PIL import Image
src, dst = sys.argv[1], sys.argv[2]
SCALE = 3
os.makedirs(dst, exist_ok=True)
man = {}
for d in sorted(glob.glob(src + "/*/")):
    name = os.path.basename(d.rstrip("/"))
    if name == "extras":
        continue
    files = sorted(glob.glob(d + "*.png"))
    box = None
    for f in files:
        bb = Image.open(f).getchannel("A").point(lambda a: 255 if a > 2 else 0).getbbox()
        if not bb:
            continue
        box = bb if box is None else (min(box[0], bb[0]), min(box[1], bb[1]), max(box[2], bb[2]), max(box[3], bb[3]))
    if box is None:
        box = (0, 0, 3, 3)
    # pad and snap to the 3x grid so point offsets stay whole
    x0 = max(0, (box[0] - 6) // SCALE * SCALE); y0 = 0
    x1 = (box[2] + 6 + SCALE - 1) // SCALE * SCALE; y1 = (box[3] + 6 + SCALE - 1) // SCALE * SCALE
    out = os.path.join(dst, name); os.makedirs(out, exist_ok=True)
    for i, f in enumerate(files):
        Image.open(f).crop((x0, y0, x1, y1)).save(os.path.join(out, f"{i:04d}.png"), optimize=True)
    man[name] = {"count": len(files), "x": x0 / SCALE, "y": y0 / SCALE, "w": (x1 - x0) / SCALE, "h": (y1 - y0) / SCALE}
    print(name, man[name])
json.dump(man, open(os.path.join(dst, "manifest.json"), "w"), indent=1)
