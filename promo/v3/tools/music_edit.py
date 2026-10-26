"""Cut "AMALGAM" (Rockot, Pixabay) to the film: ~110 BPM, edits on downbeats whose harmony matches (tools/bars.py).

Segments (track seconds -> film seconds):
  intro + drop A   11.355 -> 39.925   (bars 5-17)      film  0.000 -> 28.570   drop A lands at film 8.660
  calm, hush, B   171.125 -> 206.035  (bars 78-93)     film 28.570 -> 63.480   hush 43.855, drop B 46.005
  final hit       223.465 -> ...      (bar 102 + tail) film 63.480 -> end, faded under the end card
Seams: bar 17 ~ bar 77 (chroma 0.943), bar 93 ~ bar 101 (0.997); 12 ms equal-power crossfades.
python tools/music_edit.py <track.mp3> <out.wav> [length]
"""
import subprocess
import sys
import numpy as np
from scipy.io import wavfile

SR = 48000
src, dst = sys.argv[1], sys.argv[2]
length = float(sys.argv[3]) if len(sys.argv) > 3 else 70.0
raw = subprocess.run(["ffmpeg", "-v", "error", "-i", src, "-f", "f32le", "-ac", "2", "-ar", str(SR), "-"], check=True, capture_output=True).stdout
x = np.frombuffer(raw, dtype=np.float32).reshape(-1, 2).astype(np.float64)

segs = [(11.355, 39.925), (171.125, 206.035), (223.465, None)]
fade = int(0.012 * SR)
out = None
for a, b in segs:
    i = int(round(a * SR))
    j = len(x) if b is None else int(round(b * SR))
    s = x[i - fade if out is not None else i:j].copy()
    if out is None:
        out = s
        continue
    t = np.linspace(0, np.pi / 2, fade)[:, None]
    mixed = out[-fade:] * np.cos(t) + s[:fade] * np.sin(t)
    out = np.concatenate([out[:-fade], mixed, s[fade:]])

n = int(length * SR)
out = out[:n]
# the final hit rings out under the end card: hold 2.2 s after it, then a slow fade to silence at the end
f0 = int((63.48 + 2.2) * SR)
k = np.ones(len(out))
k[f0:] = np.linspace(1, 0, len(out) - f0) ** 2
out *= k[:, None]
print(f"edited length {len(out) / SR:.3f} s")
wavfile.write(dst, SR, out.astype(np.float32))
