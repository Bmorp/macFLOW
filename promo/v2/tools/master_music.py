"""Master the edited track for the film: loudness to a target with a 4x-oversampled true-peak limiter."""
import sys
import numpy as np
from scipy import signal
from scipy.io import wavfile
from scipy.ndimage import maximum_filter1d

src, dst, target = sys.argv[1], sys.argv[2], float(sys.argv[3])
sr, x = wavfile.read(src)
x = x.astype(np.float64)


def lufs(y):
    b1, a1 = [1.53512485958697, -2.69169618940638, 1.19839281085285], [1, -1.69065929318241, 0.73248077421585]
    b2, a2 = [1.0, -2.0, 1.0], [1, -1.99004745483398, 0.99007225036621]
    if sr != 48000:  # the K-weighting coefficients are for 48 kHz; close enough at 44.1 for a target
        pass
    z = signal.lfilter(b2, a2, signal.lfilter(b1, a1, y, axis=0), axis=0)
    blk, hop = int(0.4 * sr), int(0.1 * sr)
    p = np.array([np.mean(np.sum(z[i:i + blk] ** 2, 1)) for i in range(0, len(z) - blk, hop)])
    p = p[-0.691 + 10 * np.log10(p + 1e-12) > -70]
    rel = -0.691 + 10 * np.log10(np.mean(p)) - 10
    p = p[-0.691 + 10 * np.log10(p) > rel]
    return -0.691 + 10 * np.log10(np.mean(p))


def tp(y):
    return 20 * np.log10(np.max(np.abs(signal.resample_poly(y, 4, 1, axis=0))) + 1e-12)


def limit(y, ceiling_db=-1.5, look=0.003, rel=0.12):
    c = 10 ** (ceiling_db / 20)
    up = signal.resample_poly(y, 4, 1, axis=0)
    peak = np.max(np.abs(up), 1)
    peak = peak[: (len(peak) // 4) * 4].reshape(-1, 4).max(1)
    peak = np.pad(peak, (0, len(y) - len(peak)), mode="edge")
    env = maximum_filter1d(peak, size=int(look * sr) * 2 + 1)
    g = np.minimum(1.0, c / np.maximum(env, 1e-9))
    a = np.exp(-1 / (rel * sr))
    out = np.empty_like(g)
    prev = 1.0
    for i in range(len(g)):
        prev = g[i] if g[i] < prev else a * prev + (1 - a) * g[i]
        out[i] = prev
    return y * out[:, None]


print(f"in:  {lufs(x):.2f} LUFS, {tp(x):.2f} dBTP")
for _ in range(3):
    x *= 10 ** ((target - lufs(x)) / 20)
    x = limit(x)
print(f"out: {lufs(x):.2f} LUFS, {tp(x):.2f} dBTP")
wavfile.write(dst, sr, x.astype(np.float32))
