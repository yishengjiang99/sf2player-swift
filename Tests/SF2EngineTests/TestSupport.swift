// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import XCTest
@testable import SF2Engine

enum TestPaths {
    /// <repo> (this file is <repo>/Tests/SF2EngineTests/TestSupport.swift).
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// GeneralUser-GS.sf2: $SF2PLAYER_SF2, else <repo>/models (scripts/fetch-soundfont), else $OMR_MODELS_DIR.
    static var soundFontURL: URL? {
        let env = ProcessInfo.processInfo.environment
        var candidates: [URL] = []
        if let p = env["SF2PLAYER_SF2"] { candidates.append(URL(fileURLWithPath: p)) }
        candidates.append(repoRoot.appendingPathComponent("models/GeneralUser-GS.sf2"))
        if let d = env["OMR_MODELS_DIR"] { candidates.append(URL(fileURLWithPath: d).appendingPathComponent("GeneralUser-GS.sf2")) }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// Parses GeneralUser-GS once per test process.
enum SharedSoundFont {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: SF2SoundFont?

    static func get() throws -> SF2SoundFont {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        guard let url = TestPaths.soundFontURL else {
            throw XCTSkip("GeneralUser-GS.sf2 not found: run scripts/fetch-soundfont or set SF2PLAYER_SF2")
        }
        let sf = try SF2SoundFont(contentsOf: url)
        cached = sf
        return sf
    }
}

/// gbk sf2-synth-engine.test.ts makeRegion(): 1 s of constant 0.5 at 44.1 kHz, looping, instant envelopes.
func makeRegion(keyRange: (Int, Int) = (0, 127), velRange: (Int, Int) = (0, 127), sample: SF2SampleData? = nil,
                sampleModes: Int = 1, exclusiveClass: Int = 0) -> SF2Region {
    let sr = 44100
    let len = sr
    let data = SF2SampleBuffer([Float](repeating: 0.5, count: len))
    return SF2Region(
        keyRange: keyRange, velRange: velRange,
        sample: sample ?? SF2SampleData(dataL: data, dataR: nil, sampleRate: sr, start: 0, end: len, loopStart: 0, loopEnd: len),
        sampleModes: sampleModes, originalKey: 60, overridingRootKey: nil, coarseTune: 0, fineTune: 0, scaleTuning: 100,
        initialAttenuationCb: 0, pan: 0,
        volEnv: SF2VolEnv(delayTc: -32768, attackTc: -32768, holdTc: -12000, decayTc: -32768, sustainCb: 0, releaseTc: -12000),
        modEnv: SF2ModEnv(delayTc: -32768, attackTc: -32768, holdTc: -12000, decayTc: -32768, sustain: 0, releaseTc: -12000),
        initialFilterFcCents: 13500, initialFilterQCb: 0, modEnvToFilterFcCents: 0, modLfoToFilterFcCents: 0,
        modLfoDelayTc: -32768, modLfoFreqCents: 0, modLfoToPitchCents: 0, vibLfoDelayTc: -32768, vibLfoFreqCents: 0,
        vibLfoToPitchCents: 0, exclusiveClass: exclusiveClass)
}
