"""The Mac Flow score: 120 BPM, F minor resolving to A-flat major, written to the cut (see SPEC.md).

Synthesised from scratch (kick, sub bass, supersaw pads, plucked arp, bell lead, hats, claps, risers, a convolution
reverb) and mastered to about -15 LUFS integrated / -1 dBTP so the film's sound effects sit on top.
Run from the project root:  python3 tools/score.py   ->  assets/audio/score.wav (48 kHz, stereo, float)
"""
import os
import numpy as np
from scipy import signal
from scipy.io import wavfile
from scipy.ndimage import maximum_filter1d

SR = 48000
DUR = 46.5
N = int(DUR * SR)
BEAT = 0.5
rng = np.random.default_rng(23)
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def midi(m):
    return 440.0 * 2 ** ((m - 69) / 12)


def tt(dur):
    return np.arange(int(dur * SR)) / SR


def add(buf, start, x, gain=1.0, pan=0.0):
    """Mix mono or stereo `x` into stereo `buf` at `start` seconds, constant-power pan."""
    i = int(round(start * SR))
    if i >= len(buf):
        return
    if x.ndim == 1:
        l, r = np.cos((pan + 1) * np.pi / 4), np.sin((pan + 1) * np.pi / 4)
        x = np.stack([x * l * 1.4142, x * r * 1.4142], 1)
    j = min(len(buf), i + len(x))
    buf[i:j] += x[: j - i] * gain


def lp(x, fc, q=0.707):
    b, a = signal.iirfilter(2, fc / (SR / 2), btype="low", ftype="butter") if q == 0.707 else _rbj("low", fc, q)
    return signal.lfilter(b, a, x, axis=0)


def hp(x, fc):
    b, a = signal.iirfilter(2, fc / (SR / 2), btype="high", ftype="butter")
    return signal.lfilter(b, a, x, axis=0)


def bp(x, fc, q):
    b, a = _rbj("band", fc, q)
    return signal.lfilter(b, a, x, axis=0)


def _rbj(kind, fc, q):
    w = 2 * np.pi * fc / SR
    al = np.sin(w) / (2 * q)
    c = np.cos(w)
    if kind == "low":
        b = [(1 - c) / 2, 1 - c, (1 - c) / 2]
    else:
        b = [al, 0, -al]
    a = [1 + al, -2 * c, 1 - al]
    return np.array(b) / a[0], np.array(a) / a[0]


def sweep_lp(x, fc_curve, q=0.9, block=256):
    """A resonant low-pass whose cutoff follows `fc_curve` (Hz per sample), block by block with carried state."""
    y = np.zeros_like(x)
    zi = None
    for s in range(0, len(x), block):
        fc = float(np.clip(fc_curve[min(s, len(fc_curve) - 1)], 30, SR * 0.45))
        b, a = _rbj("low", fc, q)
        if zi is None:
            zi = np.zeros((2,) + x.shape[1:])
        seg, zi = signal.lfilter(b, a, x[s:s + block], axis=0, zi=zi)
        y[s:s + block] = seg
    return y


def saw(f, t, phase=0.0):
    # band-limited-ish: naive saw smoothed by a gentle low-pass afterwards
    return 2 * ((f * t + phase) % 1.0) - 1


def adsr(n, a, d, s, r, hold):
    t = np.arange(n) / SR
    env = np.where(t < a, t / max(a, 1e-4), s + (1 - s) * np.exp(-(t - a) / max(d, 1e-4)))
    rel = np.clip((t - hold) / max(r, 1e-4), 0, None)
    return env * np.exp(-rel * 4) * (t < hold + r * 1.5)


# ---------------------------------------------------------------- instruments

def kick(vel=1.0, tone=1.0):
    t = tt(0.55)
    f = 52 + 120 * np.exp(-t / 0.026) * tone
    ph = 2 * np.pi * np.cumsum(f) / SR
    body = np.sin(ph) * np.exp(-t / 0.2) * np.minimum(1, t / 0.0015)
    knock = np.sin(2 * np.pi * np.cumsum(150 * np.exp(-t / 0.05) + 80) / SR) * np.exp(-t / 0.045) * 0.35
    click = hp(rng.normal(0, 1, len(t)), 2500) * np.exp(-t / 0.004) * 0.45
    return np.tanh((body + knock + click) * 1.6) * vel


def boom(dur=2.4, f0=58, f1=30, vel=1.0):
    t = tt(dur)
    f = f1 + (f0 - f1) * np.exp(-t / 0.35)
    x = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.9) * np.minimum(1, t / 0.004)
    return np.tanh(x * 1.3) * vel


def hat(open_=False, vel=1.0):
    t = tt(0.35 if open_ else 0.08)
    x = hp(rng.normal(0, 1, len(t)), 7500) * np.exp(-t / (0.11 if open_ else 0.022))
    return x * vel


def clap(vel=1.0):
    t = tt(0.4)
    n = rng.normal(0, 1, len(t))
    env = np.zeros(len(t))
    for k, o in enumerate([0, 0.011, 0.022]):
        env += (t >= o) * np.exp(-np.clip(t - o, 0, None) / (0.006 if k < 2 else 0.12))
    return bp(n * env, 1400, 0.9) * vel * 1.6


def crash(vel=1.0, dur=2.8):
    t = tt(dur)
    x = hp(rng.normal(0, 1, (len(t), 2)), 5000) * np.exp(-t / 0.9)[:, None]
    return x * vel


def snare(vel=1.0):
    t = tt(0.25)
    tone = np.sin(2 * np.pi * 190 * t) * np.exp(-t / 0.05)
    nz = bp(rng.normal(0, 1, len(t)), 3000, 0.7) * np.exp(-t / 0.07)
    return (tone * 0.5 + nz) * vel


def supersaw(freqs, dur, voices=7, detune=0.13):
    t = tt(dur)
    out = np.zeros((len(t), 2))
    for f in freqs:
        for v in range(voices):
            d = (v - (voices - 1) / 2) / ((voices - 1) / 2)
            fv = f * 2 ** (d * detune / 12)
            x = saw(fv, t, rng.random())
            pan = d * 0.8
            out[:, 0] += x * np.cos((pan + 1) * np.pi / 4)
            out[:, 1] += x * np.sin((pan + 1) * np.pi / 4)
    return out / (len(freqs) * voices) * 2.2


_pluck_cache = {}


def pluck(f, vel=1.0, decay=0.22, bright=1.0):
    key = (round(f, 3), decay, bright)
    if key not in _pluck_cache:
        _pluck_cache[key] = _pluck(f, decay, bright)
    return _pluck_cache[key] * vel


def _pluck(f, decay, bright):
    vel = 1.0
    t = tt(0.6)
    x = 0.65 * saw(f, t) + 0.35 * np.sign(np.sin(2 * np.pi * f * t))
    fc = 650 + 5200 * bright * np.exp(-t / 0.06)
    y = sweep_lp(x[:, None], fc, q=1.1, block=128)[:, 0]
    return y * np.exp(-t / decay) * np.minimum(1, t / 0.002) * vel


def bell(f, vel=1.0, dur=1.6):
    t = tt(dur)
    idx = 2.2 * np.exp(-t / 0.25)
    x = np.sin(2 * np.pi * f * t + idx * np.sin(2 * np.pi * f * 3.5 * t))
    x += 0.35 * np.sin(2 * np.pi * f * 2 * t) * np.exp(-t / 0.4)
    return x * np.exp(-t / 0.75) * np.minimum(1, t / 0.003) * vel


def sub(f, dur, vel=1.0):
    t = tt(dur)
    x = np.sin(2 * np.pi * f * t) + 0.18 * np.sin(4 * np.pi * f * t)
    env = np.minimum(1, t / 0.004) * np.minimum(1, (dur - t) / 0.01)
    grit = lp(0.5 * saw(f, t) + 0.5 * saw(f * 1.004, t, 0.3), 900) * np.exp(-t / 0.18)
    return (np.tanh(x * env * 1.2) * 0.75 + grit * env * 0.45) * vel


def riser(dur, f0=300, f1=9000, vel=1.0):
    t = tt(dur)
    n = rng.normal(0, 1, (len(t), 2))
    fc = f0 * (f1 / f0) ** (t / dur)
    out = np.zeros_like(n)
    for s in range(0, len(t), 512):
        b, a = _rbj("band", float(fc[s]), 1.4)
        out[s:s + 512] = signal.lfilter(b, a, n[s:s + 512], axis=0)
    ph = np.cumsum(midi(53) * 2 ** (2 * t / dur)) / SR
    tone = (2 * (ph % 1) - 1) * 0.25
    tone = lp(tone, 3000)
    amp = (t / dur) ** 2.2
    return (out * 2.2 + tone[:, None]) * amp[:, None] * vel


# ---------------------------------------------------------------- the arrangement

drums = np.zeros((N, 2))
bass = np.zeros((N, 2))
pads = np.zeros((N, 2))
arp = np.zeros((N, 2))
lead = np.zeros((N, 2))
fx = np.zeros((N, 2))
kicks = []  # times, for the sidechain

F, Ab, C, Db, Eb, G, Bb = 41, 44, 48, 49, 51, 55, 46  # bass-octave MIDI roots
CHORD = {  # pad voicings (MIDI) and arp tones
    "Fm": ([53, 56, 60, 65], [65, 68, 72, 77]),
    "Db": ([49, 53, 56, 61], [61, 65, 68, 73]),
    "Ab": ([56, 60, 63, 68], [68, 72, 75, 80]),
    "Eb": ([51, 55, 58, 63], [63, 67, 70, 75]),
    "Abadd9": ([56, 60, 63, 70], [68, 72, 75, 82]),
}
ROOTS = {"Fm": F, "Db": Db, "Ab": Ab, "Eb": Eb, "Abadd9": Ab}
# one chord per bar (2 s); bar 0 starts at 0.0
BARS = ["Fm", "Fm", "Db",                      # intro
        "Fm", "Db", "Ab", "Eb", "Fm", "Db", "Ab", "Eb", "Fm", "Db", "Ab", "Eb",   # 6-30
        "Fm", "Db", "Ab", "Eb",                    # montage and Home, 30-38
        "Db", "Eb",                                # claim, then V into the resolution
        "Abadd9", "Abadd9", "Abadd9"]


def chord_at(t):
    return BARS[min(int(t // 2), len(BARS) - 1)]


def K(t, vel=1.0, tone=1.0):
    add(drums, t, kick(vel, tone), 0.9)
    kicks.append(t)


# Intro (0-6): a low boom under the first frame, a ticking pulse, a heartbeat, the riser, then a breath.
add(fx, 0.0, boom(2.6, 62, 32, 0.55), 1.0)
for k in range(int(5.85 / 0.25)):
    t = k * 0.25
    v = 0.10 + 0.18 * (t / 5.85)
    add(drums, t, hat(False, v * (1.0 if k % 2 == 0 else 0.6)), 1.0, pan=0.25 if k % 2 else -0.15)
for t in [2.0, 3.0, 4.0, 4.5, 5.0, 5.25, 5.5, 5.625, 5.75]:
    K(t, 0.38 + 0.2 * (t - 2) / 4, 0.7)
add(fx, 4.0, riser(1.85, 250, 9000, 0.32), 1.0)

# Grooves
def groove(t0, t1, hats16=True, clap_on=True, kick_on=True, open_hats=True, vel=1.0):
    t = t0
    while t < t1 - 1e-6:
        b = round(t / BEAT)
        if kick_on:
            K(t, 0.95 * vel)
        if clap_on and b % 2 == 1:
            add(drums, t, clap(0.55 * vel), 1.0, pan=0.0)
        for s in range(4 if hats16 else 2):
            ts = t + s * (BEAT / (4 if hats16 else 2))
            if ts >= t1:
                break
            accent = 1.0 if (s == 2 and hats16) or (not hats16 and s == 1) else 0.55
            add(drums, ts, hat(False, 0.22 * accent * vel), 1.0, pan=0.3 if s % 2 else -0.2)
        if open_hats:
            add(drums, t + BEAT / 2, hat(True, 0.12 * vel), 1.0, pan=0.35)
        t += BEAT


def bassline(t0, t1, octave_jump=False, vel=1.0):
    t = t0
    k = 0
    while t < t1 - 1e-6:
        r = ROOTS[chord_at(t)]
        m = r + (12 if (octave_jump and k % 2 == 1) else 0)
        add(bass, t, sub(midi(m), BEAT / 2 * 0.92, 0.55 * vel), 1.0)
        t += BEAT / 2
        k += 1


def pad_section(t0, t1, cutoff0, cutoff1, vel=1.0):
    t = t0
    while t < t1 - 1e-6:
        bar_end = min(t1, (t // 2 + 1) * 2)
        voicing = CHORD[chord_at(t)][0]
        dur = bar_end - t + 0.6
        x = supersaw([midi(m) for m in voicing], dur)
        env = adsr(len(x), 0.08, 0.6, 0.85, 0.5, bar_end - t)[:, None]
        fc = np.linspace(cutoff0, cutoff1, len(x)) if True else None
        x = sweep_lp(x * env, fc, q=0.8)
        add(pads, t, x, 0.55 * vel)
        t = bar_end


def arp_section(t0, t1, vel=1.0, bright=1.0, step=0.125):
    pattern = [0, 2, 1, 3, 2, 1, 0, 2]
    t = t0
    k = int(round(t0 / step))
    while t < t1 - 1e-6:
        tones = CHORD[chord_at(t)][1]
        m = tones[pattern[k % len(pattern)]]
        acc = 1.0 if k % 4 == 0 else 0.7
        add(arp, t, pluck(midi(m), 0.30 * vel * acc, 0.18, bright), 1.0, pan=(0.35 if k % 2 else -0.35))
        t += step
        k += 1


# 6.0 DROP — the notch wakes.
add(fx, 6.0, boom(2.4, 70, 30, 0.95), 1.0)
add(fx, 6.0, crash(0.16), 1.0)
groove(6.0, 16.0)
bassline(6.0, 16.0)
pad_section(0.0, 5.85, 380, 700, 0.55)
pad_section(6.0, 16.0, 1800, 3200)
arp_section(6.5, 16.0, 0.9, 0.8)
add(fx, 8.0, crash(0.12), 1.0)
add(fx, 14.0, crash(0.07, 1.6), 1.0)
for m in CHORD[chord_at(14.0)][1][:3]:
    add(lead, 14.0, pluck(midi(m), 0.22, 0.35, 1.0), 1.0)

# 16.0 Flow — a breakdown, the kick returns as Flow acts.
groove(16.0, 18.0, hats16=False, clap_on=False, kick_on=False, open_hats=False, vel=0.8)
pad_section(16.0, 20.0, 1100, 2400, 0.9)
arp_section(16.0, 20.0, 0.7, 0.55)
for t in [18.0, 19.0, 19.5]:
    K(t, 0.8)
bassline(18.0, 20.0, vel=0.7)
groove(18.0, 20.0, hats16=True, clap_on=False, kick_on=False, open_hats=False, vel=0.7)
# 20.0 the split, full again
groove(20.0, 28.0)
bassline(20.0, 28.0)
pad_section(20.0, 28.0, 2000, 3600)
arp_section(20.0, 28.0, 1.0, 0.9)
add(fx, 22.5, crash(0.12), 1.0)
add(fx, 26.0, crash(0.06, 1.2), 1.0)

# 28.0 Drop: the build into the montage.
pad_section(28.0, 29.9, 1600, 5200)
arp_section(28.0, 29.9, 1.0, 1.0, step=0.0625)
bassline(28.0, 29.9)
for k in range(8):
    K(28.0 + k * 0.25, 0.75 + 0.03 * k)
for k in range(15):
    add(drums, 28.0 + k * 0.125, snare(0.10 + 0.25 * k / 15), 1.0)
for k in range(15):
    add(drums, 29.0 + k * 0.0625, snare(0.25 + 0.3 * k / 15), 1.0)
add(fx, 28.5, riser(1.4, 400, 10000, 0.22), 1.0)

# 30.0 Montage: everything, 8th-note bass jumps.
add(fx, 30.0, boom(1.6, 80, 34, 0.7), 1.0)
add(fx, 30.0, crash(0.18), 1.0)
groove(30.0, 36.5, vel=1.05)
bassline(30.0, 36.5, octave_jump=True, vel=1.05)
pad_section(30.0, 36.5, 3200, 4200, 1.05)
arp_section(30.0, 36.5, 1.05, 1.0)
for t in [31.75, 33.75, 35.75]:
    K(t, 0.6)
# 33.0 Home opens — the lead hook.
add(fx, 33.0, crash(0.16), 1.0)
for t, m in [(33.0, 72), (33.5, 75), (34.0, 77), (34.5, 75), (35.0, 72), (35.5, 68), (36.0, 70)]:
    add(lead, t, bell(midi(m), 0.30), 1.0, pan=0.1)
    add(lead, t, bell(midi(m + 12), 0.08), 1.0, pan=-0.2)

# 36.5 Claim: a breakdown, warm and open.
pad_section(36.5, 40.0, 1200, 2600, 0.95)
arp_section(37.0, 40.0, 0.55, 0.5, step=0.25)
for t in [38.0, 39.0]:
    K(t, 0.55, 0.8)
add(bass, 38.0, sub(midi(Db), 1.9, 0.4), 1.0)

# 40.0 End: riser and roll, a breath, then the final hit on the star.
add(fx, 40.0, riser(1.88, 300, 11000, 0.36), 1.0)
for k in range(8):
    K(40.0 + k * 0.25, 0.5 + 0.05 * k)
for k in range(15):
    add(drums, 40.0 + k * 0.125, snare(0.08 + 0.3 * (k / 15) ** 2), 1.0)
add(bass, 40.0, sub(midi(Eb), 1.85, 0.45), 1.0)
pad_section(40.0, 41.88, 900, 4800, 0.9)
# 42.0
add(fx, 42.0, boom(3.5, 72, 28, 1.0), 1.0)
add(fx, 42.0, crash(0.22, 4.0), 1.0)
K(42.0, 1.0)
stab = supersaw([midi(m) for m in CHORD["Abadd9"][0] + [44, 32 + 24]], 4.5)
stab *= adsr(len(stab), 0.005, 0.9, 0.35, 1.5, 3.0)[:, None]
add(pads, 42.0, sweep_lp(stab, np.linspace(6000, 1400, len(stab)), q=0.8), 1.0)
for k, m in enumerate([68, 72, 75, 80, 82, 87]):
    add(lead, 42.0 + k * 0.125, bell(midi(m), 0.14 * (1 - k * 0.1), 2.4), 1.0, pan=(-0.3 + 0.12 * k))
add(bass, 42.0, sub(midi(32), 3.0, 0.55) * np.exp(-tt(3.0) / 1.2), 1.0)

# ---------------------------------------------------------------- mix

def sidechain(x, depth=0.8, rel=0.14):
    g = np.ones(N)
    for t in kicks:
        i = int(t * SR)
        j = min(N, i + int(0.45 * SR))
        u = np.arange(j - i) / SR
        g[i:j] = np.minimum(g[i:j], 1 - depth * np.exp(-u / rel))
    return x * g[:, None]


def reverb_ir(seconds=2.4, predelay=0.018):
    n = int(seconds * SR)
    t = np.arange(n) / SR
    ir = rng.normal(0, 1, (n, 2)) * np.exp(-t / (seconds / 6.9))[:, None]
    ir = lp(ir, 6500)
    ir[: int(predelay * SR)] = 0
    return ir / np.sqrt(np.sum(ir ** 2, 0, keepdims=True))


def convolve(x, ir):
    return np.stack([signal.fftconvolve(x[:, c], ir[:, c])[:N] for c in range(2)], 1)


def delay(x, secs, fb=0.35, mix=0.3):
    d = int(secs * SR)
    y = x.copy()
    tap = x.copy()
    for k in range(1, 5):
        tap = np.roll(tap, d, axis=0)
        tap[:d] = 0
        tap = tap[:, ::-1] * fb  # ping-pong
        y += tap
    return x * (1 - mix) + y * mix


bass = sidechain(bass, 0.85, 0.12)
pads = sidechain(pads, 0.5, 0.18)
arp = sidechain(delay(arp, 0.375, 0.42, 0.35), 0.35, 0.16)
ir = reverb_ir(2.6)
wet = convolve(pads * 0.35 + arp * 0.45 + lead * 0.5 + drums * 0.08 + fx * 0.12, ir)
mix = drums * 0.95 + bass * 0.8 + pads * 1.15 + arp * 1.1 + lead * 1.25 + fx * 0.6 + wet * 0.65
# the arc: each section a little bigger than the last, breakdowns that breathe
arc = np.interp(np.arange(N) / SR,
                [0, 5.9, 6.0, 16.0, 18.0, 18.01, 28.0, 29.9, 30.0, 36.4, 36.6, 39.9, 40.0, 41.85, 42.0, DUR],
                [1.0, 1.0, 0.72, 0.72, 0.72, 0.8, 0.8, 0.95, 1.0, 1.0, 0.62, 0.62, 0.66, 0.95, 1.15, 1.15])
mix *= arc[:, None]
# the breath before the drop and before the montage and the final hit: hard gates
for a, b in [(5.85, 6.0), (41.88, 42.0)]:
    i, j = int(a * SR), int(b * SR)
    ramp = int(0.01 * SR)
    mix[i:i + ramp] *= np.linspace(1, 0, ramp)[:, None]
    mix[i + ramp:j] = 0
mix = hp(mix, 28)
mix = mix - 0.3 * lp(mix, 55)  # about -3 dB under 55 Hz: the low end has to survive laptop and phone speakers
# glue: slow RMS compressor
rms = np.sqrt(signal.lfilter([1 - np.exp(-1 / (0.05 * SR))], [1, -np.exp(-1 / (0.05 * SR))], np.mean(mix ** 2, 1)) + 1e-12)
thr = 10 ** (-9 / 20)
gain = np.where(rms > thr, (rms / thr) ** (1 / 1.8 - 1), 1.0)
mix *= gain[:, None]
mix = np.tanh(mix * 1.15) / 1.15
# tail fade
fade = int(1.4 * SR)
mix[-fade:] *= np.linspace(1, 0, fade)[:, None] ** 1.5


def lufs(x):
    b1, a1 = [1.53512485958697, -2.69169618940638, 1.19839281085285], [1, -1.69065929318241, 0.73248077421585]
    b2, a2 = [1.0, -2.0, 1.0], [1, -1.99004745483398, 0.99007225036621]
    y = signal.lfilter(b2, a2, signal.lfilter(b1, a1, x, axis=0), axis=0)
    blk, hop = int(0.4 * SR), int(0.1 * SR)
    z = np.array([np.mean(np.sum(y[i:i + blk] ** 2, 1)) for i in range(0, len(y) - blk, hop)])
    lk = -0.691 + 10 * np.log10(z + 1e-12)
    z = z[lk > -70]
    rel = -0.691 + 10 * np.log10(np.mean(z)) - 10
    z = z[(-0.691 + 10 * np.log10(z)) > rel]
    return -0.691 + 10 * np.log10(np.mean(z))


def limit(x, ceiling_db=-1.2, look=0.004, rel=0.08):
    c = 10 ** (ceiling_db / 20)
    up = signal.resample_poly(x, 4, 1, axis=0)
    peak = np.max(np.abs(up), 1).reshape(-1, 4).max(1)[: len(x)]
    env = maximum_filter1d(peak, size=int(look * SR) * 2 + 1)
    g = np.minimum(1.0, c / np.maximum(env, 1e-9))
    a = np.exp(-1 / (rel * SR))
    out = np.empty_like(g)
    prev = 1.0
    for i in range(len(g)):  # instant attack, smooth release
        prev = g[i] if g[i] < prev else a * prev + (1 - a) * g[i]
        out[i] = prev
    return x * out[:, None]


target = -15.0
for _ in range(3):
    mix *= 10 ** ((target - lufs(mix)) / 20)
    mix = limit(mix)
tp = 20 * np.log10(np.max(np.abs(signal.resample_poly(mix, 4, 1, axis=0))))
print(f"integrated {lufs(mix):.2f} LUFS, true peak {tp:.2f} dBTP")
os.makedirs(os.path.join(ROOT, "assets/audio"), exist_ok=True)
wavfile.write(os.path.join(ROOT, "assets/audio/score.wav"), SR, mix.astype(np.float32))
