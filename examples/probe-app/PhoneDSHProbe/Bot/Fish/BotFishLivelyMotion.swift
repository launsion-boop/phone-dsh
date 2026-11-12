// SPDX-License-Identifier: MIT

// App-only animation set for the running Bot header fish. Every period,
// keyframe and the easing are constants here so the motion can be reviewed
// without reading the sampler code. `.standard` avatars never call this file.
//
// Timing model:
//  * each looping state has one clip period (working styles have their own);
//  * every track is a list of (phase, value) keys where phase is 0...1 inside
//    that clip; segments ease with the upstream smoothstep (`BotFishMath.smooth`);
//  * `celebrate`/`done` are one-shot 1.2s clips that hold their final pose;
//  * the state machine adds a critically damped pose spring (~320ms settle)
//    on state changes, a 3–5s blink timer (0.26s blink) and the 30fps view
//    budget.

import Foundation
import PhoneDSHBot

struct BotFishLivelyKeyframe {
    let phase: Double
    let value: Double
}

/// A looping scalar track. Keys are sorted, start at 0 and end at 1; the
/// first and last value match so the wrap has no seam.
struct BotFishLivelyTrack {
    let keys: [BotFishLivelyKeyframe]

    init(_ keys: [(Double, Double)]) {
        self.keys = keys.map { BotFishLivelyKeyframe(phase: $0.0, value: $0.1) }
    }

    static let zero = BotFishLivelyTrack([(0, 0), (1, 0)])

    func value(at phase: Double) -> Double {
        guard let first = keys.first, let last = keys.last else { return 0 }
        let p = phase - floor(phase)
        if p <= first.phase { return first.value }
        if p >= last.phase { return last.value }
        for index in 1..<keys.count {
            let a = keys[index - 1]
            let b = keys[index]
            guard p <= b.phase else { continue }
            let span = b.phase - a.phase
            let eased = span <= 0 ? 1 : BotFishMath.smooth((p - a.phase) / span)
            return BotFishMath.lerp(a.value, b.value, eased)
        }
        return last.value
    }

    /// One-shot sampling: q is clamped into the 0...1 clip and the last key
    /// is held afterwards instead of wrapping to the start.
    func value(clamped q: Double) -> Double {
        guard let first = keys.first, let last = keys.last else { return 0 }
        let t = BotFishMath.clamp(q, 0, 1)
        if t <= first.phase { return first.value }
        if t >= last.phase { return last.value }
        for index in 1..<keys.count {
            let a = keys[index - 1]
            let b = keys[index]
            guard t <= b.phase else { continue }
            let span = b.phase - a.phase
            let eased = span <= 0 ? 1 : BotFishMath.smooth((t - a.phase) / span)
            return BotFishMath.lerp(a.value, b.value, eased)
        }
        return last.value
    }
}

enum BotFishLivelyMotion {
    // MARK: - Shared timing

    /// Random blink interval in milliseconds (3–5s), exactly the upstream
    /// 260ms blink shape driven by `BotFishStateMachine`.
    static let blinkIntervalMilliseconds: ClosedRange<Double> = 3000...5000
    /// Pose x/y/roll/scale transition spring after a lifecycle/state change.
    /// Critically damped, settles in roughly 320ms; the face/gaze/head keys
    /// already run through the machine's existing springs.
    static let poseSpringOmega = 18.0
    static let transitionMilliseconds = 320.0
    /// Eye/iris travel multiplier at 28pt. Upstream stays at 1.
    static let gazeEmphasis = 2.4

    /// Thinking dots: 1.08s cycle, 0.12s between neighbours, 12 source units
    /// of lift and a 1.5x radius so the hop reads at 28pt.
    static let dotsCycleMilliseconds = 1080.0
    static let dotsStaggerMilliseconds = 120.0
    static let dotsLift = 12.0
    static let dotsScale = 1.5

    // MARK: - Thinking (4.8s loop)

    static let thinkingPeriod = 4800.0
    static let thinkingRoll = BotFishLivelyTrack([
        (0, 0), (0.25, -6), (0.5, 0), (0.75, 6), (1, 0),
    ])
    static let thinkingHeadX = BotFishLivelyTrack([
        (0, 0), (0.25, 1.4), (0.5, 0), (0.75, -1.4), (1, 0),
    ])
    static let thinkingGazeX = BotFishLivelyTrack([
        (0, -0.5), (0.25, -0.75), (0.5, 0.6), (0.75, 0.75), (1, -0.5),
    ])
    static let thinkingGazeY = BotFishLivelyTrack([
        (0, -0.6), (0.25, -0.85), (0.5, -0.35), (0.75, -0.8), (1, -0.6),
    ])
    static let thinkingHairSway = BotFishLivelyTrack([
        (0, 0), (0.25, -6), (0.5, 0), (0.75, 6), (1, 0),
    ])
    static let thinkingEarFlutter = BotFishLivelyTrack([
        (0, 0), (0.25, 4), (0.5, 0), (0.75, -4), (1, 0),
    ])

    // MARK: - Working styles (App only; never lifecycle states)

    struct WorkingTracks {
        let period: Double
        let roll: BotFishLivelyTrack
        let headX: BotFishLivelyTrack
        let y: BotFishLivelyTrack
        let gazeX: BotFishLivelyTrack
        let gazeY: BotFishLivelyTrack
        let scaleX: BotFishLivelyTrack
        let scaleY: BotFishLivelyTrack
        let hairSway: BotFishLivelyTrack
        let eyeArt: String?
        let brow: Double
        let anger: Double
        let smile: Double
    }

    /// Default "干活" rhythm: nod, ±5.5° body sway and one squash/stretch
    /// beat per 2.4s.
    static let workingGeneric = WorkingTracks(
        period: 2400,
        roll: BotFishLivelyTrack([
            (0, 0), (0.18, 5.5), (0.4, 0), (0.62, -5.5), (0.82, 0), (1, 0),
        ]),
        headX: BotFishLivelyTrack([
            (0, 0), (0.18, -1.2), (0.4, 0), (0.62, 1.2), (0.82, 0), (1, 0),
        ]),
        y: BotFishLivelyTrack([
            (0, 0), (0.1, 18), (0.2, 0), (0.32, 13), (0.42, 0),
            (0.55, 0), (1, 0),
        ]),
        gazeX: .zero,
        gazeY: BotFishLivelyTrack([
            (0, 0), (0.5, 0), (0.6, 0.25), (0.8, 0.1), (1, 0),
        ]),
        scaleX: BotFishLivelyTrack([
            (0, 1), (0.55, 1), (0.6, 1.06), (0.68, 0.975), (0.76, 1.01),
            (0.86, 1), (1, 1),
        ]),
        scaleY: BotFishLivelyTrack([
            (0, 1), (0.55, 1), (0.6, 0.93), (0.68, 1.035), (0.76, 0.995),
            (0.86, 1), (1, 1),
        ]),
        hairSway: BotFishLivelyTrack([
            (0, 0), (0.18, 5), (0.4, 0), (0.62, -5), (0.82, 0), (1, 0),
        ]),
        eyeArt: "focused", brow: -0.3, anger: 0.2, smile: 0.15)

    /// Reading: eyes sweep a line (design eyes so the iris moves a visible
    /// amount), head turns a little with them. 3.6s loop.
    static let workingReading = WorkingTracks(
        period: 3600,
        roll: BotFishLivelyTrack([
            (0, -2), (0.15, -2), (0.5, 3), (0.72, 3), (0.85, -2), (1, -2),
        ]),
        headX: BotFishLivelyTrack([
            (0, 0.9), (0.15, 0.9), (0.5, -1.1), (0.72, -1.1), (0.85, 0.9),
            (1, 0.9),
        ]),
        y: BotFishLivelyTrack([
            (0, 0), (0.15, 5), (0.5, 2), (0.72, 6), (0.85, 0), (1, 0),
        ]),
        gazeX: BotFishLivelyTrack([
            (0, -0.95), (0.15, -0.95), (0.5, 0.95), (0.72, 0.95),
            (0.85, -0.95), (1, -0.95),
        ]),
        gazeY: BotFishLivelyTrack([(0, 0.35), (1, 0.35)]),
        scaleX: BotFishLivelyTrack([
            (0, 1), (0.8, 1), (0.86, 1.02), (0.92, 0.995), (1, 1),
        ]),
        scaleY: BotFishLivelyTrack([
            (0, 1), (0.8, 1), (0.86, 0.985), (0.92, 1.005), (1, 1),
        ]),
        hairSway: BotFishLivelyTrack([
            (0, -3), (0.5, 4), (0.85, -3), (1, -3),
        ]),
        eyeArt: nil, brow: -0.2, anger: 0.1, smile: 0.3)

    /// Searching: head looks left/right while the eyes move faster. 2.6s.
    static let workingSearching = WorkingTracks(
        period: 2600,
        roll: BotFishLivelyTrack([
            (0, 0), (0.12, -7), (0.28, -7), (0.4, 0), (0.52, 7),
            (0.66, 7), (0.78, 0), (0.9, 0), (1, 0),
        ]),
        headX: BotFishLivelyTrack([
            (0, 0), (0.12, 1.8), (0.28, 1.8), (0.4, 0), (0.52, -1.8),
            (0.66, -1.8), (0.78, 0), (0.9, 0), (1, 0),
        ]),
        y: .zero,
        gazeX: BotFishLivelyTrack([
            (0, 0), (0.06, -1), (0.18, 1), (0.28, -1), (0.4, 0.9),
            (0.52, -0.9), (0.66, 0.9), (0.78, 0), (0.9, 0), (1, 0),
        ]),
        gazeY: BotFishLivelyTrack([(0, 0), (0.5, -0.15), (1, 0)]),
        scaleX: BotFishLivelyTrack([
            (0, 1), (0.4, 1), (0.46, 1.015), (0.56, 1), (1, 1),
        ]),
        scaleY: BotFishLivelyTrack([
            (0, 1), (0.4, 1), (0.46, 0.99), (0.56, 1), (1, 1),
        ]),
        hairSway: BotFishLivelyTrack([
            (0, 0), (0.12, 5.4), (0.4, 0), (0.52, -5.4), (0.78, 0), (1, 0),
        ]),
        eyeArt: nil, brow: -0.35, anger: 0.15, smile: 0.1)

    /// Running: twice as fast as the default nod, like typing commands. 1.2s.
    static let workingRunning = WorkingTracks(
        period: 1200,
        roll: BotFishLivelyTrack([
            (0, 0), (0.15, 3.5), (0.35, 0), (0.55, -3.5), (0.75, 0), (1, 0),
        ]),
        headX: BotFishLivelyTrack([
            (0, 0), (0.15, -0.9), (0.35, 0), (0.55, 0.9), (0.75, 0), (1, 0),
        ]),
        y: BotFishLivelyTrack([
            (0, 0), (0.08, 18), (0.16, 0), (0.28, 14), (0.36, 0),
            (0.52, 0), (0.6, 18), (0.68, 0), (0.8, 14), (0.88, 0), (1, 0),
        ]),
        gazeX: .zero,
        gazeY: BotFishLivelyTrack([(0, -0.05), (0.5, 0.1), (1, -0.05)]),
        scaleX: BotFishLivelyTrack([
            (0, 1), (0.08, 1.02), (0.16, 0.99), (0.28, 1.02), (0.36, 1),
            (0.6, 1.02), (0.68, 1), (0.8, 1.02), (0.88, 1), (1, 1),
        ]),
        scaleY: BotFishLivelyTrack([
            (0, 1), (0.08, 0.98), (0.16, 1.01), (0.28, 0.98), (0.36, 1),
            (0.6, 0.98), (0.68, 1), (0.8, 0.98), (0.88, 1), (1, 1),
        ]),
        hairSway: BotFishLivelyTrack([
            (0, 0), (0.15, -3.6), (0.35, 0), (0.55, 3.6), (0.75, 0), (1, 0),
        ]),
        eyeArt: "focused", brow: -0.4, anger: 0.25, smile: 0.1)

    /// Writing: head down (whole-fish + gaze) with a small fast shake. 1.8s.
    static let workingWriting = WorkingTracks(
        period: 1800,
        roll: BotFishLivelyTrack([
            (0, -4.5), (0.18, -4.5), (0.3, -2.5), (0.42, -4.5),
            (0.54, -2.5), (0.66, -4.5), (0.8, -4.5), (1, -4.5),
        ]),
        headX: BotFishLivelyTrack([
            (0, 0.7), (0.18, 0.7), (0.3, -0.7), (0.42, 0.7),
            (0.54, -0.7), (0.66, 0.7), (0.8, 0.7), (1, 0.7),
        ]),
        y: BotFishLivelyTrack([
            (0, 14), (0.2, 14), (0.35, 12), (0.5, 14), (0.65, 12),
            (0.8, 14), (1, 14),
        ]),
        gazeX: BotFishLivelyTrack([
            (0, -0.25), (0.25, 0.3), (0.5, -0.3), (0.75, 0.25), (1, -0.25),
        ]),
        gazeY: BotFishLivelyTrack([(0, 0.8), (1, 0.8)]),
        scaleX: BotFishLivelyTrack([
            (0, 1), (0.3, 1.01), (0.45, 0.995), (0.6, 1.01), (0.75, 1), (1, 1),
        ]),
        scaleY: BotFishLivelyTrack([
            (0, 1), (0.3, 0.99), (0.45, 1.005), (0.6, 0.99), (0.75, 1), (1, 1),
        ]),
        hairSway: BotFishLivelyTrack([
            (0, 2.8), (0.3, -2.8), (0.54, 2.8), (0.8, 2.8), (1, 2.8),
        ]),
        eyeArt: nil, brow: -0.4, anger: 0.25, smile: 0.05)

    static func workingTracks(_ style: BotFishWorkStyle) -> WorkingTracks {
        switch style {
        case .generic: return workingGeneric
        case .reading: return workingReading
        case .searching: return workingSearching
        case .running: return workingRunning
        case .writing: return workingWriting
        }
    }

    // MARK: - Streaming / speaking (mouth + ±10° head sway)

    static let streamingPeriod = 1600.0
    static let speakingPeriod = 1400.0
    static let speechRoll = BotFishLivelyTrack([
        (0, 0), (0.12, 9), (0.28, 4), (0.42, -10), (0.58, -4),
        (0.72, 8), (0.88, 2), (1, 0),
    ])
    static let speechHeadX = BotFishLivelyTrack([
        (0, 0), (0.12, -0.9), (0.42, 0.9), (0.72, -0.8), (1, 0),
    ])
    static let speechGazeX = BotFishLivelyTrack([
        (0, 0), (0.32, 0.25), (0.64, -0.2), (1, 0),
    ])
    static let speechGazeY = BotFishLivelyTrack([
        (0, 0), (0.5, -0.15), (1, 0),
    ])
    static let speechHairSway = BotFishLivelyTrack([
        (0, 0), (0.12, -4), (0.42, 4), (0.72, -3), (1, 0),
    ])

    // MARK: - Celebrate / done (one-shot 1.2s)

    static let celebrationDuration = 1200.0
    static let celebrationHopY = BotFishLivelyTrack([
        (0, 0), (0.08, 4), (0.2, -20), (0.34, -12), (0.48, 0),
        (0.6, -7), (0.74, 0), (1, 0),
    ])
    static let celebrationRoll = BotFishLivelyTrack([
        (0, 0), (0.2, -4), (0.48, 3), (0.74, -2), (1, 0),
    ])
    static let celebrationScaleX = BotFishLivelyTrack([
        (0, 1), (0.08, 1.05), (0.2, 0.95), (0.34, 0.98), (0.48, 1.02),
        (0.6, 0.99), (1, 1),
    ])
    static let celebrationScaleY = BotFishLivelyTrack([
        (0, 1), (0.08, 0.94), (0.2, 1.06), (0.34, 1.01), (0.48, 0.98),
        (0.6, 1.01), (1, 1),
    ])
    static let celebrationHairSway = BotFishLivelyTrack([
        (0, 0), (0.2, -7), (0.48, 5), (0.74, -3), (1, 0),
    ])
    static let celebrationEarFlutter = BotFishLivelyTrack([
        (0, 0), (0.2, 5), (0.48, -3), (1, 0),
    ])
    static let celebrationFinWave = BotFishLivelyTrack([
        (0, 0), (0.2, 0.5), (0.48, -0.3), (1, 0),
    ])

    // MARK: - Sampling

    /// Returns nil for lifecycle states that keep the upstream `.standard`
    /// clip (idle, alerting, listening, …). `elapsed` is state-relative time
    /// and is already frozen at 650ms for still/reduced-motion frames.
    static func sample(state: BotFishLifecycle, workStyle: BotFishWorkStyle,
                       elapsed: Double) -> BotFishParams? {
        let params: BotFishParams
        switch state {
        case .thinking:
            params = thinking(elapsed)
        case .working:
            params = working(elapsed, style: workStyle)
        case .streaming:
            params = speech(elapsed, period: streamingPeriod,
                            mouthFrameMilliseconds: 170,
                            mouthArts: ["smile", "vowel-e", "small-o"])
        case .speaking:
            params = speech(elapsed, period: speakingPeriod,
                            mouthFrameMilliseconds: 111,
                            mouthArts: ["smile", "vowel-a", "small-o"])
        case .celebrate:
            params = celebration(elapsed, done: false)
        case .done:
            params = celebration(elapsed, done: true)
        default:
            return nil
        }
        var result = params
        result.isLivelyMotion = true
        return result
    }

    private static func phase(_ elapsed: Double, period: Double) -> Double {
        guard period > 0 else { return 0 }
        return (elapsed / period).truncatingRemainder(dividingBy: 1)
    }

    private static func thinking(_ elapsed: Double) -> BotFishParams {
        let q = phase(elapsed, period: thinkingPeriod)
        var p = BotFishParams()
        p.roll = thinkingRoll.value(at: q)
        p.headX = thinkingHeadX.value(at: q)
        p.gazeX = thinkingGazeX.value(at: q)
        p.gazeY = thinkingGazeY.value(at: q)
        p.gazeEmphasis = gazeEmphasis
        p.browL = 0.65
        p.browR = -0.15
        p.smile = 0.1
        p.mouthWidth = 0.65
        p.hairSway = thinkingHairSway.value(at: q)
        p.earFlutter = thinkingEarFlutter.value(at: q)
        p.decoration = "dots"
        p.dotLift = dotsLift
        p.dotScale = dotsScale
        p.dotStagger = dotsStaggerMilliseconds / dotsCycleMilliseconds
        p.phase = phase(elapsed, period: dotsCycleMilliseconds)
        return p
    }

    private static func working(_ elapsed: Double, style: BotFishWorkStyle) -> BotFishParams {
        let tracks = workingTracks(style)
        let q = phase(elapsed, period: tracks.period)
        var p = BotFishParams()
        p.eyeArt = tracks.eyeArt
        p.roll = tracks.roll.value(at: q)
        p.headX = tracks.headX.value(at: q)
        p.y = tracks.y.value(at: q)
        p.gazeX = tracks.gazeX.value(at: q)
        p.gazeY = tracks.gazeY.value(at: q)
        p.gazeEmphasis = gazeEmphasis
        p.sx = tracks.scaleX.value(at: q)
        p.sy = tracks.scaleY.value(at: q)
        p.hairSway = tracks.hairSway.value(at: q)
        p.earFlutter = tracks.headX.value(at: q) * 2
        p.browL = tracks.brow
        p.browR = tracks.brow
        p.anger = tracks.anger
        p.smile = tracks.smile
        p.mouthWidth = 0.8
        p.mouthArt = "smile"
        return p
    }

    private static func speech(_ elapsed: Double, period: Double,
                               mouthFrameMilliseconds: Double,
                               mouthArts: [String]) -> BotFishParams {
        let q = phase(elapsed, period: period)
        var p = BotFishParams()
        p.mouthArt = mouthArts[Int(floor(elapsed / mouthFrameMilliseconds)) % mouthArts.count]
        p.roll = speechRoll.value(at: q)
        p.headX = speechHeadX.value(at: q)
        p.gazeX = speechGazeX.value(at: q)
        p.gazeY = speechGazeY.value(at: q)
        p.gazeEmphasis = 2.0
        p.hairSway = speechHairSway.value(at: q)
        p.earFlutter = speechHeadX.value(at: q) * 1.5
        p.smile = 0.6
        p.mouthWidth = 0.9
        return p
    }

    private static func celebration(_ elapsed: Double, done: Bool) -> BotFishParams {
        let q = BotFishMath.clamp(elapsed / celebrationDuration, 0, 1)
        var p = BotFishParams()
        p.joy = 1
        p.smile = 1
        p.blush = 0.55
        p.eyeArt = done ? "excited" : "laughing"
        p.mouthArt = done ? "smile-open" : "laugh"
        p.mouthWidth = done ? 0.95 : 1.1
        p.y = celebrationHopY.value(clamped: q)
        p.roll = celebrationRoll.value(clamped: q)
        p.sx = celebrationScaleX.value(clamped: q)
        p.sy = celebrationScaleY.value(clamped: q)
        p.hairSway = celebrationHairSway.value(clamped: q)
        p.earFlutter = celebrationEarFlutter.value(clamped: q)
        p.finL = 0.9
        p.finR = 0.9
        p.finWave = celebrationFinWave.value(clamped: q)
        p.gazeEmphasis = 2.0
        p.decoration = done ? "check" : "confetti"
        p.phase = q
        return p
    }
}
