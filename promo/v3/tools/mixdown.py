"""Mix the film's sound: the mastered music plus every effect from assets/audio/cues.json, through a 4x-oversampled
true-peak limiter, to -14 LUFS integrated / -1.2 dBTP. Writes assets/audio/mix.wav (48 kHz stereo float).
Run from promo/v2 after build_v2.py:  python3 tools/mixdown.py [path/to/ffmpeg]
"""
import json
import os
import subprocess
import sys
import numpy as np
from scipy import signal
from scipy.io import wavfile
from scipy.ndimage import maximum_filter1d

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FFMPEG = sys.argv[1] if len(sys.argv) > 1 else "ffmpeg"
SR = 48000
cues = json.load(open(os.path.join(ROOT, "assets/audio/cues.json")))


def load(path):
    raw = subprocess.run([FFMPEG, "-v", "error", "-i", os.path.join(ROOT, path), "-f", "f32le", "-ac", "2", "-ar", str(SR), "-"],
                         check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype=np.float32).reshape(-1, 2).astype(np.float64)


N = int(cues["music"]["duration"] * SR)
mix = np.zeros((N, 2))
music = load(cues["music"]["file"])[:N] * cues["music"]["volume"]
fo = int(cues["music"]["fade_out"] * SR)
if fo:
    music[-fo:] *= np.linspace(1, 0, fo)[:, None] ** 1.5
# duck the bed under clicks, UI sounds and whooshes: 40 ms down, hold through the hit, 220 ms back
t = np.arange(len(music)) / SR
duck_db = np.zeros(len(music))
for c in cues["sfx"]:
    if c.get("duck"):
        tp = c["start"] + c["peak"]
        env = np.interp(t, [tp - 0.10, tp - 0.06, tp + 0.10, tp + 0.32], [0, c["duck"], c["duck"], 0], left=0, right=0)
        duck_db = np.maximum(duck_db, env)
music *= (10 ** (-duck_db / 20))[:, None]
mix[: len(music)] += music
for c in cues["sfx"]:
    x = load(c["file"]) * c["volume"]
    if c.get("duration"):
        n = int(c["duration"] * SR)
        x = x[:n].copy()
        f = min(len(x), int(0.08 * SR))
        x[-f:] *= np.linspace(1, 0, f)[:, None]
    i = int(round(c["start"] * SR))
    j = min(N, i + len(x))
    mix[i:j] += x[: j - i]


def lufs(y):
    b1, a1 = [1.53512485958697, -2.69169618940638, 1.19839281085285], [1, -1.69065929318241, 0.73248077421585]
    b2, a2 = [1.0, -2.0, 1.0], [1, -1.99004745483398, 0.99007225036621]
    z = signal.lfilter(b2, a2, signal.lfilter(b1, a1, y, axis=0), axis=0)
    blk, hop = int(0.4 * SR), int(0.1 * SR)
    p = np.array([np.mean(np.sum(z[i:i + blk] ** 2, 1)) for i in range(0, len(z) - blk, hop)])
    p = p[-0.691 + 10 * np.log10(p + 1e-12) > -70]
    rel = -0.691 + 10 * np.log10(np.mean(p)) - 10
    p = p[-0.691 + 10 * np.log10(p) > rel]
    return -0.691 + 10 * np.log10(np.mean(p))


def true_peak(y):
    return 20 * np.log10(np.max(np.abs(signal.resample_poly(y, 4, 1, axis=0))) + 1e-12)


def limit(y, ceiling_db=-3.4, look=0.003, rel=0.1):  # the renderer's meter reads ~2.2 dB hotter than this one
    c = 10 ** (ceiling_db / 20)
    peak = np.max(np.abs(signal.resample_poly(y, 4, 1, axis=0)), 1)
    peak = peak[: (len(peak) // 4) * 4].reshape(-1, 4).max(1)
    peak = np.pad(peak, (0, len(y) - len(peak)), mode="edge")
    env = maximum_filter1d(peak, size=int(look * SR) * 2 + 1)
    g = np.minimum(1.0, c / np.maximum(env, 1e-9))
    a = np.exp(-1 / (rel * SR))
    out = np.empty_like(g)
    prev = 1.0
    for k in range(len(g)):
        prev = g[k] if g[k] < prev else a * prev + (1 - a) * g[k]
        out[k] = prev
    return y * out[:, None]


for c in cues["sfx"]:
    tp = c["start"] + c["peak"]
    i, w = int(tp * SR), int(0.05 * SR)
    x = load(c["file"]) * c["volume"]
    k = int(c["peak"] * SR)
    bed = music[max(0, i - w): i + w]
    hit = x[max(0, k - w): k + w]
    over = 20 * np.log10(np.sqrt(np.mean(hit ** 2)) + 1e-9) - 20 * np.log10(np.sqrt(np.mean(bed ** 2)) + 1e-9)
    print(f"  {c['name']:20s} at {tp:6.2f}s  {over:+5.1f} dB over the bed")
print(f"raw mix: {lufs(mix):.2f} LUFS, {true_peak(mix):.2f} dBTP")
for _ in range(3):
    mix *= 10 ** ((-14.0 - lufs(mix)) / 20)
    mix = limit(mix)
print(f"master:  {lufs(mix):.2f} LUFS, {true_peak(mix):.2f} dBTP")
wavfile.write(os.path.join(ROOT, "assets/audio/mix.wav"), SR, mix.astype(np.float32))
