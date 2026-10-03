// swift-tools-version:5.9
// SPDX-License-Identifier: AGPL-3.0-or-later
// SF2Engine: SoundFont 2 parser + voice synth (sample playback, envelopes, LFOs, filter, modulators).
// Shared rendering engine for the omr-sheet-cam and earsheet apps; MIDI sequencing and players live in each app.
import PackageDescription

let package = Package(
    name: "SF2Engine",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "SF2Engine", targets: ["SF2Engine"]),
    ],
    targets: [
        .target(name: "SF2Engine"),
        .testTarget(name: "SF2EngineTests", dependencies: ["SF2Engine"]),
    ]
)
