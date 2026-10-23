#!/usr/bin/env python3
"""make-midi.py bank program key velocity holdSec tailSec out.mid: one note (CC91/93 = 0), 120 bpm, 480 tpq."""
import struct, sys
bank, prog, key, vel = map(int, sys.argv[1:5]); hold, tail = map(float, sys.argv[5:7]); out = sys.argv[7]
ch = 9 if bank == 128 else 0
def vlq(n):
    b = [n & 0x7F]; n >>= 7
    while n: b.insert(0, (n & 0x7F) | 0x80); n >>= 7
    return bytes(b)
tick = lambda s: int(round(s * 960))  # 120 bpm, 480 tpq -> 960 ticks/s
ev = b""
for cc, v in ((91, 0), (93, 0)): ev += vlq(0) + bytes([0xB0 | ch, cc, v])
if ch != 9: ev += vlq(0) + bytes([0xB0 | ch, 0, bank]) + vlq(0) + bytes([0xC0 | ch, prog])
ev += vlq(0) + bytes([0x90 | ch, key, vel]) + vlq(tick(hold)) + bytes([0x80 | ch, key, 0])
ev += vlq(tick(tail)) + bytes([0xB0 | ch, 121, 0]) + vlq(0) + b"\xFF\x2F\x00"
open(out, "wb").write(b"MThd" + struct.pack(">IHHH", 6, 0, 1, 480) + b"MTrk" + struct.pack(">I", len(ev)) + ev)
