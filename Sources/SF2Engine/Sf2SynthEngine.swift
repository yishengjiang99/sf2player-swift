// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

// Port of gbk src/sf2-renderer.ts `Sf2SynthEngine` (+ makeVoice, regionBaseRate, readSampleMono,
// balanceToGains). Voice order, polyphony stealing, choke groups, per-track state and the
// per-sample math follow the TS line by line. Storage is preallocated and pointer-based so
// `dispatch(_: EngineEvent)`, `renderRange` and `renderScheduled` are real-time safe: no
// allocation, locks, ARC or exclusivity checks.

/// Synth event (gbk `SynthEvent`). `regions` is used by `.setPreset`.
public struct SF2SynthEvent: @unchecked Sendable {
    /// `.controlChange`: `note` = controller number, `velocity` = value (MIDI channel `channel`).
    /// `.pitchBend`: `velocity` = 14-bit value 0...16383 (8192 = center). Both apply only in `.spec`.
    /// `.programChange`: `note` = program (bank from the channel's CC0, channel 10 = bank 128; needs
    /// `loadPrograms(from:)`). `.channelPressure`: `velocity` = value. `.polyPressure`: `note`, `velocity` = value.
    public enum Kind: UInt8, Sendable {
        case noteOn, noteOff, setPreset, setControllers, controlChange, pitchBend, programChange, channelPressure, polyPressure
    }
    public var kind: Kind
    public var frame: Int?
    public var seq: Int = 0
    public var trackIndex: Int?
    public var channel: Int?
    public var note: Int = 0
    public var velocity: Int = 0
    public var regions: SF2RegionList?
    public var cc7Volume: Double?
    public var cc10Pan: Double?
    public var cc11Expression: Double?
    public var pan: Double?
    public var gain: Double?
    /// Informational (sequence builder): preset index behind `regions`.
    public var presetIndex: Int?

    public init(kind: Kind, frame: Int? = nil, seq: Int = 0, trackIndex: Int? = nil, channel: Int? = nil, note: Int = 0,
                velocity: Int = 0, regions: SF2RegionList? = nil, cc7Volume: Double? = nil, cc10Pan: Double? = nil,
                cc11Expression: Double? = nil, pan: Double? = nil, gain: Double? = nil, presetIndex: Int? = nil) {
        self.kind = kind; self.frame = frame; self.seq = seq; self.trackIndex = trackIndex; self.channel = channel
        self.note = note; self.velocity = velocity; self.regions = regions; self.cc7Volume = cc7Volume
        self.cc10Pan = cc10Pan; self.cc11Expression = cc11Expression; self.pan = pan; self.gain = gain
        self.presetIndex = presetIndex
    }

    public static func noteOn(_ note: Int, velocity: Int, frame: Int? = nil, seq: Int = 0, trackIndex: Int? = nil, channel: Int? = nil) -> Self {
        Self(kind: .noteOn, frame: frame, seq: seq, trackIndex: trackIndex, channel: channel, note: note, velocity: velocity)
    }
    public static func noteOff(_ note: Int, frame: Int? = nil, seq: Int = 0, trackIndex: Int? = nil, channel: Int? = nil) -> Self {
        Self(kind: .noteOff, frame: frame, seq: seq, trackIndex: trackIndex, channel: channel, note: note)
    }
    public static func setPreset(_ regions: SF2RegionList?, frame: Int? = nil, seq: Int = 0, trackIndex: Int? = nil) -> Self {
        Self(kind: .setPreset, frame: frame, seq: seq, trackIndex: trackIndex, regions: regions)
    }
    public static func controlChange(_ controller: Int, value: Int, frame: Int? = nil, seq: Int = 0, trackIndex: Int? = nil,
                                     channel: Int) -> Self {
        Self(kind: .controlChange, frame: frame, seq: seq, trackIndex: trackIndex, channel: channel, note: controller, velocity: value)
    }
    /// `value`: 14-bit 0...16383, 8192 = no bend.
    public static func pitchBend(_ value: Int, frame: Int? = nil, seq: Int = 0, trackIndex: Int? = nil, channel: Int) -> Self {
        Self(kind: .pitchBend, frame: frame, seq: seq, trackIndex: trackIndex, channel: channel, velocity: value)
    }
    public static func programChange(_ program: Int, frame: Int? = nil, seq: Int = 0, trackIndex: Int? = nil, channel: Int) -> Self {
        Self(kind: .programChange, frame: frame, seq: seq, trackIndex: trackIndex, channel: channel, note: program)
    }
    public static func channelPressure(_ value: Int, frame: Int? = nil, seq: Int = 0, trackIndex: Int? = nil, channel: Int) -> Self {
        Self(kind: .channelPressure, frame: frame, seq: seq, trackIndex: trackIndex, channel: channel, velocity: value)
    }
    public static func polyPressure(note: Int, value: Int, frame: Int? = nil, seq: Int = 0, trackIndex: Int? = nil, channel: Int) -> Self {
        Self(kind: .polyPressure, frame: frame, seq: seq, trackIndex: trackIndex, channel: channel, note: note, velocity: value)
    }
    public static func setControllers(trackIndex: Int? = nil, cc7Volume: Double? = nil, cc10Pan: Double? = nil, cc11Expression: Double? = nil,
                                      pan: Double? = nil, gain: Double? = nil) -> Self {
        Self(kind: .setControllers, trackIndex: trackIndex, cc7Volume: cc7Volume, cc10Pan: cc10Pan, cc11Expression: cc11Expression, pan: pan, gain: gain)
    }
}

/// gbk `TrackState` input for `setTrackStates`.
public struct SF2TrackState: @unchecked Sendable {
    public var trackIndex: Int
    public var regions: SF2RegionList?
    public var cc7Volume: Double?
    public var cc10Pan: Double?
    public var cc11Expression: Double?
    public var pan: Double?
    public var gain: Double?
    public init(trackIndex: Int, regions: SF2RegionList? = nil, cc7Volume: Double? = nil, cc10Pan: Double? = nil,
                cc11Expression: Double? = nil, pan: Double? = nil, gain: Double? = nil) {
        self.trackIndex = trackIndex; self.regions = regions; self.cc7Volume = cc7Volume; self.cc10Pan = cc10Pan
        self.cc11Expression = cc11Expression; self.pan = pan; self.gain = gain
    }
}

/// Snapshot of an internal track state (gbk `InternalTrackState`).
public struct SF2TrackSnapshot: Equatable, Sendable {
    public var regionCount: Int
    public var cc7Volume: Double, cc10Pan: Double, cc11Expression: Double, pan: Double, gain: Double
}

public struct SF2VoiceSnapshot: Equatable, Sendable {
    public var note: Int, velocity: Int, channel: Int, trackIndex: Int?
    public var volEnvStage: EnvStage
    public var volEnvLevel: Double
    public var baseGain: Double
}

/// POD event for the real-time path. -1 encodes "absent" for track/channel/list, NaN for CCs.
public struct EngineEvent {
    public var kind: UInt8
    public var frame: Int
    public var seq: Int
    public var trackIndex: Int32
    public var channel: Int32
    public var note: Int32
    public var velocity: Int32
    public var list: Int32
    public var cc7: Double, cc10: Double, cc11: Double, pan: Double, gain: Double

    public init(kind: UInt8, frame: Int, seq: Int, trackIndex: Int32, channel: Int32, note: Int32, velocity: Int32, list: Int32,
                cc7: Double, cc10: Double, cc11: Double, pan: Double, gain: Double) {
        self.kind = kind; self.frame = frame; self.seq = seq; self.trackIndex = trackIndex; self.channel = channel
        self.note = note; self.velocity = velocity; self.list = list
        self.cc7 = cc7; self.cc10 = cc10; self.cc11 = cc11; self.pan = pan; self.gain = gain
    }
}

/// POD per-track state for the real-time path.
public struct TrackRT {
    public var present = false
    public var list: Int32 = -1
    public var cc7 = 100.0, cc10 = 64.0, cc11 = 127.0, pan = 0.0, gain = 1.0
    /// `.spec`: the track's CC7/CC10/CC11 override the channel controller state of every channel it plays
    /// on (`chanMask`), so they act through the 2.01 default modulators. Set for non-default initial values
    /// (power-on defaults are already the channel state) and by any track `.setControllers` CC.
    public var ccSet = false
    public var chanMask: UInt16 = 0
    public init() {}
    /// Whether the CCs differ from the MIDI power-on defaults (100 / 64 / 127).
    public var hasNonDefaultCcs: Bool { cc7 != 100 || cc10 != 64 || cc11 != 127 }
}

/// MIDI channel state (`.spec`): controllers, pitch wheel, RPN 0 bend range, channel preset.
struct ChannelRT {
    var bend: Int32 = 8192
    var pws = 2.0
    var rpnMsb: UInt8 = 127, rpnLsb: UInt8 = 127
    var pressure: Int32 = 0
    var list: Int32 = -1
    var program: Int32 = 0
    /// MIDI-08: whether the most recent parameter select was NRPN (CC99/98) rather than RPN (CC101/100).
    var paramIsNRPN = false
    /// N-01...N-03: SoundFont NRPN mode (CC99 = 120), selected generator (-1 none), LSB accumulator.
    var nrpnActive = false
    var nrpnSelect: Int32 = -1
    var nrpnAccum: Int32 = 0
    var sostenuto = false
}

struct Voice {
    var note: Int32 = 0, channel: Int32 = 0, trackIndex: Int32 = -1, velocity: Int32 = 0
    var pos = 0.0, baseRate = 1.0, rate = 1.0
    var start = 0.0, end = 0.0, loopStart = 0.0, loopEnd = 0.0
    var looping = false, loopUntilReleaseThenTail = false, inReleaseTail = false, finished = false
    var dataL: UnsafePointer<Float>?, lenL = 0
    var dataR: UnsafePointer<Float>?, lenR = 0
    var baseGain = 0.0, regionPanPos = 0.0, trackPanPos = 0.0, trackVolumeMul = 1.0
    var volEnv: VolEnv, modEnv: ModEnv, modLfo: LFO, vibLfo: LFO, lpf: TwoPoleLPF
    var exclusiveClass = 0
    var vibToPitch = 0.0, modToPitch = 0.0, initialFc = 13500.0, modEnvToFc = 0.0, modLfoToFc = 0.0
    var lastFc = Double.nan
    var lastMixPan = Double.nan, gL = 0.0, gR = 0.0
    // .spec: modulator list and the region's unmodulated values.
    var spec = false
    var mods: UnsafePointer<SF2Modulator>?, modCount = 0
    var regAtten = 0.0, regPan = 0.0, regFc = 13500.0, regQ = 0.0, regVib = 0.0, regModPitch = 0.0
    var regModEnvPitch = 0.0, regModLfoFc = 0.0, regModEnvFc = 0.0, regModLfoVol = 0.0
    var baseRate0 = 1.0, trackGain = 1.0
    var modEnvToPitch = 0.0, modLfoToVol = 0.0
    // .spec channel functions: key held, deferred by sustain / sostenuto, region list (exclusive scope),
    // effective key / velocity (G-02).
    var keyDown = true, deferred = false, sostenuto = false
    var list: Int32 = -1
    var effKey: Int32 = 0, effVel: Int32 = 0
    /// G-11: send amounts (0 ... 1) and the region values they are modulated from.
    var chorusAmt = 0.0, reverbAmt = 0.0, regChorus = 0.0, regReverb = 0.0
    /// G-08: resonance in cB and whether the filter is out of circuit (Fc >= 20 kHz / 0.45 sr with Q <= 0).
    var qCb = 0.0

    init(sr: Double) {
        volEnv = VolEnv(sr: sr); modEnv = ModEnv(sr: sr); modLfo = LFO(sr: sr); vibLfo = LFO(sr: sr); lpf = TwoPoleLPF(sr: sr)
    }
}

@inline(__always) private func readSampleMono(_ data: UnsafePointer<Float>, _ len: Int, _ pos: Double) -> Double {
    // Non-finite / absurd positions (pathological tuning in fuzzed files) read silence instead of trapping.
    guard pos.isFinite, abs(pos) < 9e15 else { return 0 }
    let i = Int(pos)
    let f = pos - Double(i)
    let a = i >= 0 && i < len ? Double(data[i]) : 0
    let b = i + 1 >= 0 && i + 1 < len ? Double(data[i + 1]) : 0
    return a + (b - a) * f
}

public final class Sf2SynthEngine: @unchecked Sendable {
    public static let maxTracks = 256

    struct State {
        var maxVoices: Int
        var capacity: Int
        var count = 0
        var cc7 = 100.0, cc10 = 64.0, cc11 = 127.0
        var globalList: Int32 = -1
        var voices: UnsafeMutablePointer<Voice>
        var order: UnsafeMutablePointer<Int32>
        var free: UnsafeMutablePointer<Int32>
        var freeCount: Int
        var tracks: UnsafeMutablePointer<TrackRT>
        var store: UnsafeMutablePointer<SF2RegionStore.Header>
        var spec = true
        var chans: UnsafeMutablePointer<ChannelRT>
        /// 16 x 128 controller values.
        var ccs: UnsafeMutablePointer<UInt8>
        /// 16 x 64 NRPN generator offsets (N-04), 16 x 128 poly pressure, 129 x 128 program -> list id.
        var nrpn: UnsafeMutablePointer<Double>
        var poly: UnsafeMutablePointer<UInt8>
        var programs: UnsafeMutablePointer<Int32>
        /// G-11: per-frame send-bus sums and the built-in effects.
        var revL = 0.0, revR = 0.0, choL = 0.0, choR = 0.0
        var fx: SF2EffectsRT
        var fxOn = true
        /// Master bus (non-normative), applied in renderRange / renderScheduled for every fidelity.
        var master: MasterBusRT
        var masterOn = true
        var masterGainDb = -3.0
        var masterGain = pow(10, -3.0 / 20)
    }

    public let outSr: Double
    let st: UnsafeMutablePointer<State>
    /// Owns the region lists referenced by events. Swap only while not rendering.
    public private(set) var regionStore: SF2RegionStore

    /// - Parameter voiceCapacity: preallocated voice pool (>= maxVoices). The real-time player
    ///   preallocates a large pool so a new sequence's maxVoices never needs a reallocation.
    public init(outSr: Double, maxVoices: Int? = nil, voiceCapacity: Int? = nil, store: SF2RegionStore = SF2RegionStore()) {
        self.outSr = outSr
        let mv = max(1, maxVoices ?? 64)
        let cap = max(mv, voiceCapacity ?? mv)
        regionStore = store
        let voices = UnsafeMutablePointer<Voice>.allocate(capacity: cap)
        voices.initialize(repeating: Voice(sr: outSr), count: cap)
        let order = UnsafeMutablePointer<Int32>.allocate(capacity: cap)
        order.initialize(repeating: 0, count: cap)
        let free = UnsafeMutablePointer<Int32>.allocate(capacity: cap)
        for i in 0 ..< cap { (free + i).initialize(to: Int32(cap - 1 - i)) }
        let tracks = UnsafeMutablePointer<TrackRT>.allocate(capacity: Self.maxTracks)
        tracks.initialize(repeating: TrackRT(), count: Self.maxTracks)
        let chans = UnsafeMutablePointer<ChannelRT>.allocate(capacity: 16)
        chans.initialize(repeating: ChannelRT(), count: 16)
        let ccs = UnsafeMutablePointer<UInt8>.allocate(capacity: 16 * 128)
        ccs.initialize(repeating: 0, count: 16 * 128)
        let nrpn = UnsafeMutablePointer<Double>.allocate(capacity: 16 * 64)
        nrpn.initialize(repeating: 0, count: 16 * 64)
        let poly = UnsafeMutablePointer<UInt8>.allocate(capacity: 16 * 128)
        poly.initialize(repeating: 0, count: 16 * 128)
        let programs = UnsafeMutablePointer<Int32>.allocate(capacity: 129 * 128)
        programs.initialize(repeating: -1, count: 129 * 128)
        st = .allocate(capacity: 1)
        st.initialize(to: State(maxVoices: mv, capacity: cap, voices: voices, order: order, free: free, freeCount: cap,
                                tracks: tracks, store: store.hdr, chans: chans, ccs: ccs, nrpn: nrpn, poly: poly, programs: programs, fx: SF2EffectsRT(sr: outSr), master: MasterBusRT(sampleRate: outSr)))
        resetChannelsRT()
    }

    deinit {
        let s = st.pointee
        s.voices.deinitialize(count: s.capacity); s.voices.deallocate()
        s.order.deallocate(); s.free.deallocate()
        s.tracks.deinitialize(count: Self.maxTracks); s.tracks.deallocate()
        s.chans.deallocate(); s.ccs.deallocate(); s.nrpn.deallocate(); s.poly.deallocate(); s.programs.deallocate()
        s.fx.free()
        s.master.free()
        st.deinitialize(count: 1); st.deallocate()
    }

    // MARK: - gbk-shaped API (tests, offline)

    /// Rendering rules: always `.spec` (`.gbk` is an alias). Set before rendering (not real-time safe to change mid-note).
    public var fidelity: SF2Fidelity {
        get { .spec }
        set { st.pointee.spec = true }
    }

    /// Current controller value on a MIDI channel (`.spec` state).
    public func controller(_ cc: Int, channel: Int) -> Int {
        guard (0 ..< 16).contains(channel), (0 ..< 128).contains(cc) else { return 0 }
        return Int(st.pointee.ccs[channel * 128 + cc])
    }
    public func pitchBend(channel: Int) -> Int { (0 ..< 16).contains(channel) ? Int(st.pointee.chans[channel].bend) : 8192 }
    public func pitchBendRange(channel: Int) -> Double { (0 ..< 16).contains(channel) ? st.pointee.chans[channel].pws : 2 }

    public var maxVoices: Int { st.pointee.maxVoices }
    public var voiceCapacity: Int { st.pointee.capacity }
    public var voiceCount: Int { st.pointee.count }
    public var cc7Volume: Double { st.pointee.cc7 }
    public var cc10Pan: Double { st.pointee.cc10 }
    public var cc11Expression: Double { st.pointee.cc11 }

    /// Non-real-time: grows the pool if needed.
    public func setMaxVoices(_ n: Int) {
        let mv = max(1, n)
        if mv > st.pointee.capacity { reallocateVoices(mv) }
        st.pointee.maxVoices = mv
    }

    /// Real-time safe: clamps to the preallocated pool.
    public func setMaxVoicesRT(_ n: Int) { st.pointee.maxVoices = max(1, min(n, st.pointee.capacity)) }

    private func reallocateVoices(_ cap: Int) {
        var s = st.pointee
        let voices = UnsafeMutablePointer<Voice>.allocate(capacity: cap)
        voices.initialize(repeating: Voice(sr: outSr), count: cap)
        voices.update(from: s.voices, count: s.capacity)
        let order = UnsafeMutablePointer<Int32>.allocate(capacity: cap)
        order.initialize(repeating: 0, count: cap)
        order.update(from: s.order, count: s.count)
        let free = UnsafeMutablePointer<Int32>.allocate(capacity: cap)
        free.initialize(repeating: 0, count: cap)
        free.update(from: s.free, count: s.freeCount)
        var fc = s.freeCount
        for slot in stride(from: cap - 1, through: s.capacity, by: -1) { free[fc] = Int32(slot); fc += 1 }
        s.voices.deinitialize(count: s.capacity); s.voices.deallocate(); s.order.deallocate(); s.free.deallocate()
        s.voices = voices; s.order = order; s.free = free; s.freeCount = fc; s.capacity = cap
        st.pointee = s
    }

    /// Replaces the region store (non-real-time). Clears voices and track region references.
    public func setRegionStore(_ store: SF2RegionStore) {
        regionStore = store
        st.pointee.store = store.hdr
        clearVoices()
    }

    /// Global region list (gbk `engine.regions`). Setting does not clear voices, like assignment in TS.
    public var regions: [SF2Region] {
        get { regionStore.regions(of: st.pointee.globalList) }
        set { st.pointee.globalList = regionStore.add(SF2RegionList(newValue)) }
    }

    public var voices: [SF2VoiceSnapshot] {
        (0 ..< st.pointee.count).map { i in
            let v = st.pointee.voices[Int(st.pointee.order[i])]
            return SF2VoiceSnapshot(note: Int(v.note), velocity: Int(v.velocity), channel: Int(v.channel),
                                    trackIndex: v.trackIndex < 0 ? nil : Int(v.trackIndex), volEnvStage: v.volEnv.stage,
                                    volEnvLevel: v.volEnv.level, baseGain: v.baseGain)
        }
    }

    public var trackStates: [Int: SF2TrackSnapshot] {
        var out: [Int: SF2TrackSnapshot] = [:]
        for i in 0 ..< Self.maxTracks where st.pointee.tracks[i].present {
            let t = st.pointee.tracks[i]
            out[i] = SF2TrackSnapshot(regionCount: regionStore.regions(of: t.list).count, cc7Volume: t.cc7, cc10Pan: t.cc10,
                                      cc11Expression: t.cc11, pan: t.pan, gain: t.gain)
        }
        return out
    }

    public func setTrackStates(_ tracks: [SF2TrackState]) {
        let pods = tracks.map { t -> (Int, TrackRT) in
            var r = TrackRT()
            r.present = true
            r.list = t.regions.map { regionStore.add($0) } ?? -1
            r.cc7 = max(0, min(127, t.cc7Volume ?? 100))
            r.cc10 = max(0, min(127, t.cc10Pan ?? 64))
            r.cc11 = max(0, min(127, t.cc11Expression ?? 127))
            r.pan = max(-1, min(1, t.pan ?? 0))
            r.gain = max(0, t.gain ?? 1)
            r.ccSet = r.hasNonDefaultCcs
            return (t.trackIndex, r)
        }
        resetTracksRT()
        for (i, r) in pods where i >= 0 && i < Self.maxTracks { st.pointee.tracks[i] = r }
        clearVoices()
    }

    /// Converts a public event to its POD form (adds region lists to the store: non-real-time).
    public func pod(_ e: SF2SynthEvent) -> EngineEvent {
        EngineEvent(kind: e.kind.rawValue, frame: e.frame ?? Int.max, seq: e.seq,
                    trackIndex: e.trackIndex.map { Int32(clamping: $0) } ?? -1,
                    channel: e.channel.map { Int32(clamping: $0) } ?? -1,
                    note: Int32(truncatingIfNeeded: e.note), velocity: Int32(truncatingIfNeeded: e.velocity),
                    list: e.regions.map { regionStore.add($0) } ?? -1,
                    cc7: e.cc7Volume ?? .nan, cc10: e.cc10Pan ?? .nan, cc11: e.cc11Expression ?? .nan,
                    pan: e.pan ?? .nan, gain: e.gain ?? .nan)
    }

    public func dispatchEvent(_ e: SF2SynthEvent) { dispatch(pod(e)) }

    public func pickRegions(note: Int, velocity: Int, regions: [SF2Region]? = nil) -> [SF2Region] {
        (regions ?? self.regions).filter {
            note >= $0.keyRange.0 && note <= $0.keyRange.1 && velocity >= $0.velRange.0 && velocity <= $0.velRange.1
        }
    }

    public func renderRange(_ left: inout [Float], _ right: inout [Float]) {
        let n = min(left.count, right.count)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in renderRange(l.baseAddress!, r.baseAddress!, n) }
        }
    }

    public func renderScheduled(_ left: inout [Float], _ right: inout [Float], events: [SF2SynthEvent], eventIndex: Int = 0,
                                renderedSamples: Int = 0) -> (eventIndex: Int, renderedSamples: Int) {
        let pods = events.map { pod($0) }
        let n = min(left.count, right.count)
        return left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                pods.withUnsafeBufferPointer { p in
                    renderScheduled(l.baseAddress!, r.baseAddress!, n, p.baseAddress!, p.count, eventIndex, renderedSamples)
                }
            }
        }
    }

    // MARK: - Real-time core

    /// Real-time safe: points the engine at another region store's header (the caller keeps that store alive)
    /// and drops the global region list, which referred to the old store.
    public func setStoreRT(_ hdr: UnsafeMutablePointer<SF2RegionStore.Header>) {
        st.pointee.store = hdr
        st.pointee.globalList = -1
    }

    public func resetTracksRT() {
        for i in 0 ..< Self.maxTracks { st.pointee.tracks[i] = TrackRT() }
        resetChannelsRT()
    }

    /// MIDI power-on channel state: CC7 100, CC10 64, CC11 127, others 0; bend center, range 2 semitones.
    public func resetChannelsRT() {
        st.pointee.cc7 = 100; st.pointee.cc10 = 64; st.pointee.cc11 = 127
        let s = st.pointee
        for c in 0 ..< 16 {
            s.chans[c] = ChannelRT()
            let cc = s.ccs + c * 128
            for i in 0 ..< 128 { cc[i] = 0 }
            cc[7] = 100; cc[10] = 64; cc[11] = 127
            cc[100] = 127; cc[101] = 127
            for k in 0 ..< 64 { s.nrpn[c * 64 + k] = 0 }
            for k in 0 ..< 128 { s.poly[c * 128 + k] = 0 }
        }
    }

    /// Non-real-time: resolves every (bank 0...128, program 0...127) of `sf` to a `.spec` region list
    /// for `.programChange` (MIDI-07). Exact (preset, bank) first match (Z-12); missing pairs use the
    /// engine's bank-0 / any-bank fallback (policy, not SoundFont 2.01).
    public func loadPrograms(from sf: SF2SoundFont) throws {
        var byPreset: [Int: Int32] = [:]
        for bank in 0 ... 128 {
            for prog in 0 ... 127 {
                var id: Int32 = -1
                if let p = sf.resolvePresetIndex(program: prog, bank: bank) {
                    if let hit = byPreset[p] { id = hit } else {
                        id = regionStore.add(try sf.regionList(forPreset: p, fidelity: .spec))
                        byPreset[p] = id
                    }
                }
                st.pointee.programs[bank * 128 + prog] = id
            }
        }
    }

    public func setTrackRT(_ index: Int, _ t: TrackRT) {
        guard index >= 0 && index < Self.maxTracks else { return }
        var r = t
        r.ccSet = r.ccSet || r.hasNonDefaultCcs
        r.chanMask = 0
        st.pointee.tracks[index] = r
    }

    public func clearVoices() {
        let cap = st.pointee.capacity
        st.pointee.count = 0
        for i in 0 ..< cap { st.pointee.free[i] = Int32(cap - 1 - i) }
        st.pointee.freeCount = cap
    }

    /// Releases every voice (note-off semantics). Used by the player on pause.
    public func releaseAllRT() {
        let s = st.pointee
        for i in 0 ..< s.count {
            let v = s.voices + Int(s.order[i])
            v.pointee.volEnv.noteOff(); v.pointee.modEnv.noteOff()
            if v.pointee.loopUntilReleaseThenTail { v.pointee.inReleaseTail = true }
        }
    }

    /// Releases voices of tracks in `mask` (bit i = SMF track i). Used when tracks are muted.
    public func releaseTracksRT(_ mask: UInt64) {
        let s = st.pointee
        for i in 0 ..< s.count {
            let v = s.voices + Int(s.order[i])
            let t = v.pointee.trackIndex
            guard t >= 0 && t < 64 && mask & (UInt64(1) << UInt64(t)) != 0 else { continue }
            v.pointee.volEnv.noteOff(); v.pointee.modEnv.noteOff()
            if v.pointee.loopUntilReleaseThenTail { v.pointee.inReleaseTail = true }
        }
    }

    @inline(__always) private func removeVoice(at idx: Int) {
        let s = st
        let slot = s.pointee.order[idx]
        let n = s.pointee.count
        var i = idx
        while i < n - 1 { s.pointee.order[i] = s.pointee.order[i + 1]; i += 1 }
        s.pointee.count = n - 1
        s.pointee.free[s.pointee.freeCount] = slot
        s.pointee.freeCount += 1
    }

    @inline(__always) private func listRange(_ id: Int32) -> (UnsafeMutablePointer<VoiceRegion>?, Int) {
        let h = st.pointee.store.pointee
        guard id >= 0, Int(id) < h.listCount, let lists = h.lists, let regions = h.regions else { return (nil, 0) }
        let r = lists[Int(id)]
        return (regions + r.start, r.count)
    }

    public func dispatch(_ msg: EngineEvent) {
        let s = st
        switch msg.kind {
        case SF2SynthEvent.Kind.setPreset.rawValue:
            if s.pointee.spec && msg.channel >= 0 && msg.channel < 16 {
                s.pointee.chans[Int(msg.channel)].list = msg.list
                return
            }
            if msg.trackIndex >= 0 {
                let ti = Int(msg.trackIndex)
                if ti < Self.maxTracks && s.pointee.tracks[ti].present { s.pointee.tracks[ti].list = msg.list }
                return
            }
            s.pointee.globalList = msg.list
            clearVoices()

        case SF2SynthEvent.Kind.noteOn.rawValue:
            let note = Int(msg.note)
            let velocity = Int(msg.velocity)
            // MIDI-01 (9.2): in .spec a note-on with velocity 0 is a note-off.
            if s.pointee.spec && velocity == 0 {
                keyOffSpec(msg.note, trackIndex: msg.trackIndex, channel: msg.channel)
                return
            }
            var track: UnsafeMutablePointer<TrackRT>?
            if msg.trackIndex >= 0 && Int(msg.trackIndex) < Self.maxTracks && s.pointee.tracks[Int(msg.trackIndex)].present {
                track = s.pointee.tracks + Int(msg.trackIndex)
            }
            var listId = track?.pointee.list ?? s.pointee.globalList
            if s.pointee.spec && msg.channel >= 0 && msg.channel < 16 && s.pointee.chans[Int(msg.channel)].list >= 0 {
                listId = s.pointee.chans[Int(msg.channel)].list
            }
            let (base, count) = listRange(listId)
            guard let base, count > 0 else { return }
            var any = false
            for k in 0 ..< count {
                let r = base + k
                if note >= r.pointee.keyLo && note <= r.pointee.keyHi && velocity >= r.pointee.velLo && velocity <= r.pointee.velHi {
                    any = true
                    if r.pointee.exclusiveClass != 0 {
                        if s.pointee.spec { chokeExclusiveSpec(r.pointee.exclusiveClass, channel: msg.channel >= 0 ? msg.channel : 0, list: listId) }
                        else { chokeExclusive(r.pointee.exclusiveClass, trackIndex: msg.trackIndex) }
                    }
                }
            }
            if !any { return }
            if s.pointee.spec, let t = track, t.pointee.ccSet {
                let ch = Int(msg.channel >= 0 && msg.channel < 16 ? msg.channel : 0)
                if t.pointee.chanMask & (1 << ch) == 0 {
                    t.pointee.chanMask |= 1 << ch
                    applyTrackCcsRT(t, ch)
                }
            }
            var trackVolumeMul = 1.0, trackPanPos = 0.0
            if let t = track?.pointee {
                if s.pointee.spec {
                    // .spec: CC7/10/11 come from the channel via modulators; the track adds the app's gain / pan.
                    trackVolumeMul = t.gain
                    trackPanPos = t.pan
                } else {
                    trackVolumeMul = (t.cc7 / 127) * (t.cc11 / 127) * t.gain
                    trackPanPos = (t.cc10 - 64) / 63 + t.pan
                }
            }
            for k in 0 ..< count {
                let r = base + k
                guard note >= r.pointee.keyLo && note <= r.pointee.keyHi && velocity >= r.pointee.velLo && velocity <= r.pointee.velHi
                else { continue }
                ensurePolyphony()
                guard s.pointee.freeCount > 0 else { continue }
                s.pointee.freeCount -= 1
                let slot = s.pointee.free[s.pointee.freeCount]
                s.pointee.voices[Int(slot)].list = listId
                makeVoice(s.pointee.voices + Int(slot), r, note: note, velocity: velocity,
                          channel: msg.channel >= 0 ? msg.channel : 0, trackIndex: msg.trackIndex,
                          trackPanPos: trackPanPos, trackVolumeMul: trackVolumeMul, list: listId)
                s.pointee.order[s.pointee.count] = slot
                s.pointee.count += 1
            }

        case SF2SynthEvent.Kind.noteOff.rawValue:
            if s.pointee.spec { keyOffSpec(msg.note, trackIndex: msg.trackIndex, channel: msg.channel) }
            else { releaseNote(msg.note, trackIndex: msg.trackIndex, channel: msg.channel) }

        case SF2SynthEvent.Kind.setControllers.rawValue:
            @inline(__always) func cc(_ x: Double) -> Double { max(0, min(127, Double(Int32(truncatingIfNeeded: Int64(max(-1e18, min(1e18, x))))))) }
            if msg.trackIndex >= 0 {
                let ti = Int(msg.trackIndex)
                guard ti < Self.maxTracks, s.pointee.tracks[ti].present else { return }
                let t = s.pointee.tracks + ti
                if msg.cc7.isFinite { t.pointee.cc7 = cc(msg.cc7) }
                if msg.cc10.isFinite { t.pointee.cc10 = cc(msg.cc10) }
                if msg.cc11.isFinite { t.pointee.cc11 = cc(msg.cc11) }
                if msg.pan.isFinite { t.pointee.pan = max(-1, min(1, msg.pan)) }
                if msg.gain.isFinite { t.pointee.gain = max(0, msg.gain) }
                if s.pointee.spec && (msg.cc7.isFinite || msg.cc10.isFinite || msg.cc11.isFinite) {
                    t.pointee.ccSet = true
                    for c in 0 ..< 16 where t.pointee.chanMask & (1 << c) != 0 { applyTrackCcsRT(t, c) }
                }
                return
            }
            // Engine-wide (one engine per app track): in .spec CC7/10/11 go to every channel's controller state.
            if msg.cc7.isFinite { s.pointee.cc7 = cc(msg.cc7); if s.pointee.spec { for c in 0 ..< 16 { controlChangeRT(c, 7, Int(s.pointee.cc7)) } } }
            if msg.cc10.isFinite { s.pointee.cc10 = cc(msg.cc10); if s.pointee.spec { for c in 0 ..< 16 { controlChangeRT(c, 10, Int(s.pointee.cc10)) } } }
            if msg.cc11.isFinite { s.pointee.cc11 = cc(msg.cc11); if s.pointee.spec { for c in 0 ..< 16 { controlChangeRT(c, 11, Int(s.pointee.cc11)) } } }

        case SF2SynthEvent.Kind.controlChange.rawValue:
            guard s.pointee.spec, msg.channel >= 0, msg.channel < 16, msg.note >= 0, msg.note < 128 else { return }
            controlChangeRT(Int(msg.channel), Int(msg.note), Int(max(0, min(127, msg.velocity))))

        case SF2SynthEvent.Kind.programChange.rawValue:
            guard s.pointee.spec, msg.channel >= 0, msg.channel < 16, msg.note >= 0, msg.note < 128 else { return }
            let c = Int(msg.channel)
            s.pointee.chans[c].program = msg.note
            let bank = c == 9 ? 128 : Int(s.pointee.ccs[c * 128])
            s.pointee.chans[c].list = s.pointee.programs[bank * 128 + Int(msg.note)]

        case SF2SynthEvent.Kind.channelPressure.rawValue:
            guard s.pointee.spec, msg.channel >= 0, msg.channel < 16 else { return }
            s.pointee.chans[Int(msg.channel)].pressure = max(0, min(127, msg.velocity))
            updateChannelVoices(Int(msg.channel))

        case SF2SynthEvent.Kind.polyPressure.rawValue:
            guard s.pointee.spec, msg.channel >= 0, msg.channel < 16, msg.note >= 0, msg.note < 128 else { return }
            s.pointee.poly[Int(msg.channel) * 128 + Int(msg.note)] = UInt8(max(0, min(127, msg.velocity)))
            updateChannelVoices(Int(msg.channel))

        case SF2SynthEvent.Kind.pitchBend.rawValue:
            guard s.pointee.spec, msg.channel >= 0, msg.channel < 16 else { return }
            s.pointee.chans[Int(msg.channel)].bend = max(0, min(16383, msg.velocity))
            updateChannelVoices(Int(msg.channel))

        default:
            break
        }
    }

    @inline(__always) func releaseNote(_ note: Int32, trackIndex: Int32, channel: Int32) {
        let s = st
        for i in 0 ..< s.pointee.count {
            let v = s.pointee.voices + Int(s.pointee.order[i])
            let sameTrack = trackIndex < 0 || v.pointee.trackIndex == trackIndex
            let sameChannel = channel < 0 || v.pointee.channel == channel
            if v.pointee.note == note && sameTrack && sameChannel {
                v.pointee.volEnv.noteOff(); v.pointee.modEnv.noteOff()
                if v.pointee.loopUntilReleaseThenTail { v.pointee.inReleaseTail = true }
            }
        }
    }

    /// MIDI-02/03 key-off: deferred while CC64 is down or the note is held by sostenuto.
    @inline(__always) func keyOffSpec(_ note: Int32, trackIndex: Int32, channel: Int32) {
        let s = st
        for i in 0 ..< s.pointee.count {
            let v = s.pointee.voices + Int(s.pointee.order[i])
            let sameTrack = trackIndex < 0 || v.pointee.trackIndex == trackIndex
            let sameChannel = channel < 0 || v.pointee.channel == channel
            guard v.pointee.note == note && sameTrack && sameChannel && v.pointee.keyDown else { continue }
            keyOffVoice(v)
        }
    }

    @inline(__always) func keyOffVoice(_ v: UnsafeMutablePointer<Voice>) {
        v.pointee.keyDown = false
        let c = Int(max(0, min(15, v.pointee.channel)))
        if st.pointee.ccs[c * 128 + 64] >= 64 || v.pointee.sostenuto { v.pointee.deferred = true; return }
        v.pointee.deferred = false
        v.pointee.volEnv.noteOff(); v.pointee.modEnv.noteOff()
        if v.pointee.loopUntilReleaseThenTail { v.pointee.inReleaseTail = true }
    }

    /// Releases deferred voices on `channel` that no pedal holds any more.
    @inline(__always) func releaseDeferred(_ channel: Int) {
        let s = st
        let sustain = s.pointee.ccs[channel * 128 + 64] >= 64
        for i in 0 ..< s.pointee.count {
            let v = s.pointee.voices + Int(s.pointee.order[i])
            guard Int(v.pointee.channel) == channel, v.pointee.deferred, !sustain, !v.pointee.sostenuto else { continue }
            v.pointee.deferred = false
            v.pointee.volEnv.noteOff(); v.pointee.modEnv.noteOff()
            if v.pointee.loopUntilReleaseThenTail { v.pointee.inReleaseTail = true }
        }
    }

    /// G-12 (8.1.2 #57): terminate same-class voices of the same preset (region list) and channel rapidly.
    static let exclusiveReleaseSec = 0.005
    func chokeExclusiveSpec(_ exclusiveClass: Int, channel: Int32, list: Int32) {
        let s = st
        for i in 0 ..< s.pointee.count {
            let v = s.pointee.voices + Int(s.pointee.order[i])
            guard v.pointee.exclusiveClass == exclusiveClass, v.pointee.channel == channel, v.pointee.list == list else { continue }
            v.pointee.volEnv.fastRelease(Self.exclusiveReleaseSec); v.pointee.modEnv.noteOff()
            v.pointee.keyDown = false; v.pointee.deferred = false; v.pointee.sostenuto = false
            if v.pointee.loopUntilReleaseThenTail { v.pointee.inReleaseTail = true }
        }
    }

    func chokeExclusive(_ exclusiveClass: Int, trackIndex: Int32) {
        let s = st
        for i in 0 ..< s.pointee.count {
            let v = s.pointee.voices + Int(s.pointee.order[i])
            let sameTrack = trackIndex < 0 || v.pointee.trackIndex == trackIndex
            if v.pointee.exclusiveClass == exclusiveClass && sameTrack {
                v.pointee.volEnv.noteOff(); v.pointee.modEnv.noteOff()
                if v.pointee.loopUntilReleaseThenTail { v.pointee.inReleaseTail = true }
            }
        }
    }

    func ensurePolyphony() {
        let s = st
        if s.pointee.count < s.pointee.maxVoices { return }
        var minIdx = 0
        var minVal = Double.infinity
        for i in 0 ..< s.pointee.count {
            let v = s.pointee.voices + Int(s.pointee.order[i])
            let loudness = v.pointee.volEnv.level * v.pointee.baseGain
            if loudness < minVal { minVal = loudness; minIdx = i }
        }
        if s.pointee.count > 0 { removeVoice(at: minIdx) }
    }

    private func makeVoice(_ v: UnsafeMutablePointer<Voice>, _ r: UnsafeMutablePointer<VoiceRegion>, note: Int, velocity: Int,
                           channel: Int32, trackIndex: Int32, trackPanPos: Double, trackVolumeMul: Double, list: Int32 = -1) {
        let reg = r.pointee
        let sr = outSr
        var voice = Voice(sr: sr)
        voice.list = list
        // G-02: substitution generators replace the MIDI key / velocity for this zone (.spec).
        let effKey = st.pointee.spec && reg.keynum >= 0 ? reg.keynum : note
        let effVel = st.pointee.spec && reg.velocity >= 0 ? reg.velocity : velocity
        voice.effKey = Int32(truncatingIfNeeded: effKey); voice.effVel = Int32(truncatingIfNeeded: effVel)
        voice.note = Int32(truncatingIfNeeded: note); voice.channel = channel; voice.trackIndex = trackIndex
        voice.velocity = Int32(truncatingIfNeeded: velocity)
        voice.start = Double(reg.start); voice.end = Double(reg.end)
        voice.loopStart = Double(reg.loopStart); voice.loopEnd = Double(reg.loopEnd)
        voice.pos = voice.start
        voice.looping = reg.sampleModes == 1 || reg.sampleModes == 3
        voice.loopUntilReleaseThenTail = reg.sampleModes == 3
        // regionBaseRate
        let keyTrackCents = Double((effKey - reg.root) * reg.scaleTuning)
        let tuneCents = Double(reg.coarseTune * 100 + reg.fineTune)
        let srRatio = Double(reg.sampleRate) / sr
        voice.baseRate = centsToRatio(keyTrackCents + tuneCents) * srRatio
        voice.rate = voice.baseRate
        voice.dataL = reg.dataL; voice.lenL = reg.lenL
        voice.dataR = reg.dataR; voice.lenR = reg.lenR
        voice.baseGain = velToLin(Double(velocity), 2.0) * cbAttenToLin(Double(reg.initialAttenuationCb))
        voice.regionPanPos = Double(max(-500, min(500, reg.pan))) / 500
        voice.trackPanPos = max(-1, min(1, trackPanPos))
        voice.trackVolumeMul = max(0, trackVolumeMul)
        voice.exclusiveClass = reg.exclusiveClass
        voice.volEnv.setFromSf2(reg.volEnv)
        voice.modEnv.setFromSf2(reg.modEnv)
        voice.modLfo.set(freqHz: centsToRatio(Double(reg.modLfoFreqCents)), delaySec: timecentsToSeconds(Double(reg.modLfoDelayTc)))
        voice.vibLfo.set(freqHz: centsToRatio(Double(reg.vibLfoFreqCents)), delaySec: timecentsToSeconds(Double(reg.vibLfoDelayTc)))
        voice.initialFc = Double(reg.initialFilterFcCents)
        voice.lpf.setCutoffHz(fcCentsToHz(voice.initialFc))
        voice.lastFc = voice.initialFc
        voice.vibToPitch = Double(reg.vibLfoToPitchCents)
        voice.modToPitch = Double(reg.modLfoToPitchCents)
        voice.modEnvToFc = Double(reg.modEnvToFilterFcCents)
        voice.modLfoToFc = Double(reg.modLfoToFilterFcCents)
        if st.pointee.spec {
            specVoice(&voice, r, note: effKey, velocity: effVel, trackGain: trackVolumeMul)
        }
        voice.volEnv.noteOn()
        voice.modEnv.noteOn()
        v.pointee = voice
    }

    // MARK: - SoundFont 2.01 (.spec; 2.04 features gated by SF2SpecVersion)

    @inline(__always) private func modInputs(_ channel: Int32, note: Int, velocity: Int, midiNote: Int) -> ModInputs {
        let c = Int(max(0, min(15, channel)))
        let ch = st.pointee.chans[c]
        let poly = midiNote >= 0 && midiNote < 128 ? Int(st.pointee.poly[c * 128 + midiNote]) : 0
        return ModInputs(velocity: velocity, key: note, cc: UnsafePointer(st.pointee.ccs + c * 128), pitchWheel: Int(ch.bend),
                         pitchWheelSensitivity: ch.pws, channelPressure: Int(ch.pressure), polyPressure: poly)
    }

    /// Sums every modulator into `d` (indexed by destination generator; `SF2Modulator.slotCount` slots).
    @inline(__always) private func evalMods(_ voice: Voice, _ d: UnsafeMutablePointer<Double>) {
        for i in 0 ..< SF2Modulator.slotCount { d[i] = 0 }
        // N-04: NRPN offsets add to the generators like a modulator.
        let c = Int(max(0, min(15, voice.channel)))
        let nr = st.pointee.nrpn + c * 64
        for k in 0 ..< 64 { d[k] = nr[k] }
        guard let mods = voice.mods else { return }
        let inputs = modInputs(voice.channel, note: Int(voice.effKey), velocity: Int(voice.effVel), midiNote: Int(voice.note))
        for k in 0 ..< voice.modCount {
            let m = mods[k]
            d[Int(m.dest)] += modValue(m, inputs)
        }
    }

    /// Applies the modulated values that may change while the note sounds (CC / pitch wheel sources).
    @inline(__always) private func applyLive(_ v: inout Voice, _ d: UnsafeMutablePointer<Double>) {
        let qCb = max(0, min(960, v.regQ + d[9]))
        // G-08 (8.1.2 #9): Q cB is the resonance peak height above the DC gain, and the DC gain is
        // reduced by Q/2. The 2-pole RBJ low-pass whose peak/DC ratio is G = 10^(Q/200) has
        // q^2 = (G^2 + G sqrt(G^2 - 1)) / 2 (q = 1/sqrt 2 at Q = 0: no peak).
        let gq = pow(10, qCb / 200)
        let q = ((gq * gq + gq * (gq * gq - 1).squareRoot()) / 2).squareRoot()
        if q != v.lpf.q { v.lpf.q = q; v.lastFc = .nan }
        v.qCb = qCb
        let filterGain = pow(10, -qCb / 400)
        v.baseGain = cbAttenToLin(max(0, min(1440, v.regAtten + d[48]))) * filterGain
        v.regionPanPos = max(-500, min(500, v.regPan + d[17])) / 500
        // M-12 / Z-11: modulated destinations are re-clamped to their 8.1.3 range on every evaluation.
        v.initialFc = GenInfo.clamp(8, v.regFc + d[8])
        if v.lastFc != v.initialFc { v.lastFc = .nan }
        v.vibToPitch = GenInfo.clamp(6, v.regVib + d[6])
        v.modToPitch = GenInfo.clamp(5, v.regModPitch + d[5])
        v.modEnvToPitch = GenInfo.clamp(7, v.regModEnvPitch + d[7])
        v.modLfoToFc = GenInfo.clamp(10, v.regModLfoFc + d[10])
        v.modEnvToFc = GenInfo.clamp(11, v.regModEnvFc + d[11])
        v.modLfoToVol = GenInfo.clamp(13, v.regModLfoVol + d[13])
        v.chorusAmt = GenInfo.clamp(15, v.regChorus + d[15]) / 1000
        v.reverbAmt = GenInfo.clamp(16, v.regReverb + d[16]) / 1000
        let pitch = d[Int(SF2Modulator.pitchDest)] + d[51] * 100 + d[52]
        v.baseRate = pitch == 0 ? v.baseRate0 : v.baseRate0 * centsToRatio(pitch)
        v.rate = v.baseRate
    }

    private func specVoice(_ voice: inout Voice, _ r: UnsafeMutablePointer<VoiceRegion>, note: Int, velocity: Int, trackGain: Double) {
        let reg = r.pointee
        let h = st.pointee.store.pointee
        voice.spec = true
        if let mods = h.mods, reg.modCount > 0, reg.modStart + reg.modCount <= h.modCount {
            voice.mods = UnsafePointer(mods + reg.modStart); voice.modCount = reg.modCount
        }
        voice.regAtten = Double(reg.initialAttenuationCb); voice.regPan = Double(reg.pan)
        voice.regFc = Double(reg.initialFilterFcCents); voice.regQ = Double(reg.initialFilterQCb)
        voice.regVib = Double(reg.vibLfoToPitchCents); voice.regModPitch = Double(reg.modLfoToPitchCents)
        voice.regModEnvPitch = Double(reg.modEnvToPitchCents)
        voice.regModLfoFc = Double(reg.modLfoToFilterFcCents); voice.regModEnvFc = Double(reg.modEnvToFilterFcCents)
        voice.regModLfoVol = Double(reg.modLfoToVolumeCb)
        voice.regChorus = Double(reg.chorusSend); voice.regReverb = Double(reg.reverbSend)
        // MIDI-04 soft pedal (CC67 >= 64 at note-on, MIDI 1.0): -6 dB (60 cB) and -600 cents cutoff (engine choice).
        if st.pointee.ccs[Int(max(0, min(15, voice.channel))) * 128 + 67] >= 64 {
            voice.regAtten += Self.softPedalAttenuationCb; voice.regFc -= Self.softPedalFcCents
        }
        voice.baseRate0 = voice.baseRate
        voice.trackGain = trackGain
        voice.trackVolumeMul = trackGain
        withUnsafeTemporaryAllocation(of: Double.self, capacity: SF2Modulator.slotCount) { buf in
            let d = buf.baseAddress!
            evalMods(voice, d)
            // Note-on-only destinations: sample start, LFO / envelope timing, key-number scaling.
            let keyDelta = Double(60 - note)
            // M-12: every summed value is re-clamped to its 8.1.3 range (key scaling is part of the sum).
            @inline(__always) func tc(_ base: Int, _ add: Double, _ id: Int) -> Int { Int(GenInfo.clamp(id, Double(base) + add).rounded()) }
            let kVH = GenInfo.clamp(39, Double(reg.keynumToVolEnvHold) + d[39]), kVD = GenInfo.clamp(40, Double(reg.keynumToVolEnvDecay) + d[40])
            let kMH = GenInfo.clamp(31, Double(reg.keynumToModEnvHold) + d[31]), kMD = GenInfo.clamp(32, Double(reg.keynumToModEnvDecay) + d[32])
            var ve = reg.volEnv
            ve.delayTc = tc(ve.delayTc, d[33], 33); ve.attackTc = tc(ve.attackTc, d[34], 34)
            ve.holdTc = tc(ve.holdTc, d[35], 35) + Int((kVH * keyDelta).rounded())
            ve.decayTc = tc(ve.decayTc, d[36], 36) + Int((kVD * keyDelta).rounded())
            ve.sustainCb = tc(ve.sustainCb, d[37], 37); ve.releaseTc = tc(ve.releaseTc, d[38], 38)
            voice.volEnv.spec = true
            voice.volEnv.setFromSf2(ve)
            var me = reg.modEnv
            me.delayTc = tc(me.delayTc, d[25], 25); me.attackTc = tc(me.attackTc, d[26], 26)
            me.holdTc = tc(me.holdTc, d[27], 27) + Int((kMH * keyDelta).rounded())
            me.decayTc = tc(me.decayTc, d[28], 28) + Int((kMD * keyDelta).rounded())
            me.sustain = max(0, min(1, me.sustain - d[29] / 1000)); me.releaseTc = tc(me.releaseTc, d[30], 30)
            voice.modEnv.spec = true
            voice.modEnv.setFromSf2(me)
            // G-06: LFO frequency clamped to the useful 1 mHz ... 100 Hz.
            voice.modLfo.set(freqHz: max(0.001, min(100, fcCentsToHz(GenInfo.clamp(22, Double(reg.modLfoFreqCents) + d[22])))),
                             delaySec: timecentsToSeconds(GenInfo.clamp(21, Double(reg.modLfoDelayTc) + d[21])))
            voice.vibLfo.set(freqHz: max(0.001, min(100, fcCentsToHz(GenInfo.clamp(24, Double(reg.vibLfoFreqCents) + d[24])))),
                             delaySec: timecentsToSeconds(GenInfo.clamp(23, Double(reg.vibLfoDelayTc) + d[23])))
            // G-13: scaleTuning (#56) is a non-real-time generator: modulators apply at note-on only.
            if d[56] != 0 {
                let st0 = Double(reg.scaleTuning), st1 = GenInfo.clamp(56, st0 + d[56])
                voice.baseRate *= centsToRatio(Double(note - reg.root) * (st1 - st0))
                voice.baseRate0 = voice.baseRate
            }
            voice.modLfo.triangle = true; voice.vibLfo.triangle = true
            applyLive(&voice, d)
            voice.lpf.setCutoffHz(fcCentsToHz(voice.initialFc))
            voice.lastFc = voice.initialFc
        }
    }

    public static let softPedalAttenuationCb = 60.0
    public static let softPedalFcCents = 600.0

    /// N-05 (9.6.3): NRPN data spans the generator's useful range; if the span exceeds 8192 units it
    /// is halved until <= 8192, i.e. each data step is 2^k native units (interpretation documented).
    static func nrpnScale(_ gen: Int) -> Double {
        guard let (lo, hi) = GenInfo.valueRange(gen) else { return 0 }
        var span = Double(hi - lo), step = 1.0
        while span > 8192 { span /= 2; step *= 2 }
        return step
    }

    /// Re-evaluates the modulators of every sounding voice on `channel` (after a CC or pitch-wheel change).
    func updateChannelVoices(_ channel: Int) {
        let s = st
        withUnsafeTemporaryAllocation(of: Double.self, capacity: SF2Modulator.slotCount) { buf in
            let d = buf.baseAddress!
            for i in 0 ..< s.pointee.count {
                let v = s.pointee.voices + Int(s.pointee.order[i])
                guard v.pointee.spec, Int(v.pointee.channel) == channel else { continue }
                evalMods(v.pointee, d)
                applyLive(&v.pointee, d)
            }
        }
    }

    @inline(__always) func applyTrackCcsRT(_ t: UnsafeMutablePointer<TrackRT>, _ ch: Int) {
        controlChangeRT(ch, 7, Int(t.pointee.cc7)); controlChangeRT(ch, 10, Int(t.pointee.cc10)); controlChangeRT(ch, 11, Int(t.pointee.cc11))
    }

    /// Channel-mode controller message (RPN 0 pitch-bend range, CC121 reset), then live modulator update.
    func controlChangeRT(_ channel: Int, _ cc: Int, _ value: Int) {
        let s = st.pointee
        let ch = s.chans + channel
        let ccs = s.ccs + channel * 128
        let old = ccs[cc]
        ccs[cc] = UInt8(value)
        switch cc {
        case 101: ch.pointee.rpnMsb = UInt8(value); ch.pointee.paramIsNRPN = false
        case 100: ch.pointee.rpnLsb = UInt8(value); ch.pointee.paramIsNRPN = false
        case 99:
            ch.pointee.rpnMsb = 127; ch.pointee.rpnLsb = 127   // NRPN selected: data entry is not RPN 0
            ch.pointee.paramIsNRPN = true
            ch.pointee.nrpnActive = value == 120                // N-01
            ch.pointee.nrpnAccum = 0
        case 98:
            ch.pointee.rpnMsb = 127; ch.pointee.rpnLsb = 127
            ch.pointee.paramIsNRPN = true
            guard ch.pointee.nrpnActive else { break }
            switch value {                                      // N-02 / N-03
            case 0 ... 99:
                let gen = Int(ch.pointee.nrpnAccum) + value
                ch.pointee.nrpnAccum = 0
                if gen < 61, GenInfo.valueRange(gen) != nil, gen != Gen.scaleTuning { ch.pointee.nrpnSelect = Int32(gen) }
            case 100: ch.pointee.nrpnAccum += 100
            case 101: ch.pointee.nrpnAccum += 1000
            case 102: ch.pointee.nrpnAccum += 10000
            default: break
            }
        case 6:
            if ch.pointee.paramIsNRPN {
                // N-04: 14-bit data (CC6 << 7 | CC38), centered at 0x2000, applied when the MSB arrives.
                if ch.pointee.nrpnActive && ch.pointee.nrpnSelect >= 0 {
                    let g = Int(ch.pointee.nrpnSelect)
                    let v = Double((value << 7) | Int(ccs[38])) - 8192
                    s.nrpn[channel * 64 + g] = v * Self.nrpnScale(g)
                }
            } else if ch.pointee.rpnMsb == 0 && ch.pointee.rpnLsb == 0 {
                ch.pointee.pws = Double(value) + Double(ccs[38]) / 100
            }
        case 38:
            if !ch.pointee.paramIsNRPN && ch.pointee.rpnMsb == 0 && ch.pointee.rpnLsb == 0 {
                ch.pointee.pws = Double(ccs[6]) + Double(value) / 100
            }
        case 64:
            if value < 64 && old >= 64 { releaseDeferred(channel) }           // MIDI-02
        case 66:                                                                // MIDI-03 CC66 sostenuto (MIDI 1.0)
            if value >= 64 && !ch.pointee.sostenuto {
                ch.pointee.sostenuto = true
                for i in 0 ..< s.count {
                    let v = s.voices + Int(s.order[i])
                    if Int(v.pointee.channel) == channel && v.pointee.spec && v.pointee.keyDown { v.pointee.sostenuto = true }
                }
            } else if value < 64 && ch.pointee.sostenuto {
                ch.pointee.sostenuto = false
                for i in 0 ..< s.count {
                    let v = s.voices + Int(s.order[i])
                    if Int(v.pointee.channel) == channel { v.pointee.sostenuto = false }
                }
                releaseDeferred(channel)
            }
        case 120:                                                               // MIDI-05 all sound off
            for i in 0 ..< s.count {
                let v = s.voices + Int(s.order[i])
                if Int(v.pointee.channel) == channel { v.pointee.volEnv.kill(); v.pointee.finished = true }
            }
            return
        case 123:                                                               // MIDI-05 all notes off
            for i in 0 ..< s.count {
                let v = s.voices + Int(s.order[i])
                if Int(v.pointee.channel) == channel && v.pointee.spec && v.pointee.keyDown { keyOffVoice(v) }
            }
        case 121:
            // RP-015 reset all controllers: not volume / pan / bank / program. MIDI-06 / N-06: also
            // pedals, pressure, poly pressure and NRPN state / offsets.
            ccs[1] = 0; ccs[2] = 0; ccs[4] = 0; ccs[64] = 0; ccs[65] = 0; ccs[66] = 0; ccs[67] = 0; ccs[68] = 0; ccs[69] = 0
            ccs[11] = 127; ccs[100] = 127; ccs[101] = 127; ccs[98] = 127; ccs[99] = 127
            ch.pointee.rpnMsb = 127; ch.pointee.rpnLsb = 127
            ch.pointee.bend = 8192; ch.pointee.pressure = 0
            ch.pointee.paramIsNRPN = false; ch.pointee.nrpnActive = false; ch.pointee.nrpnSelect = -1; ch.pointee.nrpnAccum = 0
            ch.pointee.sostenuto = false
            for k in 0 ..< 64 { s.nrpn[channel * 64 + k] = 0 }
            for k in 0 ..< 128 { s.poly[channel * 128 + k] = 0 }
            for i in 0 ..< s.count {
                let v = s.voices + Int(s.order[i])
                if Int(v.pointee.channel) == channel { v.pointee.sostenuto = false }
            }
            releaseDeferred(channel)
        default: break
        }
        updateChannelVoices(channel)
    }

    @inline(__always) private func advancePos(_ v: UnsafeMutablePointer<Voice>) {
        v.pointee.pos += v.pointee.rate
        let effectiveLooping = v.pointee.looping && !v.pointee.inReleaseTail
        if effectiveLooping {
            if v.pointee.pos >= v.pointee.loopEnd {
                let loopLen = v.pointee.loopEnd - v.pointee.loopStart
                v.pointee.pos = loopLen > 1
                    ? v.pointee.loopStart + (v.pointee.pos - v.pointee.loopStart).truncatingRemainder(dividingBy: loopLen)
                    : v.pointee.loopStart
            }
            return
        }
        if v.pointee.pos >= v.pointee.end || !v.pointee.pos.isFinite { v.pointee.finished = true }
    }

    /// One output frame: renderRange / renderScheduled inner voice loop.
    @inline(__always) private func renderFrame(_ ccPanPos: Double) -> (Double, Double) {
        let s = st
        var sumL = 0.0, sumR = 0.0
        var vi = s.pointee.count - 1
        while vi >= 0 {
            let v = s.pointee.voices + Int(s.pointee.order[vi])
            if v.pointee.finished || v.pointee.volEnv.stage == .idle {
                removeVoice(at: vi)
                vi -= 1
                continue
            }
            let modEnv = v.pointee.modEnv.next()
            // .spec (G-06): LFOs run from note-on whatever their depth (depth may be modulated later).
            let needModLfo = v.pointee.spec || v.pointee.modToPitch != 0 || v.pointee.modLfoToFc != 0 || v.pointee.modLfoToVol != 0
            let modLfo = needModLfo ? v.pointee.modLfo.next() : 0
            let vibLfo = v.pointee.spec || v.pointee.vibToPitch != 0 ? v.pointee.vibLfo.next() : 0
            var pitchCents = vibLfo * v.pointee.vibToPitch + modLfo * v.pointee.modToPitch
            if v.pointee.modEnvToPitch != 0 { pitchCents += modEnv * v.pointee.modEnvToPitch }
            v.pointee.rate = pitchCents == 0 ? v.pointee.baseRate : v.pointee.baseRate * centsToRatio(pitchCents)

            let sL = readSampleMono(v.pointee.dataL!, v.pointee.lenL, v.pointee.pos)
            let sR = v.pointee.dataR != nil ? readSampleMono(v.pointee.dataR!, v.pointee.lenR, v.pointee.pos) : sL

            let fcCents = v.pointee.initialFc + modEnv * v.pointee.modEnvToFc + modLfo * v.pointee.modLfoToFc
            if fcCents != v.pointee.lastFc {
                v.pointee.lpf.setCutoffHz(fcCentsToHz(fcCents))
                v.pointee.lastFc = fcCents
            }
            let fL: Double, fR: Double
            if v.pointee.spec && v.pointee.qCb <= 0 && fcCentsToHz(fcCents) >= min(20000, 0.45 * outSr) {
                fL = sL; fR = sR                               // G-08: bypassed, flat
            } else {
                fL = v.pointee.lpf.processL(sL)
                fR = v.pointee.lpf.processR(sR)
            }
            let env = v.pointee.volEnv.next()
            var gain = v.pointee.baseGain * env * v.pointee.trackVolumeMul
            if v.pointee.modLfoToVol != 0 { gain *= cbAttenToLin(-modLfo * v.pointee.modLfoToVol) }
            let mixPan = max(-1, min(1, v.pointee.regionPanPos + (v.pointee.trackIndex < 0 ? ccPanPos : v.pointee.trackPanPos)))
            if mixPan != v.pointee.lastMixPan {
                if v.pointee.spec {
                    // G-10 (8.1.2 #17): linear amplitude law; -250 -> 75 % left, 25 % right.
                    v.pointee.gL = (1 - mixPan) * 0.5
                    v.pointee.gR = (1 + mixPan) * 0.5
                } else {
                    let angle = (mixPan + 1) * 0.25 * Double.pi
                    v.pointee.gL = cos(angle)
                    v.pointee.gR = sin(angle)
                }
                v.pointee.lastMixPan = mixPan
            }
            let oL = fL * gain * v.pointee.gL, oR = fR * gain * v.pointee.gR
            sumL += oL
            sumR += oR
            if v.pointee.spec {
                s.pointee.revL += oL * v.pointee.reverbAmt; s.pointee.revR += oR * v.pointee.reverbAmt
                s.pointee.choL += oL * v.pointee.chorusAmt; s.pointee.choR += oR * v.pointee.chorusAmt
            }
            advancePos(v)
            vi -= 1
        }
        return (sumL, sumR)
    }

    /// gbk `renderRange`: overwrites `count` frames.
    public func renderRange(_ outL: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>, _ count: Int) {
        let ccPanPos = st.pointee.spec ? 0 : (st.pointee.cc10 - 64) / 63
        let fx = st.pointee.spec && st.pointee.fxOn
        for i in 0 ..< count {
            var (l, r) = renderFrame(ccPanPos)
            if fx { let w = takeSends(); l += w.0; r += w.1 } else { clearSends() }
            (l, r) = applyMaster(l, r)
            outL[i] = Float(l)
            outR[i] = Float(r)
        }
    }

    /// G-11: `effectsEnabled` mixes the built-in reverb / chorus (driven by each voice's
    /// chorusEffectsSend / reverbEffectsSend, CC91 / CC93 via the default modulators) into
    /// `renderRange` / `renderScheduled` output. `.spec` voices only; set while not rendering.
    public var effectsEnabled: Bool {
        get { st.pointee.fxOn }
        set { st.pointee.fxOn = newValue }
    }

    /// Clears the built-in reverb / chorus state. Call while not rendering.
    public func resetEffects() { st.pointee.fx.clear(); st.pointee.master.reset() }

    /// Master gain in dB (default -3 dB). It applies whether or not the dynamics are enabled. Set while not rendering.
    public var masterGainDb: Double {
        get { st.pointee.masterGainDb }
        set { st.pointee.masterGainDb = newValue; st.pointee.masterGain = pow(10, newValue / 20) }
    }
    /// Master-bus dynamics (compressor, lookahead limiter, safety clip), on by default. Set while not rendering.
    public var masterDynamicsEnabled: Bool {
        get { st.pointee.masterOn }
        set { st.pointee.masterOn = newValue }
    }
    public var masterParams: MasterBusParams {
        get { st.pointee.master.params }
        set { st.pointee.master.setParams(newValue) }
    }
    public var masterLatencyFrames: Int { st.pointee.master.latencyFrames }
    public var masterGainReductionDb: Double { st.pointee.master.gainReductionDb }

    @inline(__always) private func applyMaster(_ l: Double, _ r: Double) -> (Double, Double) {
        let s = st
        let g = s.pointee.masterGain
        if s.pointee.masterOn {
            s.pointee.master.process(l * g, r * g)
            return (s.pointee.master.outL, s.pointee.master.outR)
        }
        return (l * g, r * g)
    }

    @inline(__always) private func clearSends() {
        st.pointee.revL = 0; st.pointee.revR = 0; st.pointee.choL = 0; st.pointee.choR = 0
    }

    @inline(__always) private func takeSends() -> (Double, Double) {
        let s = st
        let w = s.pointee.fx.process(s.pointee.revL, s.pointee.revR, s.pointee.choL, s.pointee.choR)
        s.pointee.revL = 0; s.pointee.revR = 0; s.pointee.choL = 0; s.pointee.choR = 0
        return w
    }

    /// G-11 aux-bus render: dry mix into `outL/outR` and the pre-effect send buses into the four aux
    /// buffers (send level x the voice's panned dry signal). The built-in effects are not applied, so a
    /// host can run its own reverb / chorus. Overwrites `count` frames of every buffer.
    public func renderRange(_ outL: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>,
                            reverbL: UnsafeMutablePointer<Float>, reverbR: UnsafeMutablePointer<Float>,
                            chorusL: UnsafeMutablePointer<Float>, chorusR: UnsafeMutablePointer<Float>, _ count: Int) {
        let s = st
        let ccPanPos = s.pointee.spec ? 0 : (s.pointee.cc10 - 64) / 63
        for i in 0 ..< count {
            let (l, r) = renderFrame(ccPanPos)
            outL[i] = Float(l); outR[i] = Float(r)
            reverbL[i] = Float(s.pointee.revL); reverbR[i] = Float(s.pointee.revR)
            chorusL[i] = Float(s.pointee.choL); chorusR[i] = Float(s.pointee.choR)
            s.pointee.revL = 0; s.pointee.revR = 0; s.pointee.choL = 0; s.pointee.choR = 0
        }
    }

    /// Array convenience for the aux-bus render.
    public func renderRange(_ left: inout [Float], _ right: inout [Float], reverbL: inout [Float], reverbR: inout [Float],
                            chorusL: inout [Float], chorusR: inout [Float]) {
        let n = [left.count, right.count, reverbL.count, reverbR.count, chorusL.count, chorusR.count].min()!
        left.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { r in
            reverbL.withUnsafeMutableBufferPointer { a in reverbR.withUnsafeMutableBufferPointer { b in
                chorusL.withUnsafeMutableBufferPointer { c in chorusR.withUnsafeMutableBufferPointer { d in
                    renderRange(l.baseAddress!, r.baseAddress!, reverbL: a.baseAddress!, reverbR: b.baseAddress!,
                                chorusL: c.baseAddress!, chorusR: d.baseAddress!, n)
                } }
            } }
        } }
    }

    /// gbk `renderScheduled` (AudioWorklet path): dispatches events whose frame <= renderedSamples.
    public func renderScheduled(_ outL: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>, _ count: Int,
                         _ events: UnsafePointer<EngineEvent>, _ eventCount: Int, _ startIndex: Int,
                         _ startRendered: Int) -> (eventIndex: Int, renderedSamples: Int) {
        var eventIndex = startIndex
        var rendered = startRendered
        let ccPanPos = st.pointee.spec ? 0 : (st.pointee.cc10 - 64) / 63
        let fx = st.pointee.spec && st.pointee.fxOn
        for i in 0 ..< count {
            while eventIndex < eventCount && events[eventIndex].frame <= rendered {
                dispatch(events[eventIndex])
                eventIndex += 1
            }
            var (l, r) = renderFrame(ccPanPos)
            if fx { let w = takeSends(); l += w.0; r += w.1 } else { clearSends() }
            (l, r) = applyMaster(l, r)
            outL[i] = Float(l)
            outR[i] = Float(r)
            rendered += 1
        }
        return (eventIndex, rendered)
    }
}
