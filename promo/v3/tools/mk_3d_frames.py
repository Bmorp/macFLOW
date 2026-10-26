"""The MacBook's screen texture is 2 px per point, so its island frames need 2x, not the 5x the flat desktop shots use:
decoding 23 frames of 3260 px at once runs a browser out of memory. Writes assets/frames-3d/<seq>/ at 0.4x.
python tools/mk_3d_frames.py p_open p_hold"""
import glob
import os
import shutil
import sys
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
for seq in sys.argv[1:]:
    out = os.path.join(ROOT, "assets/frames-3d", seq)
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    for f in sorted(glob.glob(os.path.join(ROOT, "assets/frames", seq, "*.png"))):
        im = Image.open(f)
        im.resize((round(im.width * 0.4), round(im.height * 0.4)), Image.LANCZOS).save(os.path.join(out, os.path.basename(f)), optimize=True)
    print(seq, len(os.listdir(out)), "frames")
