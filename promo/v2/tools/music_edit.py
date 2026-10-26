"""Cut "Creative Technology Showreel" (Pumpupthemind, Pixabay) to the film: 100 BPM, bars every 2.4 s from 0.095 s.

Film bar n starts at 2.4 n s. Segments (track seconds):
  A  0.095 -> 31.295   intro + drop A (bars 0-12)
  B 50.495 -> 79.295   transition bar 21, breakdown 22-25, build 26, drop B 27-32
  C 98.495 -> end      bar 41, the ending hit (bar 42), the tail
Edits sit on downbeats whose bars match (13~21, 33~41), with 12 ms equal-power crossfades.
"""
import sys
import numpy as np
from scipy.io import wavfile

src, dst = sys.argv[1], sys.argv[2]
sr, x = wavfile.read(src)
x = x.astype(np.float64) / (32768.0 if x.dtype == np.int16 else 1.0)
segs = [(0.095, 31.295), (50.495, 79.295), (98.495, None)]
fade = int(0.012 * sr)
out = None
for a, b in segs:
    i = int(round(a * sr))
    j = len(x) if b is None else int(round(b * sr))
    s = x[i - fade if out is not None else i:j].copy()
    if out is None:
        out = s
        continue
    t = np.linspace(0, np.pi / 2, fade)[:, None]
    head, tail = s[:fade], out[-fade:]
    mixed = tail * np.cos(t) + head * np.sin(t)
    out = np.concatenate([out[:-fade], mixed, s[fade:]])
# end: a long fade so the ring-out lands in silence
dur = len(out) / sr
print(f"edited length {dur:.3f} s")
wavfile.write(dst, sr, out.astype(np.float32))
