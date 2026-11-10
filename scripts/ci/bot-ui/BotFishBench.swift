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
    }

    static let framesPerConfiguration = 300

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
        ]
    }

    static func runAll(frames: Int = framesPerConfiguration) -> [String: Any] {
        var results: [[String: Any]] = []
        for configuration in configurations(frames: frames) {
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
                               appearance: .classic)
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
                                       appearance: .classic)
            renderTime += CACurrentMediaTime() - frameStart
            if image != nil { renderedFrames += 1 }
        }
        let elapsed = CACurrentMediaTime() - start

        return [
            "name": configuration.name,
            "sizePt": Double(configuration.size),
            "state": configuration.state.rawValue,
            "displayScale": Double(configuration.displayScale),
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
