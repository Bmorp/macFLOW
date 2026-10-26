"""Bar-by-bar chroma of the track, to find edit points whose harmony matches.
python tools/bars.py <track> <beats.json>   (beats.json: the `hyperframes audio --json` output)"""
import json
import subprocess
import sys
import numpy as np

SR = 22050
track, analysis = sys.argv[1], sys.argv[2]
raw = subprocess.run(["ffmpeg", "-v", "error", "-i", track, "-f", "f32le", "-ac", "1", "-ar", str(SR), "-"],
                     check=True, capture_output=True).stdout
x = np.frombuffer(raw, dtype=np.float32)
down = json.load(open(analysis))["items"][0]["downbeats"]["times"]

n, hop = 4096, 1024
win = np.hanning(n)
frames = np.lib.stride_tricks.sliding_window_view(x, n)[::hop] * win
mag = np.abs(np.fft.rfft(frames, axis=1))
freqs = np.fft.rfftfreq(n, 1 / SR)
keep = (freqs > 60) & (freqs < 4000)
pitch = (np.round(12 * np.log2(freqs[keep] / 440)) % 12).astype(int)
chroma = np.zeros((len(mag), 12))
for k in range(12):
    chroma[:, k] = mag[:, keep][:, pitch == k].sum(1)
t = np.arange(len(mag)) * hop / SR


def bar(i):
    m = (t >= down[i]) & (t < down[i + 1])
    v = chroma[m].mean(0)
    return v / (np.linalg.norm(v) + 1e-9)


bars = np.array([bar(i) for i in range(len(down) - 1)])
np.save("/tmp/amalgam-bars.npy", bars)
sim = bars @ bars.T


def show(src_range, dst_range):
    # jumping from the end of bar a to the start of bar b sounds right when bar a ~ bar b-1
    best = sorted(((sim[a, b - 1], a, b) for a in src_range for b in dst_range), reverse=True)[:8]
    for s, a, b in best:
        print(f"  end of bar {a:3d} ({down[a + 1]:7.3f}s) -> bar {b:3d} ({down[b]:7.3f}s)  match {s:.3f}")


for name, a, b in [("B -> G (calm)", range(13, 21), range(73, 82)), ("B return -> ending hit", range(90, 99), range(101, 104)),
                   ("intro -> B", range(3, 8), range(8, 9))]:
    print(name)
    show(a, b)
