// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Immutable Float32 sample storage with a stable pointer (the render thread reads it without ARC).
public final class SF2SampleBuffer: @unchecked Sendable {
    public let count: Int
    let mutablePointer: UnsafeMutablePointer<Float>
    public var pointer: UnsafePointer<Float> { UnsafePointer(mutablePointer) }

    init(count: Int) {
        self.count = count
        mutablePointer = .allocate(capacity: max(1, count))
        mutablePointer.initialize(repeating: 0, count: max(1, count))
    }

    public convenience init(_ values: [Float]) {
        self.init(count: values.count)
        values.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { mutablePointer.update(from: base, count: values.count) }
        }
    }

    public subscript(i: Int) -> Float { mutablePointer[i] }
    public var array: [Float] { Array(UnsafeBufferPointer(start: mutablePointer, count: count)) }

    deinit { mutablePointer.deallocate() }
}

public struct SF2SampleData: Equatable, @unchecked Sendable {
    public var dataL: SF2SampleBuffer
    public var dataR: SF2SampleBuffer?
    public var sampleRate: Int
    public var start: Int
    public var end: Int
    public var loopStart: Int
    public var loopEnd: Int

    public init(dataL: SF2SampleBuffer, dataR: SF2SampleBuffer? = nil, sampleRate: Int, start: Int, end: Int, loopStart: Int, loopEnd: Int) {
        self.dataL = dataL; self.dataR = dataR; self.sampleRate = sampleRate
        self.start = start; self.end = end; self.loopStart = loopStart; self.loopEnd = loopEnd
    }

    public static func == (a: SF2SampleData, b: SF2SampleData) -> Bool {
        a.dataL === b.dataL && a.dataR === b.dataR && a.sampleRate == b.sampleRate && a.start == b.start
            && a.end == b.end && a.loopStart == b.loopStart && a.loopEnd == b.loopEnd
    }
}

public struct SF2VolEnv: Equatable, Sendable {
    public var delayTc, attackTc, holdTc, decayTc, sustainCb, releaseTc: Int
    public init(delayTc: Int = -12000, attackTc: Int = -12000, holdTc: Int = -12000, decayTc: Int = -12000, sustainCb: Int = 0, releaseTc: Int = -12000) {
        self.delayTc = delayTc; self.attackTc = attackTc; self.holdTc = holdTc
        self.decayTc = decayTc; self.sustainCb = sustainCb; self.releaseTc = releaseTc
    }
}

public struct SF2ModEnv: Equatable, Sendable {
    public var delayTc, attackTc, holdTc, decayTc: Int
    /// 0..1 (gbk: sustainModEnv / 1000, clamped).
    public var sustain: Double
    public var releaseTc: Int
    public init(delayTc: Int = -12000, attackTc: Int = -12000, holdTc: Int = -12000, decayTc: Int = -12000, sustain: Double = 0, releaseTc: Int = -12000) {
        self.delayTc = delayTc; self.attackTc = attackTc; self.holdTc = holdTc
        self.decayTc = decayTc; self.sustain = sustain; self.releaseTc = releaseTc
    }
}

/// gbk `SF2Region`: one playable (preset zone x instrument zone) with merged generators.
public struct SF2Region: Equatable, @unchecked Sendable {
    public var keyRange: (Int, Int)
    public var velRange: (Int, Int)
    public var sample: SF2SampleData
    public var sampleModes: Int
    public var originalKey: Int
    public var overridingRootKey: Int?
    public var coarseTune: Int
    public var fineTune: Int
    public var scaleTuning: Int
    public var initialAttenuationCb: Int
    public var pan: Int
    public var volEnv: SF2VolEnv
    public var modEnv: SF2ModEnv
    public var initialFilterFcCents: Int
    public var initialFilterQCb: Int
    public var modEnvToFilterFcCents: Int
    public var modLfoToFilterFcCents: Int
    public var modLfoDelayTc: Int
    public var modLfoFreqCents: Int
    public var modLfoToPitchCents: Int
    public var vibLfoDelayTc: Int
    public var vibLfoFreqCents: Int
    public var vibLfoToPitchCents: Int
    public var exclusiveClass: Int

    public init(keyRange: (Int, Int) = (0, 127), velRange: (Int, Int) = (0, 127), sample: SF2SampleData, sampleModes: Int = 0,
                originalKey: Int = 60, overridingRootKey: Int? = nil, coarseTune: Int = 0, fineTune: Int = 0, scaleTuning: Int = 100,
                initialAttenuationCb: Int = 0, pan: Int = 0, volEnv: SF2VolEnv = SF2VolEnv(), modEnv: SF2ModEnv = SF2ModEnv(),
                initialFilterFcCents: Int = 13500, initialFilterQCb: Int = 0, modEnvToFilterFcCents: Int = 0,
                modLfoToFilterFcCents: Int = 0, modLfoDelayTc: Int = -12000, modLfoFreqCents: Int = 0, modLfoToPitchCents: Int = 0,
                vibLfoDelayTc: Int = -12000, vibLfoFreqCents: Int = 0, vibLfoToPitchCents: Int = 0, exclusiveClass: Int = 0) {
        self.keyRange = keyRange; self.velRange = velRange; self.sample = sample; self.sampleModes = sampleModes
        self.originalKey = originalKey; self.overridingRootKey = overridingRootKey; self.coarseTune = coarseTune
        self.fineTune = fineTune; self.scaleTuning = scaleTuning; self.initialAttenuationCb = initialAttenuationCb
        self.pan = pan; self.volEnv = volEnv; self.modEnv = modEnv; self.initialFilterFcCents = initialFilterFcCents
        self.initialFilterQCb = initialFilterQCb; self.modEnvToFilterFcCents = modEnvToFilterFcCents
        self.modLfoToFilterFcCents = modLfoToFilterFcCents; self.modLfoDelayTc = modLfoDelayTc
        self.modLfoFreqCents = modLfoFreqCents; self.modLfoToPitchCents = modLfoToPitchCents
        self.vibLfoDelayTc = vibLfoDelayTc; self.vibLfoFreqCents = vibLfoFreqCents
        self.vibLfoToPitchCents = vibLfoToPitchCents; self.exclusiveClass = exclusiveClass
    }

    public static func == (a: SF2Region, b: SF2Region) -> Bool {
        a.keyRange == b.keyRange && a.velRange == b.velRange && a.sample == b.sample && a.sampleModes == b.sampleModes
            && a.originalKey == b.originalKey && a.overridingRootKey == b.overridingRootKey && a.coarseTune == b.coarseTune
            && a.fineTune == b.fineTune && a.scaleTuning == b.scaleTuning && a.initialAttenuationCb == b.initialAttenuationCb
            && a.pan == b.pan && a.volEnv == b.volEnv && a.modEnv == b.modEnv && a.initialFilterFcCents == b.initialFilterFcCents
            && a.initialFilterQCb == b.initialFilterQCb && a.modEnvToFilterFcCents == b.modEnvToFilterFcCents
            && a.modLfoToFilterFcCents == b.modLfoToFilterFcCents && a.modLfoDelayTc == b.modLfoDelayTc
            && a.modLfoFreqCents == b.modLfoFreqCents && a.modLfoToPitchCents == b.modLfoToPitchCents
            && a.vibLfoDelayTc == b.vibLfoDelayTc && a.vibLfoFreqCents == b.vibLfoFreqCents
            && a.vibLfoToPitchCents == b.vibLfoToPitchCents && a.exclusiveClass == b.exclusiveClass
    }
}

/// A preset's region array with identity (dedupes region lists in sequences / region stores).
public final class SF2RegionList: @unchecked Sendable {
    public let regions: [SF2Region]
    public init(_ regions: [SF2Region]) { self.regions = regions }
    public var count: Int { regions.count }
}
