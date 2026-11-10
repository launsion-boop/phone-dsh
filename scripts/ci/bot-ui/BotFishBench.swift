// SPDX-License-Identifier: MIT

// Capture-app-only benchmark for the native 大肥鱼 renderer. It drives the
// same `BotFishEngine.advance` entry point the SwiftUI TimelineView drives,
// with synthetic display-link dates, and reports the mean CPU time per frame.
//
// Launch with `-BotFishBench`; the app writes `bot-fish-bench.json` into its
// Documents container and exits after printing `BOT_FISH_BENCH <json>`.

#if DEBUG
import Darwin
import Foundation
import PhoneDSHBot
import SwiftUI
import UIKit

enum BotFishBenchmark {
    struct Configuration {
        let name: String
        let size: CGFloat
        let state: BotFishLifecycle
        let displayScale: CGFloat
        let frames: Int
        var crowned = false
        var reaction: BotFishReaction?
    }

    static let framesPerConfiguration = 3000

    /// The regression set compared with `origin/main` (32/96pt idle and
    /// working) plus the two main-Bot crown sizes.
    static func configurations(frames: Int = framesPerConfiguration) -> [Configuration] {
        [
            Configuration(name: "32pt-idle", size: 32, state: .idle,
                          displayScale: 3, frames: frames),
            Configuration(name: "32pt-working", size: 32, state: .working,
                          displayScale: 3, frames: frames),
            Configuration(name: "96pt-idle", size: 96, state: .idle,
                          displayScale: 3, frames: frames),
            Configuration(name: "96pt-working", size: 96, state: .working,
                          displayScale: 3, frames: frames),
            Configuration(name: "32pt-crowned-working", size: 32, state: .working,
                          displayScale: 3, frames: frames, crowned: true),
            Configuration(name: "96pt-crowned-idle", size: 96, state: .idle,
                          displayScale: 3, frames: frames, crowned: true),
        ]
    }

    /// One-shot reactions are measured over their own playback window instead
    /// of the full 300-frame lifecycle run: the first measured frame starts the
    /// reaction, the rest re-use the same id exactly like a real view.
    static func reactionConfigurations(frames: Int = framesPerConfiguration) -> [Configuration] {
        func make(_ name: String, size: CGFloat, kind: BotFishReactionKind,
                  frames: Int, duration: Int64) -> Configuration {
            let reaction = BotFishReaction(
                id: "bench-\(name)", kind: kind, name: name,
                startedAt: 0, durationMs: duration)
            return Configuration(name: "\(Int(size))pt-\(name)", size: size, state: .idle,
                                 displayScale: 3, frames: frames, reaction: reaction)
        }
        let actionFrames = min(frames, 48)
        let expressionFrames = min(frames, 120)
        return [
            make("waving", size: 32, kind: .action, frames: actionFrames, duration: 1_600),
            make("waving", size: 96, kind: .action, frames: actionFrames, duration: 1_600),
            make("happy", size: 32, kind: .expression, frames: expressionFrames, duration: 4_000),
            make("happy", size: 96, kind: .expression, frames: expressionFrames, duration: 4_000),
        ]
    }

    static func runAll(frames: Int = framesPerConfiguration) -> [String: Any] {
        var results: [[String: Any]] = []
        for configuration in configurations(frames: frames)
            + reactionConfigurations(frames: frames) {
            results.append(run(configuration))
        }
        let arguments = ProcessInfo.processInfo.arguments
        var marker = ""
        if let index = arguments.firstIndex(of: "-BotFishBenchMarker"),
           arguments.indices.contains(index + 1) {
            marker = arguments[index + 1]
        }
        return [
            "status": "PASS",
            "platform": "iOS Simulator",
            "completedAt": Date().timeIntervalSince1970,
            "marker": marker,
            "framesPerConfiguration": frames,
            "device": UIDevice.current.name,
            "systemVersion": UIDevice.current.systemVersion,
            "configurations": results,
        ]
    }

    static func run(_ configuration: Configuration) -> [String: Any] {
        let engine = BotFishEngine()
        engine.configure(state: configuration.state, still: false, reduced: false)
        let origin = Date(timeIntervalSinceReferenceDate: CACurrentMediaTime())

        // Warm up long enough for the shared tint/scaling caches and the
        // per-engine display-sized buffers to be built exactly as they are
        // before the measured window starts.
        for index in 0..<10 {
            _ = engine.advance(at: origin.addingTimeInterval(Double(index) / 30.0),
                               state: configuration.state, still: false, reduced: false,
                               size: configuration.size,
                               displayScale: configuration.displayScale,
                               appearance: .classic, crowned: configuration.crowned)
        }

        var renderedFrames = 0
        var renderTime = 0.0
        let start = CACurrentMediaTime()
        for index in 0..<configuration.frames {
            let timestamp = origin.addingTimeInterval(Double(10 + index) / 30.0)
            let frameStart = CACurrentMediaTime()
            let image = engine.advance(at: timestamp,
                                       state: configuration.state, still: false, reduced: false,
                                       size: configuration.size,
                                       displayScale: configuration.displayScale,
                                       appearance: .classic,
                                       crowned: configuration.crowned,
                                       reaction: configuration.reaction)
            renderTime += CACurrentMediaTime() - frameStart
            if image != nil { renderedFrames += 1 }
        }
        let elapsed = CACurrentMediaTime() - start

        return [
            "name": configuration.name,
            "sizePt": Double(configuration.size),
            "state": configuration.state.rawValue,
            "displayScale": Double(configuration.displayScale),
            "crowned": configuration.crowned,
            "reaction": configuration.reaction?.name ?? "",
            "frames": configuration.frames,
            "renderedFrames": renderedFrames,
            "totalMs": elapsed * 1000,
            "meanFrameMs": elapsed * 1000 / Double(configuration.frames),
            "renderOnlyMeanFrameMs": renderTime * 1000 / Double(configuration.frames),
            "framesPerSecond": Double(configuration.frames) / elapsed,
        ]
    }

    static func runAndExit() {
        let result = runAll()
        let data = try? JSONSerialization.data(withJSONObject: result,
                                               options: [.prettyPrinted, .sortedKeys])
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("bot-fish-bench.json")
        try? data?.write(to: url, options: .atomic)
        if let data, let text = String(data: data, encoding: .utf8) {
            print("BOT_FISH_BENCH \(text.replacingOccurrences(of: "\n", with: " "))")
        }
        fflush(stdout)
        exit(0)
    }
}

struct BotFishBenchmarkView: View {
    var body: some View {
        Text("BotFish benchmark running…")
            .font(.system(size: 15))
            .task { BotFishBenchmark.runAndExit() }
    }
}
#endif
