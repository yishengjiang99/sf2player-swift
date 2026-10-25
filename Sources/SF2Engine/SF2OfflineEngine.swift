// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

// gbk src/sf2-renderer.ts renderOfflineSequenceToAudioBuffer: tracks + events -> stereo PCM.

public enum SF2EventOrder {
    /// renderOfflineSequenceToAudioBuffer's event order: (frame ?? 0, seq ?? 0, trackIndex ?? 0), stable.
    public static func sorted(_ events: [SF2SynthEvent]) -> [SF2SynthEvent] {
        events.enumerated().sorted { x, y in
            let a = x.element, b = y.element
            let fa = a.frame ?? 0, fb = b.frame ?? 0
            if fa != fb { return fa < fb }
            if a.seq != b.seq { return a.seq < b.seq }
            let ta = a.trackIndex ?? 0, tb = b.trackIndex ?? 0
            if ta != tb { return ta < tb }
            return x.offset < y.offset
        }.map(\.element)
    }
}

public struct SF2StereoBuffer: Sendable {
    public var sampleRate: Double
    public var left: [Float]
    public var right: [Float]
    public var length: Int { left.count }
}

public enum SF2OfflineRenderer {
    /// Port of gbk `renderOfflineSequenceToAudioBuffer`.
    public static func renderOfflineSequence(sampleRate: Double, length: Int, tracks: [SF2TrackState], events: [SF2SynthEvent],
                                             maxVoices: Int = 64, fidelity: SF2Fidelity = .spec,
                                             masterDynamicsEnabled: Bool = true, masterGainDb: Double = -3) -> SF2StereoBuffer {
        var left = [Float](repeating: 0, count: length)
        var right = [Float](repeating: 0, count: length)
        let engine = Sf2SynthEngine(outSr: sampleRate, maxVoices: maxVoices)
        engine.fidelity = fidelity
        engine.masterDynamicsEnabled = masterDynamicsEnabled
        engine.masterGainDb = masterGainDb
        engine.setTrackStates(tracks)
        let sorted = SF2EventOrder.sorted(events)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                var cursor = 0
                for e in sorted {
                    let frame = max(0, min(length, Int(Int32(truncatingIfNeeded: e.frame ?? 0))))
                    if frame > cursor {
                        engine.renderRange(l.baseAddress! + cursor, r.baseAddress! + cursor, frame - cursor)
                        cursor = frame
                    }
                    engine.dispatchEvent(e)
                }
                if cursor < length { engine.renderRange(l.baseAddress! + cursor, r.baseAddress! + cursor, length - cursor) }
            }
        }
        return SF2StereoBuffer(sampleRate: sampleRate, left: left, right: right)
    }
}

extension SF2OfflineRenderer {
    public struct SongRender: Sendable {
        public var buffer: SF2StereoBuffer
        /// Frames up to the last event (the music); the rest of the buffer is the release / effects tail.
        public var musicFrames: Int
        public var loudness: SF2LoudnessReport
    }

    /// gbk offline export semantics (gbk c728c6c, 6c9eafc): the render ends at the last event (note-off, CC...) plus
    /// `tailSeconds`, so release and reverb tails are kept, and ONE whole-file gain is applied afterwards (default
    /// `.off`; gbk exports use `.gbkDefault`, -16 LUFS integrated capped at -1 dBTP).
    public static func renderSong(sampleRate: Double, tracks: [SF2TrackState], events: [SF2SynthEvent], tailSeconds: Double = 3,
                                  maxVoices: Int = 64, normalize: SF2Normalize = .off, channels: Int = 2,
                                  configure: ((Sf2SynthEngine) -> Void)? = nil) -> SongRender {
        let tail = max(0, min(30, tailSeconds.isFinite ? tailSeconds : 3))
        let music = events.reduce(0) { max($0, max(0, Int(Int32(truncatingIfNeeded: $1.frame ?? 0)))) }
        let length = music + Int((tail * sampleRate).rounded(.toNearestOrAwayFromZero))
        var buf = render(sampleRate: sampleRate, length: length, tracks: tracks, events: events, maxVoices: maxVoices, configure: configure)
        let meter = SF2LoudnessMeter(sampleRate: sampleRate, channels: channels)
        meter.push(buf.left, buf.right)
        let report = SF2LoudnessReport.choose(normalize, meter.result(), meter: normalize == .off ? nil : meter)
        if report.gainLinear != 1 {
            let g = report.gainLinear
            for i in 0 ..< buf.length { buf.left[i] = Float(Double(buf.left[i]) * g); buf.right[i] = Float(Double(buf.right[i]) * g) }
        }
        return SongRender(buffer: buf, musicFrames: music, loudness: report)
    }

    static func render(sampleRate: Double, length: Int, tracks: [SF2TrackState], events: [SF2SynthEvent], maxVoices: Int,
                       configure: ((Sf2SynthEngine) -> Void)?) -> SF2StereoBuffer {
        var left = [Float](repeating: 0, count: length), right = left
        let engine = Sf2SynthEngine(outSr: sampleRate, maxVoices: maxVoices)
        configure?(engine)
        engine.setTrackStates(tracks)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                var cursor = 0
                for e in SF2EventOrder.sorted(events) {
                    let frame = max(0, min(length, Int(Int32(truncatingIfNeeded: e.frame ?? 0))))
                    if frame > cursor { engine.renderRange(l.baseAddress! + cursor, r.baseAddress! + cursor, frame - cursor); cursor = frame }
                    engine.dispatchEvent(e)
                }
                if cursor < length { engine.renderRange(l.baseAddress! + cursor, r.baseAddress! + cursor, length - cursor) }
            }
        }
        return SF2StereoBuffer(sampleRate: sampleRate, left: left, right: right)
    }
}
