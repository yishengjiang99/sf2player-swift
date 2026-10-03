// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

// Port of gbk src/sf2-renderer.ts `Sf2SynthEngine` (+ makeVoice, regionBaseRate, readSampleMono,
// balanceToGains). Voice order, polyphony stealing, choke groups, per-track state and the
// per-sample math follow the TS line by line. Storage is preallocated and pointer-based so
// `dispatch(_: EngineEvent)`, `renderRange` and `renderScheduled` are real-time safe: no
// allocation, locks, ARC or exclusivity checks.

/// Synth event (gbk `SynthEvent`). `regions` is used by `.setPreset`.
public struct SF2SynthEvent: @unchecked Sendable {
    public enum Kind: UInt8, Sendable { case noteOn, noteOff, setPreset, setControllers }
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
    public init() {}
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

    init(sr: Double) {
        volEnv = VolEnv(sr: sr); modEnv = ModEnv(sr: sr); modLfo = LFO(sr: sr); vibLfo = LFO(sr: sr); lpf = TwoPoleLPF(sr: sr)
    }
}

@inline(__always) private func readSampleMono(_ data: UnsafePointer<Float>, _ len: Int, _ pos: Double) -> Double {
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
        st = .allocate(capacity: 1)
        st.initialize(to: State(maxVoices: mv, capacity: cap, voices: voices, order: order, free: free, freeCount: cap,
                                tracks: tracks, store: store.hdr))
    }

    deinit {
        let s = st.pointee
        s.voices.deinitialize(count: s.capacity); s.voices.deallocate()
        s.order.deallocate(); s.free.deallocate()
        s.tracks.deinitialize(count: Self.maxTracks); s.tracks.deallocate()
        st.deinitialize(count: 1); st.deallocate()
    }

    // MARK: - gbk-shaped API (tests, offline)

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
    }

    public func setTrackRT(_ index: Int, _ t: TrackRT) {
        if index >= 0 && index < Self.maxTracks { st.pointee.tracks[index] = t }
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
            var track: UnsafeMutablePointer<TrackRT>?
            if msg.trackIndex >= 0 && Int(msg.trackIndex) < Self.maxTracks && s.pointee.tracks[Int(msg.trackIndex)].present {
                track = s.pointee.tracks + Int(msg.trackIndex)
            }
            let (base, count) = listRange(track?.pointee.list ?? s.pointee.globalList)
            guard let base, count > 0 else { return }
            var any = false
            for k in 0 ..< count {
                let r = base + k
                if note >= r.pointee.keyLo && note <= r.pointee.keyHi && velocity >= r.pointee.velLo && velocity <= r.pointee.velHi {
                    any = true
                    if r.pointee.exclusiveClass != 0 { chokeExclusive(r.pointee.exclusiveClass, trackIndex: msg.trackIndex) }
                }
            }
            if !any { return }
            var trackVolumeMul = 1.0, trackPanPos = 0.0
            if let t = track?.pointee {
                trackVolumeMul = (t.cc7 / 127) * (t.cc11 / 127) * t.gain
                trackPanPos = (t.cc10 - 64) / 63 + t.pan
            }
            for k in 0 ..< count {
                let r = base + k
                guard note >= r.pointee.keyLo && note <= r.pointee.keyHi && velocity >= r.pointee.velLo && velocity <= r.pointee.velHi
                else { continue }
                ensurePolyphony()
                guard s.pointee.freeCount > 0 else { continue }
                s.pointee.freeCount -= 1
                let slot = s.pointee.free[s.pointee.freeCount]
                makeVoice(s.pointee.voices + Int(slot), r, note: note, velocity: velocity,
                          channel: msg.channel >= 0 ? msg.channel : 0, trackIndex: msg.trackIndex,
                          trackPanPos: trackPanPos, trackVolumeMul: trackVolumeMul)
                s.pointee.order[s.pointee.count] = slot
                s.pointee.count += 1
            }

        case SF2SynthEvent.Kind.noteOff.rawValue:
            let note = msg.note
            for i in 0 ..< s.pointee.count {
                let v = s.pointee.voices + Int(s.pointee.order[i])
                let sameTrack = msg.trackIndex < 0 || v.pointee.trackIndex == msg.trackIndex
                let sameChannel = msg.channel < 0 || v.pointee.channel == msg.channel
                if v.pointee.note == note && sameTrack && sameChannel {
                    v.pointee.volEnv.noteOff(); v.pointee.modEnv.noteOff()
                    if v.pointee.loopUntilReleaseThenTail { v.pointee.inReleaseTail = true }
                }
            }

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
                return
            }
            if msg.cc7.isFinite { s.pointee.cc7 = cc(msg.cc7) }
            if msg.cc10.isFinite { s.pointee.cc10 = cc(msg.cc10) }
            if msg.cc11.isFinite { s.pointee.cc11 = cc(msg.cc11) }

        default:
            break
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
                           channel: Int32, trackIndex: Int32, trackPanPos: Double, trackVolumeMul: Double) {
        let reg = r.pointee
        let sr = outSr
        var voice = Voice(sr: sr)
        voice.note = Int32(truncatingIfNeeded: note); voice.channel = channel; voice.trackIndex = trackIndex
        voice.velocity = Int32(truncatingIfNeeded: velocity)
        voice.start = Double(reg.start); voice.end = Double(reg.end)
        voice.loopStart = Double(reg.loopStart); voice.loopEnd = Double(reg.loopEnd)
        voice.pos = voice.start
        voice.looping = reg.sampleModes == 1 || reg.sampleModes == 3
        voice.loopUntilReleaseThenTail = reg.sampleModes == 3
        // regionBaseRate
        let keyTrackCents = Double((note - reg.root) * reg.scaleTuning)
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
        voice.volEnv.noteOn()
        voice.modEnv.noteOn()
        v.pointee = voice
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
        if v.pointee.pos >= v.pointee.end { v.pointee.finished = true }
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
            let needModLfo = v.pointee.modToPitch != 0 || v.pointee.modLfoToFc != 0
            let modLfo = needModLfo ? v.pointee.modLfo.next() : 0
            let vibLfo = v.pointee.vibToPitch != 0 ? v.pointee.vibLfo.next() : 0
            let pitchCents = vibLfo * v.pointee.vibToPitch + modLfo * v.pointee.modToPitch
            v.pointee.rate = pitchCents == 0 ? v.pointee.baseRate : v.pointee.baseRate * centsToRatio(pitchCents)

            let sL = readSampleMono(v.pointee.dataL!, v.pointee.lenL, v.pointee.pos)
            let sR = v.pointee.dataR != nil ? readSampleMono(v.pointee.dataR!, v.pointee.lenR, v.pointee.pos) : sL

            let fcCents = v.pointee.initialFc + modEnv * v.pointee.modEnvToFc + modLfo * v.pointee.modLfoToFc
            if fcCents != v.pointee.lastFc {
                v.pointee.lpf.setCutoffHz(fcCentsToHz(fcCents))
                v.pointee.lastFc = fcCents
            }
            let fL = v.pointee.lpf.processL(sL)
            let fR = v.pointee.lpf.processR(sR)
            let env = v.pointee.volEnv.next()
            let gain = v.pointee.baseGain * env * v.pointee.trackVolumeMul
            let mixPan = max(-1, min(1, v.pointee.regionPanPos + (v.pointee.trackIndex < 0 ? ccPanPos : v.pointee.trackPanPos)))
            if mixPan != v.pointee.lastMixPan {
                let angle = (mixPan + 1) * 0.25 * Double.pi
                v.pointee.gL = cos(angle)
                v.pointee.gR = sin(angle)
                v.pointee.lastMixPan = mixPan
            }
            sumL += fL * gain * v.pointee.gL
            sumR += fR * gain * v.pointee.gR
            advancePos(v)
            vi -= 1
        }
        return (sumL, sumR)
    }

    /// gbk `renderRange`: overwrites `count` frames.
    public func renderRange(_ outL: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>, _ count: Int) {
        let ccPanPos = (st.pointee.cc10 - 64) / 63
        for i in 0 ..< count {
            let (l, r) = renderFrame(ccPanPos)
            outL[i] = Float(l)
            outR[i] = Float(r)
        }
    }

    /// gbk `renderScheduled` (AudioWorklet path): dispatches events whose frame <= renderedSamples.
    public func renderScheduled(_ outL: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>, _ count: Int,
                         _ events: UnsafePointer<EngineEvent>, _ eventCount: Int, _ startIndex: Int,
                         _ startRendered: Int) -> (eventIndex: Int, renderedSamples: Int) {
        var eventIndex = startIndex
        var rendered = startRendered
        let ccPanPos = (st.pointee.cc10 - 64) / 63
        for i in 0 ..< count {
            while eventIndex < eventCount && events[eventIndex].frame <= rendered {
                dispatch(events[eventIndex])
                eventIndex += 1
            }
            let (l, r) = renderFrame(ccPanPos)
            outL[i] = Float(l)
            outR[i] = Float(r)
            rendered += 1
        }
        return (eventIndex, rendered)
    }
}
