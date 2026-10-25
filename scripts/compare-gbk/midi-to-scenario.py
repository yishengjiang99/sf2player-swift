#!/usr/bin/env python3
"""midi-to-scenario.py song.mid font.sf2 out.json [sampleRate] [tailSec] [maxSec]
Standard MIDI file -> sf2-parity-render scenario: channel events (note on/off, CC, program, bend, pressure)
at sample frames (tempo map honoured), programs: true, effects + master bus on, frames = last event + tail."""
import json, struct, sys

def read_vlq(b, i):
    v = 0
    while True:
        c = b[i]; i += 1; v = (v << 7) | (c & 0x7F)
        if not c & 0x80: return v, i

def parse(path):
    b = open(path, "rb").read()
    assert b[:4] == b"MThd"
    _, ntrk, div = struct.unpack(">HHH", b[8:14])
    i = 8 + struct.unpack(">I", b[4:8])[0]
    evs, tempos = [], [(0, 500000)]
    for _ in range(ntrk):
        while b[i:i + 4] != b"MTrk":
            i += 8 + struct.unpack(">I", b[i + 4:i + 8])[0]
        n = struct.unpack(">I", b[i + 4:i + 8])[0]; j = i + 8; end = j + n; i = end
        t = 0; run = 0
        while j < end:
            d, j = read_vlq(b, j); t += d
            st = b[j]
            if st == 0xFF:
                typ = b[j + 1]; ln, k = read_vlq(b, j + 2); data = b[k:k + ln]; j = k + ln
                if typ == 0x51: tempos.append((t, int.from_bytes(data, "big")))
                if typ == 0x2F: break
                continue
            if st in (0xF0, 0xF7):
                ln, k = read_vlq(b, j + 1); j = k + ln; continue
            if st & 0x80: run = st; j += 1
            hi = run & 0xF0
            nd = 1 if hi in (0xC0, 0xD0) else 2
            data = b[j:j + nd]; j += nd
            evs.append((t, len(evs), run, data))
    tempos.sort()
    return div, evs, tempos

def tick_to_sec(div, tempos):
    def f(t):
        s, lt, tempo = 0.0, 0, 500000
        for tt, tp in tempos:
            if tt > t: break
            s += (tt - lt) * tempo / 1e6 / div; lt, tempo = tt, tp
        return s + (t - lt) * tempo / 1e6 / div
    return f

def main():
    a = sys.argv[1:]
    mid, font, out = a[0], a[1], a[2]
    sr = int(a[3]) if len(a) > 3 else 44100
    tail = float(a[4]) if len(a) > 4 else 3.0
    maxsec = float(a[5]) if len(a) > 5 else 1e9
    div, evs, tempos = parse(mid)
    sec = tick_to_sec(div, tempos)
    events = []
    last = 0
    for t, order, st, d in sorted(evs, key=lambda e: (e[0], e[1])):
        s = sec(t)
        if s > maxsec: continue
        fr = int(round(s * sr)); ch = st & 0x0F; hi = st & 0xF0
        if hi == 0x90 and d[1] > 0: e = {"type": "noteOn", "note": d[0], "velocity": d[1]}
        elif hi == 0x80 or hi == 0x90: e = {"type": "noteOff", "note": d[0]}
        elif hi == 0xB0: e = {"type": "controlChange", "controller": d[0], "value": d[1]}
        elif hi == 0xC0: e = {"type": "programChange", "program": d[0]}
        elif hi == 0xE0: e = {"type": "pitchBend", "velocity": d[0] | (d[1] << 7)}
        elif hi == 0xD0: e = {"type": "channelPressure", "value": d[0]}
        elif hi == 0xA0: e = {"type": "polyPressure", "note": d[0], "value": d[1]}
        else: continue
        e.update(frame=fr, channel=ch, seq=len(events))
        events.append(e); last = max(last, fr)
    if maxsec < 1e9:  # cut: release everything at the cut point
        cut = int(round(maxsec * sr))
        for c in range(16): events.append({"type": "controlChange", "controller": 123, "value": 0, "channel": c, "frame": cut, "seq": len(events)})
        for c in range(16): events.append({"type": "controlChange", "controller": 64, "value": 0, "channel": c, "frame": cut, "seq": len(events)})
        last = cut
    scen = {"font": font, "sampleRate": sr, "frames": last + int(round(tail * sr)), "effects": True, "programs": True,
            "maxVoices": 256, "events": events}
    json.dump(scen, open(out, "w"))
    print(f"{mid}: {len(events)} events, {scen['frames'] / sr:.1f} s")

main()
