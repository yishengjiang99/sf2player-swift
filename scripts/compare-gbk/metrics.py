#!/usr/bin/env python3
"""metrics.py name js.f32 swift.f32 sampleRate [wavdir] -> one JSON line of JS-vs-Swift render metrics.
Inputs are interleaved little-endian Float32 stereo (sf2-parity-render / gbk-render.mts output)."""
import json, sys, wave
import numpy as np
from scipy.signal import lfilter

def kweight(x, sr):  # BS.1770-4 K-weighting at any rate (same derivation as gbk src/audio/loudness.ts)
    f0, G, Q = 1681.974450955533, 3.999843853973347, 0.7071752369554196
    K = np.tan(np.pi * f0 / sr); Vh = 10 ** (G / 20); Vb = Vh ** 0.4996667741545416
    a0 = 1 + K / Q + K * K
    b1 = [(Vh + Vb * K / Q + K * K) / a0, 2 * (K * K - Vh) / a0, (Vh - Vb * K / Q + K * K) / a0]
    a1 = [1, 2 * (K * K - 1) / a0, (1 - K / Q + K * K) / a0]
    f0, Q = 38.13547087602444, 0.5003270373238773; K = np.tan(np.pi * f0 / sr); a0 = 1 + K / Q + K * K
    b2 = [1, -2, 1]; a2 = [1, 2 * (K * K - 1) / a0, (1 - K / Q + K * K) / a0]
    return lfilter(b2, a2, lfilter(b1, a1, x, axis=0), axis=0)

def lufs(x, sr):
    y = kweight(x.astype(np.float64), sr)
    sub = int(round(sr * 0.1)); n = len(y) // sub
    if n < 4: return float("-inf")
    e = (y[: n * sub] ** 2).reshape(n, sub, 2).mean(axis=1).sum(axis=1)
    blocks = np.convolve(e, np.ones(4) / 4, "valid")
    L = lambda ms: -0.691 + 10 * np.log10(ms)
    blocks = blocks[blocks > 0]; blocks = blocks[L(blocks) > -70]
    if not len(blocks): return float("-inf")
    rel = L(blocks.mean()) - 10; g = blocks[L(blocks) > rel]
    return float(L(g.mean())) if len(g) else float("-inf")

def db(x): return float(20 * np.log10(x)) if x > 0 else float("-inf")

def tail_end(x, sr):  # last time the signal is within 60 dB of its peak
    a = np.abs(x).max(axis=1); pk = a.max()
    idx = np.nonzero(a > pk * 1e-3)[0]
    return float(idx[-1] / sr) if len(idx) else 0.0

BANDS = [(20, 125), (125, 500), (500, 2000), (2000, 8000), (8000, 20000)]
def band_db(x, sr):
    m = x.mean(axis=1); n = 8192; hop = 4096
    frames = max(1, (len(m) - n) // hop)
    w = np.hanning(n); acc = np.zeros(n // 2 + 1)
    for k in range(frames):
        seg = m[k * hop: k * hop + n]
        if len(seg) < n: break
        acc += np.abs(np.fft.rfft(seg * w)) ** 2
    f = np.fft.rfftfreq(n, 1 / sr)
    return [10 * np.log10(acc[(f >= lo) & (f < hi)].sum() + 1e-30) for lo, hi in BANDS]

def write_wav(path, x, sr):
    w = wave.open(path, "wb"); w.setnchannels(2); w.setsampwidth(2); w.setframerate(sr)
    w.writeframes((np.clip(x, -1, 1) * 32767).astype("<i2").tobytes()); w.close()

name, jsp, swp, sr = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
js = np.fromfile(jsp, "<f4").reshape(-1, 2).astype(np.float64)
sw = np.fromfile(swp, "<f4").reshape(-1, 2).astype(np.float64)
if len(sys.argv) > 5:
    write_wav(f"{sys.argv[5]}/{name}-js.wav", js, sr); write_wav(f"{sys.argv[5]}/{name}-swift.wav", sw, sr)
n = min(len(js), len(sw)); d = js[:n] - sw[:n]
rms_js = np.sqrt((js ** 2).mean()); rms_d = np.sqrt((d ** 2).mean())
corr = float(np.corrcoef(js[:n].ravel(), sw[:n].ravel())[0, 1]) if rms_js > 0 else 0.0
bj, bs = band_db(js, sr), band_db(sw, sr)
out = {
    "song": name, "seconds": round(n / sr, 2), "length_frames_delta": int(len(sw) - len(js)),
    "rms_js_dbfs": round(db(rms_js), 2), "rms_swift_dbfs": round(db(np.sqrt((sw ** 2).mean())), 2),
    "diff_rms_db_rel": round(db(rms_d) - db(rms_js), 2), "diff_peak": float(f"{np.abs(d).max():.3g}"),
    "peak_js": round(float(np.abs(js).max()), 4), "peak_swift": round(float(np.abs(sw).max()), 4),
    "corr": round(corr, 6),
    "band_delta_db": {f"{lo}-{hi}": round(b - a, 2) for (lo, hi), a, b in zip(BANDS, bj, bs)},
    "lufs_js": round(lufs(js, sr), 2), "lufs_swift": round(lufs(sw, sr), 2),
    "tail_end_js_s": round(tail_end(js, sr), 3), "tail_end_swift_s": round(tail_end(sw, sr), 3),
}
out["lufs_delta"] = round(out["lufs_swift"] - out["lufs_js"], 2)
print(json.dumps(out))
