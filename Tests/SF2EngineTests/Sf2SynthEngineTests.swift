// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import SF2Engine

/// Port of gbk test/sf2-synth-engine.test.ts (same 18 cases, same order).
final class Sf2SynthEngineTests: XCTestCase {
    // Constructor / configuration

    func testConstructsWithDefaultState() {
        let engine = Sf2SynthEngine(outSr: 44100)
        XCTAssertEqual(engine.outSr, 44100)
        XCTAssertEqual(engine.voiceCount, 0)
        XCTAssertEqual(engine.regions.count, 0)
        XCTAssertEqual(engine.maxVoices, 64)
        XCTAssertEqual(engine.cc7Volume, 100)
        XCTAssertEqual(engine.cc10Pan, 64)
        XCTAssertEqual(engine.cc11Expression, 127)
    }

    func testSetMaxVoicesEnforcesMinimumOfOne() {
        let engine = Sf2SynthEngine(outSr: 44100)
        engine.setMaxVoices(0)
        XCTAssertEqual(engine.maxVoices, 1)
        engine.setMaxVoices(32)
        XCTAssertEqual(engine.maxVoices, 32)
    }

    // setPreset

    func testSetPresetReplacesGlobalRegionsAndClearsVoices() {
        let engine = Sf2SynthEngine(outSr: 44100)
        let region = makeRegion()
        engine.dispatchEvent(.noteOn(60, velocity: 100))
        engine.regions = [region]
        engine.dispatchEvent(.setPreset(SF2RegionList([])))
        XCTAssertEqual(engine.regions.count, 0)
        XCTAssertEqual(engine.voiceCount, 0)
    }

    func testSetPresetWithValidRegionsStoresThem() {
        let engine = Sf2SynthEngine(outSr: 44100)
        engine.dispatchEvent(.setPreset(SF2RegionList([makeRegion()])))
        XCTAssertEqual(engine.regions.count, 1)
    }

    // pickRegions

    func testPickRegionsReturnsMatchingRegionsForNoteAndVelocity() {
        let engine = Sf2SynthEngine(outSr: 44100)
        let r1 = makeRegion(keyRange: (60, 72), velRange: (64, 127))
        let r2 = makeRegion(keyRange: (0, 59), velRange: (0, 127))
        engine.regions = [r1, r2]
        XCTAssertEqual(engine.pickRegions(note: 64, velocity: 100), [r1])
        XCTAssertEqual(engine.pickRegions(note: 40, velocity: 80), [r2])
        XCTAssertEqual(engine.pickRegions(note: 64, velocity: 40), [])
    }

    func testPickRegionsReturnsEmptyWhenNoRegionsLoaded() {
        let engine = Sf2SynthEngine(outSr: 44100)
        XCTAssertEqual(engine.pickRegions(note: 60, velocity: 100), [])
    }

    // noteOn / noteOff / voice management

    func testNoteOnWithNoMatchingRegionsCreatesNoVoices() {
        let engine = Sf2SynthEngine(outSr: 44100)
        engine.dispatchEvent(.noteOn(60, velocity: 100))
        XCTAssertEqual(engine.voiceCount, 0)
    }

    func testNoteOnCreatesAVoiceForAMatchingRegion() {
        let engine = Sf2SynthEngine(outSr: 44100)
        engine.dispatchEvent(.setPreset(SF2RegionList([makeRegion()])))
        engine.dispatchEvent(.noteOn(60, velocity: 100))
        XCTAssertEqual(engine.voiceCount, 1)
        XCTAssertEqual(engine.voices[0].note, 60)
        XCTAssertEqual(engine.voices[0].velocity, 100)
    }

    func testNoteOffPutsMatchingVoiceIntoRelease() {
        let engine = Sf2SynthEngine(outSr: 44100)
        engine.dispatchEvent(.setPreset(SF2RegionList([makeRegion()])))
        engine.dispatchEvent(.noteOn(60, velocity: 100))
        XCTAssertEqual(engine.voiceCount, 1)
        engine.dispatchEvent(.noteOff(60))
        XCTAssertEqual(engine.voices[0].volEnvStage, .release)
    }

    func testNoteOffDoesNotAffectVoicesForDifferentNotes() {
        let engine = Sf2SynthEngine(outSr: 44100)
        engine.dispatchEvent(.setPreset(SF2RegionList([makeRegion()])))
        engine.dispatchEvent(.noteOn(60, velocity: 100))
        engine.dispatchEvent(.noteOff(64))
        XCTAssertNotEqual(engine.voices[0].volEnvStage, .release)
    }

    // Polyphony limiting

    func testEnsurePolyphonyDropsQuietestVoiceWhenMaxVoicesIsReached() {
        let engine = Sf2SynthEngine(outSr: 44100, maxVoices: 2)
        engine.dispatchEvent(.setPreset(SF2RegionList([makeRegion()])))
        engine.dispatchEvent(.noteOn(60, velocity: 100))
        engine.dispatchEvent(.noteOn(62, velocity: 100))
        XCTAssertEqual(engine.voiceCount, 2)
        engine.dispatchEvent(.noteOn(64, velocity: 100))
        XCTAssertEqual(engine.voiceCount, 2)
    }

    // setControllers

    func testSetControllersUpdatesGlobalCCs() {
        let engine = Sf2SynthEngine(outSr: 44100)
        engine.dispatchEvent(.setControllers(cc7Volume: 80, cc10Pan: 80, cc11Expression: 90))
        XCTAssertEqual(engine.cc7Volume, 80)
        XCTAssertEqual(engine.cc10Pan, 80)
        XCTAssertEqual(engine.cc11Expression, 90)
    }

    func testSetControllersClampsCCValuesTo0Through127() {
        let engine = Sf2SynthEngine(outSr: 44100)
        engine.dispatchEvent(.setControllers(cc7Volume: 200, cc10Pan: -5))
        XCTAssertEqual(engine.cc7Volume, 127)
        XCTAssertEqual(engine.cc10Pan, 0)
    }

    // Track-based state

    func testSetTrackStatesStoresPerTrackRegionsAndParameters() {
        let engine = Sf2SynthEngine(outSr: 44100)
        engine.setTrackStates([
            SF2TrackState(trackIndex: 0, regions: SF2RegionList([makeRegion()]), cc7Volume: 90, cc10Pan: 32, cc11Expression: 100, pan: 0.5, gain: 0.8),
        ])
        XCTAssertEqual(engine.trackStates.count, 1)
        let ts = engine.trackStates[0]!
        XCTAssertEqual(ts.cc7Volume, 90)
        XCTAssertEqual(ts.cc10Pan, 32)
        XCTAssertEqual(ts.gain, 0.8)
        XCTAssertEqual(ts.regionCount, 1)
    }

    func testSetTrackStatesClearsActiveVoices() {
        let engine = Sf2SynthEngine(outSr: 44100)
        engine.dispatchEvent(.setPreset(SF2RegionList([makeRegion()])))
        engine.dispatchEvent(.noteOn(60, velocity: 100))
        XCTAssertEqual(engine.voiceCount, 1)
        engine.setTrackStates([])
        XCTAssertEqual(engine.voiceCount, 0)
    }

    // renderRange produces audio

    func testRenderRangeFillsSilenceWhenNoVoicesAreActive() {
        let engine = Sf2SynthEngine(outSr: 44100)
        var l = [Float](repeating: 1, count: 128), r = [Float](repeating: 1, count: 128)
        engine.renderRange(&l, &r)
        XCTAssertTrue(l.allSatisfy { $0 == 0 }, "outL should be silent with no voices")
        XCTAssertTrue(r.allSatisfy { $0 == 0 }, "outR should be silent with no voices")
    }

    func testRenderRangeProducesNonZeroOutputAfterNoteOn() {
        let engine = Sf2SynthEngine(outSr: 44100)
        engine.dispatchEvent(.setPreset(SF2RegionList([makeRegion()])))
        engine.dispatchEvent(.noteOn(60, velocity: 127))
        var l = [Float](repeating: 0, count: 256), r = [Float](repeating: 0, count: 256)
        engine.renderRange(&l, &r)
        XCTAssertTrue(l.contains { abs($0) > 1e-6 }, "renderRange should produce non-zero audio after noteOn")
    }

    func testRenderRangeRemovesFinishedVoicesAfterSamplePlaybackEnds() {
        let sr = 44100
        let shortLen = 32
        let data = SF2SampleBuffer([Float](repeating: 0.5, count: shortLen))
        let region = makeRegion(sample: SF2SampleData(dataL: data, dataR: nil, sampleRate: sr, start: 0, end: shortLen, loopStart: 0, loopEnd: shortLen),
                                sampleModes: 0)
        let engine = Sf2SynthEngine(outSr: Double(sr))
        engine.dispatchEvent(.setPreset(SF2RegionList([region])))
        engine.dispatchEvent(.noteOn(60, velocity: 127))
        XCTAssertEqual(engine.voiceCount, 1)
        var l = [Float](repeating: 0, count: sr), r = [Float](repeating: 0, count: sr)
        engine.renderRange(&l, &r)
        XCTAssertEqual(engine.voiceCount, 0)
    }

    // exclusive class (choke groups)

    func testChokeExclusiveReleasesVoicesWithTheSameExclusiveClass() {
        let engine = Sf2SynthEngine(outSr: 44100)
        engine.dispatchEvent(.setPreset(SF2RegionList([makeRegion(exclusiveClass: 1)])))
        engine.dispatchEvent(.noteOn(60, velocity: 100))
        XCTAssertEqual(engine.voiceCount, 1)
        engine.dispatchEvent(.noteOn(62, velocity: 100))
        XCTAssertEqual(engine.voices[0].volEnvStage, .release)
    }
}

/// Extra engine checks beyond the gbk suite (pool reuse, renderScheduled == offline, track pan/volume).
final class Sf2SynthEngineExtraTests: XCTestCase {
    func testVoicePoolReusesSlotsWithoutGrowing() {
        let engine = Sf2SynthEngine(outSr: 44100, maxVoices: 4)
        engine.dispatchEvent(.setPreset(SF2RegionList([makeRegion()])))
        for n in 0 ..< 100 { engine.dispatchEvent(.noteOn(40 + n % 40, velocity: 100)) }
        XCTAssertEqual(engine.voiceCount, 4)
        XCTAssertEqual(engine.voiceCapacity, 4)
    }

    func testPolyphonyStealsTheQuietestVoiceFirstInOrder() {
        let engine = Sf2SynthEngine(outSr: 44100, maxVoices: 2)
        engine.dispatchEvent(.setPreset(SF2RegionList([makeRegion()])))
        engine.dispatchEvent(.noteOn(60, velocity: 100))
        engine.dispatchEvent(.noteOn(62, velocity: 20))
        var l = [Float](repeating: 0, count: 64), r = l
        engine.renderRange(&l, &r) // levels > 0, note 62 quieter
        engine.dispatchEvent(.noteOn(64, velocity: 100))
        XCTAssertEqual(engine.voices.map(\.note), [60, 64])
    }

    func testRenderScheduledMatchesOfflineRender() {
        let list = SF2RegionList([makeRegion()])
        let tracks = [SF2TrackState(trackIndex: 0, regions: list, cc7Volume: 100, cc10Pan: 64, cc11Expression: 127, pan: 0, gain: 1)]
        let events: [SF2SynthEvent] = [
            .noteOn(60, velocity: 100, frame: 10, seq: 0, trackIndex: 0, channel: 0),
            .noteOn(67, velocity: 90, frame: 300, seq: 1, trackIndex: 0, channel: 0),
            .noteOff(60, frame: 700, seq: 2, trackIndex: 0, channel: 0),
            .noteOff(67, frame: 1500, seq: 3, trackIndex: 0, channel: 0),
        ]
        let offline = SF2OfflineRenderer.renderOfflineSequence(sampleRate: 44100, length: 6000, tracks: tracks, events: events)
        let engine = Sf2SynthEngine(outSr: 44100)
        engine.setTrackStates(tracks)
        var l = [Float](), r = [Float]()
        var idx = 0, rendered = 0
        while rendered < 6000 {
            var bl = [Float](repeating: 0, count: 128), br = bl
            (idx, rendered) = engine.renderScheduled(&bl, &br, events: events, eventIndex: idx, renderedSamples: rendered)
            l += bl; r += br
        }
        XCTAssertEqual(Array(l.prefix(6000)), offline.left)
        XCTAssertEqual(Array(r.prefix(6000)), offline.right)
    }

    func testTrackPanAndVolumeShapeOutput() {
        let list = SF2RegionList([makeRegion()])
        let tracks = [SF2TrackState(trackIndex: 0, regions: list, cc7Volume: 127, cc10Pan: 0, cc11Expression: 127, pan: 0, gain: 1)]
        let out = SF2OfflineRenderer.renderOfflineSequence(sampleRate: 44100, length: 2000, tracks: tracks,
                                                          events: [.noteOn(60, velocity: 127, frame: 0, trackIndex: 0, channel: 0)])
        // hard-left pan: right channel ~ cos(pi/2) ~ 0
        XCTAssertGreaterThan(abs(out.left[1500]), 0.1)
        XCTAssertLessThan(abs(out.right[1500]), 1e-6)
    }
}
