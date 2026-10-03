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
                                             maxVoices: Int = 64) -> SF2StereoBuffer {
        var left = [Float](repeating: 0, count: length)
        var right = [Float](repeating: 0, count: length)
        let engine = Sf2SynthEngine(outSr: sampleRate, maxVoices: maxVoices)
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
