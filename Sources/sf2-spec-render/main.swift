// SPDX-License-Identifier: AGPL-3.0-or-later
// usage: sf2-spec-render <font.sf2> <bank> <program> <key> <velocity> <holdSec> <tailSec> <out.wav> [effects 0|1]
// Renders one note through SF2Fidelity.spec (strict-or-lenient load) at 44.1 kHz, 16-bit stereo.
import Foundation
import SF2Engine

let a = CommandLine.arguments
guard a.count >= 9 else {
    FileHandle.standardError.write("usage: sf2-spec-render font.sf2 bank program key velocity holdSec tailSec out.wav [effects]\n".data(using: .utf8)!)
    exit(2)
}
let sr = 44100.0
let sf = try SF2SoundFont(data: Data(contentsOf: URL(fileURLWithPath: a[1])), options: .lenient)
let bank = Int(a[2])!, program = Int(a[3])!, key = Int(a[4])!, vel = Int(a[5])!
let hold = Double(a[6])!, tail = Double(a[7])!
guard let idx = sf.resolvePresetIndex(program: program, bank: bank) else { print("no preset \(bank):\(program)"); exit(1) }
let engine = Sf2SynthEngine(outSr: sr, maxVoices: 64)
engine.fidelity = .spec
engine.effectsEnabled = a.count > 9 && a[9] == "1"
engine.setTrackStates([SF2TrackState(trackIndex: 0, regions: try sf.regionList(forPreset: idx, fidelity: .spec))])
let nOn = Int(hold * sr), nOff = Int(tail * sr)
var l = [Float](repeating: 0, count: nOn), r = l
engine.dispatchEvent(.noteOn(key, velocity: vel, trackIndex: 0, channel: 0))
engine.renderRange(&l, &r)
var l2 = [Float](repeating: 0, count: nOff), r2 = l2
engine.dispatchEvent(.noteOff(key, trackIndex: 0, channel: 0))
engine.renderRange(&l2, &r2)
l += l2; r += r2
var d = Data()
func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
let bytes = UInt32(l.count * 4)
d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVEfmt ".utf8))
u32(16); u16(1); u16(2); u32(UInt32(sr)); u32(UInt32(sr) * 4); u16(4); u16(16)
d.append(contentsOf: Array("data".utf8)); u32(bytes)
for i in 0 ..< l.count {
    for x in [l[i], r[i]] { u16(UInt16(bitPattern: Int16(max(-32768, min(32767, (Double(x) * 32767).rounded()))))) }
}
try d.write(to: URL(fileURLWithPath: a[8]))
