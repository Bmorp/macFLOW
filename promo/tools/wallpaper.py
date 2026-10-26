"""An original desktop picture: layered sheets of warm silk under a light dawn sky, with two soft ribbons high up.
2x of a 1470x956 pt display."""
import sys, numpy as np
from PIL import Image, ImageFilter
out = sys.argv[1]
W, H = 2940, 1912
y, x = np.mgrid[0:H, 0:W].astype(np.float32)
u, v = x / W, y / H
def hexc(h): return np.array([int(h[i:i+2], 16) / 255 for i in (1, 3, 5)], np.float32)
sky_top, sky_low = hexc("#FBF5EE"), hexc("#F6D9C2")
img = sky_top + (sky_low - sky_top) * (np.clip(v / 0.7, 0, 1)[..., None] ** 1.3)

# Two soft ribbons high in the sky, so the area around the notch has colour and depth.
for (a, b, c, w, col, al) in [(0.06, 0.34, 0.9, 0.07, "#F4B48C", 0.55), (0.18, 0.22, 2.2, 0.05, "#EE8F86", 0.40)]:
    cy = a + b * u + 0.05 * np.sin(2 * np.pi * c * u + 0.6)
    d = (v - cy) / w
    prof = np.exp(-d ** 2 * 2.2) * (0.6 + 0.4 * np.exp(-((d + 0.35) / 0.25) ** 2))
    img = img * (1 - (prof * al)[..., None]) + hexc(col) * (prof * al)[..., None]

sheets = [  # edge height, waves, light, mid, deep, tilt
    (0.56, [(0.050, 1.0, 0.3), (0.020, 2.7, 1.9)], "#FAD3B4", "#F2A982", "#E58866", -0.10),
    (0.64, [(0.045, 0.8, 2.0), (0.022, 2.2, 0.4)], "#F6B193", "#E5806E", "#C9586A", -0.16),
    (0.72, [(0.040, 1.2, 4.1), (0.018, 3.0, 2.2)], "#EE8E80", "#CF5A6E", "#9E3A5E", -0.08),
    (0.81, [(0.036, 0.9, 1.1), (0.016, 2.5, 3.0)], "#D46A7C", "#A9406A", "#6E2A52", -0.12),
    (0.90, [(0.030, 1.1, 3.0), (0.014, 2.0, 0.8)], "#A9466E", "#7B2D5A", "#3F1A38", -0.06),
]
for base, waves, cl, cm, cd, tilt in sheets:
    cy = base + tilt * (u - 0.5)
    for amp, f, p in waves:
        cy = cy + amp * np.sin(2 * np.pi * f * u + p)
    dist = (v - cy)  # >0 below the edge
    cover = np.clip(dist * H / 2.0, 0, 1)  # 2px antialiased edge
    depth = np.clip(dist / 0.16, 0, 1)
    col = np.where(depth[..., None] < 0.18,
                   hexc(cl) + (hexc(cm) - hexc(cl)) * (depth / 0.18)[..., None],
                   hexc(cm) + (hexc(cd) - hexc(cm)) * np.clip((depth - 0.18) / 0.82, 0, 1)[..., None] ** 0.9)
    # a satin highlight just under the fold, and a slow sheen along the cloth
    col = col + np.exp(-((dist - 0.012) / 0.006) ** 2)[..., None] * 0.16
    col = col + (0.05 * np.sin(2 * np.pi * (1.6 * u + 6 * dist) + base * 9))[..., None] * (depth[..., None] > 0.1)
    # contact shadow on what lies behind, just above this edge
    occl = np.clip(1 + dist / 0.03, 0, 1) * (dist < 0)
    img = img * (1 - 0.10 * occl[..., None])
    img = img * (1 - cover[..., None]) + np.clip(col, 0, 1) * cover[..., None]
rng = np.random.default_rng(3)
img = np.clip(img + rng.normal(0, 0.006, (H, W, 1)).astype(np.float32), 0, 1)
Image.fromarray((img * 255).astype(np.uint8)).save(out, quality=94)
print("ok", out)
