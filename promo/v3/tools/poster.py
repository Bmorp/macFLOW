"""The README poster: one frame of the film with a play button, 16:9, JPEG.
python tools/poster.py <frame.jpg> <out.jpg>"""
import sys
from PIL import Image, ImageDraw, ImageFilter

src, dst = sys.argv[1], sys.argv[2]
im = Image.open(src).convert("RGB")
W, H = im.size
S = 3  # supersample the overlay so its edges are smooth
ov = Image.new("RGBA", (W * S, H * S), (0, 0, 0, 0))
d = ImageDraw.Draw(ov)
cx, cy, r = W * S // 2, int(H * 0.66) * S, int(H * 0.085) * S
# a soft shadow, a frosted disc, the triangle
shadow = Image.new("RGBA", ov.size, (0, 0, 0, 0))
ImageDraw.Draw(shadow).ellipse((cx - r, cy - r + 14 * S, cx + r, cy + r + 14 * S), fill=(0, 0, 0, 120))
ov = Image.alpha_composite(ov, shadow.filter(ImageFilter.GaussianBlur(28 * S)))
d = ImageDraw.Draw(ov)
d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(255, 255, 255, 235))
t = r * 0.42
d.polygon([(cx - t * 0.62, cy - t * 0.95), (cx - t * 0.62, cy + t * 0.95), (cx + t * 1.02, cy)], fill=(10, 10, 11, 255))
ov = ov.resize((W, H), Image.LANCZOS)
im = Image.alpha_composite(im.convert("RGBA"), ov)
im.convert("RGB").save(dst, quality=90, optimize=True)
print(dst, im.size)
