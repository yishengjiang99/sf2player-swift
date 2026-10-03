// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Flat, pointer-addressed copy of the region parameters the synth needs (no references, so the
/// render thread can copy it into a voice without ARC traffic).
struct VoiceRegion {
    var keyLo: Int, keyHi: Int, velLo: Int, velHi: Int
    var dataL: UnsafePointer<Float>, lenL: Int
    var dataR: UnsafePointer<Float>?, lenR: Int
    var sampleRate: Int
    var start: Int, end: Int, loopStart: Int, loopEnd: Int
    var sampleModes: Int
    var root: Int
    var scaleTuning: Int, coarseTune: Int, fineTune: Int
    var initialAttenuationCb: Int
    var pan: Int
    var volEnv: SF2VolEnv
    var modEnv: SF2ModEnv
    var initialFilterFcCents: Int, modEnvToFilterFcCents: Int, modLfoToFilterFcCents: Int
    var modLfoDelayTc: Int, modLfoFreqCents: Int, modLfoToPitchCents: Int
    var vibLfoDelayTc: Int, vibLfoFreqCents: Int, vibLfoToPitchCents: Int
    var exclusiveClass: Int

    init(_ r: SF2Region) {
        keyLo = r.keyRange.0; keyHi = r.keyRange.1; velLo = r.velRange.0; velHi = r.velRange.1
        dataL = r.sample.dataL.pointer; lenL = r.sample.dataL.count
        dataR = r.sample.dataR?.pointer; lenR = r.sample.dataR?.count ?? 0
        sampleRate = r.sample.sampleRate
        start = r.sample.start; end = r.sample.end; loopStart = r.sample.loopStart; loopEnd = r.sample.loopEnd
        sampleModes = r.sampleModes
        root = r.overridingRootKey ?? r.originalKey
        scaleTuning = r.scaleTuning; coarseTune = r.coarseTune; fineTune = r.fineTune
        initialAttenuationCb = r.initialAttenuationCb
        pan = r.pan
        volEnv = r.volEnv; modEnv = r.modEnv
        initialFilterFcCents = r.initialFilterFcCents; modEnvToFilterFcCents = r.modEnvToFilterFcCents
        modLfoToFilterFcCents = r.modLfoToFilterFcCents
        modLfoDelayTc = r.modLfoDelayTc; modLfoFreqCents = r.modLfoFreqCents; modLfoToPitchCents = r.modLfoToPitchCents
        vibLfoDelayTc = r.vibLfoDelayTc; vibLfoFreqCents = r.vibLfoFreqCents; vibLfoToPitchCents = r.vibLfoToPitchCents
        exclusiveClass = r.exclusiveClass
    }
}

/// Region lists addressed by Int32 id (-1 = the empty list). Append-only; appends reallocate, so
/// only append while no render thread reads the store (the real-time player builds one store per
/// sequence up front and never mutates it afterwards).
public final class SF2RegionStore: @unchecked Sendable {
    struct ListRange { var start: Int; var count: Int }
    /// Opaque real-time view of the store (players swap it between songs via `Sf2SynthEngine.setStoreRT`).
    public struct Header {
        var regions: UnsafeMutablePointer<VoiceRegion>?
        var regionCount = 0, regionCapacity = 0
        var lists: UnsafeMutablePointer<ListRange>?
        var listCount = 0, listCapacity = 0
    }

    public let hdr: UnsafeMutablePointer<Header>
    private var retainedLists: [SF2RegionList] = []
    private var ids: [ObjectIdentifier: Int32] = [:]

    public init() {
        hdr = .allocate(capacity: 1)
        hdr.initialize(to: Header())
    }

    deinit {
        hdr.pointee.regions?.deallocate()
        hdr.pointee.lists?.deallocate()
        hdr.deallocate()
    }

    public var listCount: Int { hdr.pointee.listCount }

    /// Adds (or returns the existing id of) a region list. Retains its sample buffers.
    @discardableResult
    public func add(_ list: SF2RegionList) -> Int32 {
        if let id = ids[ObjectIdentifier(list)] { return id }
        var h = hdr.pointee
        if h.regionCount + list.count > h.regionCapacity {
            let cap = max(64, max(h.regionCount + list.count, h.regionCapacity * 2))
            let p = UnsafeMutablePointer<VoiceRegion>.allocate(capacity: cap)
            if let old = h.regions { p.moveInitialize(from: old, count: h.regionCount); old.deallocate() }
            h.regions = p; h.regionCapacity = cap
        }
        if h.listCount + 1 > h.listCapacity {
            let cap = max(16, h.listCapacity * 2)
            let p = UnsafeMutablePointer<ListRange>.allocate(capacity: cap)
            if let old = h.lists { p.moveInitialize(from: old, count: h.listCount); old.deallocate() }
            h.lists = p; h.listCapacity = cap
        }
        for (i, r) in list.regions.enumerated() { (h.regions! + h.regionCount + i).initialize(to: VoiceRegion(r)) }
        (h.lists! + h.listCount).initialize(to: ListRange(start: h.regionCount, count: list.count))
        let id = Int32(h.listCount)
        h.regionCount += list.count
        h.listCount += 1
        hdr.pointee = h
        retainedLists.append(list)
        ids[ObjectIdentifier(list)] = id
        return id
    }

    public func regions(of id: Int32) -> [SF2Region] {
        id >= 0 && Int(id) < retainedLists.count ? retainedLists[Int(id)].regions : []
    }
}
