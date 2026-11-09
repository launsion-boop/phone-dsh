// SPDX-License-Identifier: MIT

// Native port of dsh-bot `src/renderer/lib/fish/model.js` and
// `expressive.js` (revision bf4075b). The model is deterministic: given a
// lifecycle state and a time in milliseconds it produces the facial and
// transform parameters the renderer paints. Nothing here touches UIKit.

import Foundation
import PhoneDSHBot

enum BotFishMath {
    static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        max(lower, min(upper, value))
    }

    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    /// `ease` in the upstream model.
    static func smooth(_ value: Double) -> Double {
        let t = clamp(value, 0, 1)
        return t * t * (3 - 2 * t)
    }

    static func bump(_ x: Double, _ a: Double, _ b: Double) -> Double {
        guard x > a, x < b else { return 0 }
        let s = sin((x - a) / (b - a) * Double.pi)
        return s * s
    }
}

enum BotFishEyeCel {
    /// Row-major order of the 3×4 eye sprite grid.
    static let names = [
        "laughing", "focused", "surprised", "sad", "love", "confused",
        "angry", "sleepy", "wink", "excited", "deadpan", "shy",
    ]

    static func index(of name: String?) -> Int? {
        guard let name else { return nil }
        return names.firstIndex(of: name)
    }
}

enum BotFishMouthCel {
    /// Row-major order of the 3×4 mouth sprite grid.
    static let names = [
        "smile", "smile-open", "laugh", "shocked", "pout", "sad",
        "smug", "small-o", "vowel-a", "vowel-e", "kiss", "yawn",
    ]

    static func index(of name: String?) -> Int? {
        guard let name else { return nil }
        return names.firstIndex(of: name)
    }
}

/// Every animated parameter the renderer consumes. Defaults match the
/// upstream `sample()` baseline object.
struct BotFishParams {
    var eyeL = 1.0
    var eyeR = 1.0
    var joy = 0.0
    var browL = 0.0
    var browR = 0.0
    var anger = 0.0
    var sorrow = 0.0
    var smile = 0.55
    var mouth = 0.0
    var mouthWidth = 1.0
    var round = 0.0
    var blush = 0.0
    var tears = 0.0
    var love = 0.0
    var gazeX = 0.0
    var gazeY = 0.0
    var roll = 0.0
    var y = 0.0
    var x = 0.0
    var sx = 1.0
    var sy = 1.0
    var alpha = 1.0
    var finL = 0.0
    var finR = 0.0
    var finWave = 0.0
    var decoration = ""
    var progress = 0.0
    var phase = 0.0

    // Filled by `expressiveMotion`.
    var eyeArt: String?
    var mouthArt: String?
    var finFold = 0.0
    var hairSway = 0.0
    var earFlutter = 0.0
    var puff = 0.0
    var breath = 0.0

    // Filled by the controller.
    var headX = 0.0
    var headY = 0.0
    var bodyX = 0.0
    var bodyY = 0.0
    var blink = 1.0
    var morphX = 1.0
    var morphY = 1.0
    var artMix = 1.0
    var eyeArtPrev: String?
    var mouthArtPrev: String?
}

struct BotFishClip {
    var period: Double?
    var duration: Double?
    var isStatic = false

    static func forState(_ state: BotFishLifecycle) -> BotFishClip {
        switch state {
        case .idle: return BotFishClip(period: 2400)
        case .thinking: return BotFishClip(period: 2800)
        case .streaming: return BotFishClip(period: 1000)
        case .working: return BotFishClip(period: 1800)
        case .sleeping: return BotFishClip(period: 4200)
        case .alerting: return BotFishClip(period: 1100)
        case .listening: return BotFishClip(period: 3200)
        case .speaking: return BotFishClip(period: 900)
        case .happy: return BotFishClip(period: 2200)
        case .sad: return BotFishClip(period: 3600)
        case .surprised: return BotFishClip(period: 2000)
        case .confused: return BotFishClip(period: 3200)
        case .laughing: return BotFishClip(period: 900)
        case .love: return BotFishClip(period: 2400)
        case .angry: return BotFishClip(period: 2400)
        case .wink: return BotFishClip(period: 2200)
        case .nod: return BotFishClip(period: 2000)
        case .shrug: return BotFishClip(period: 2800)
        case .celebrate: return BotFishClip(period: 1500)
        case .poke: return BotFishClip(duration: 420)
        case .waking: return BotFishClip(duration: 1400)
        case .waiting: return BotFishClip(period: 4000)
        case .loading: return BotFishClip(period: 1600)
        case .done: return BotFishClip(duration: 1200)
        case .standby: return BotFishClip(period: nil, duration: nil, isStatic: true)
        case .poweringDown: return BotFishClip(duration: 1400)
        case .spawning: return BotFishClip(duration: 1000)
        case .bouncing: return BotFishClip(period: 1400)
        case .dancing: return BotFishClip(period: 1800)
        case .waving: return BotFishClip(period: 1600)
        case .shy: return BotFishClip(period: 3200)
        case .smug: return BotFishClip(period: 2600)
        case .crying: return BotFishClip(period: 2400)
        case .sighing: return BotFishClip(period: 3600)
        case .cheering: return BotFishClip(period: 1600)
        case .bowing: return BotFishClip(period: 2800)
        case .shakingHead: return BotFishClip(period: 2400)
        case .clapping: return BotFishClip(period: 1200)
        case .stretching: return BotFishClip(period: 4200)
        case .yawning: return BotFishClip(period: 4800)
        case .kiss: return BotFishClip(period: 2600)
        case .highFive: return BotFishClip(period: 2200)
        }
    }
}

enum BotFishModel {
    /// Port of `sample(state, time)`.
    static func sample(state: BotFishLifecycle, time: Double) -> BotFishParams {
        let spec = BotFishClip.forState(state)
        let phase = spec.period.map { period in
            period == 0 ? 0 : time.truncatingRemainder(dividingBy: period) / period
        } ?? 0
        let s = sin(phase * Double.pi * 2)
        let q = spec.duration.map { BotFishMath.clamp(time / $0, 0, 1) } ?? phase
        var p = BotFishParams()
        p.phase = phase
        p.progress = q

        switch state {
        case .idle:
            p.sy = 1 + s * 0.004
        case .thinking:
            p.gazeY = -0.65
            p.gazeX = -0.25
            p.browL = 0.65
            p.browR = -0.15
            p.roll = -2.5
            p.smile = 0.05
            p.mouthWidth = 0.65
            p.decoration = "dots"
        case .streaming:
            p.eyeL = 0.70
            p.eyeR = 0.70
            p.mouth = 0.10 + 0.20 * (s + 1) / 2
            p.smile = 0.5
            p.mouthWidth = 0.75
        case .working:
            p.eyeL = 0.84
            p.eyeR = 0.84
            p.anger = 0.25
            p.browL = -0.35
            p.browR = -0.35
            p.y = max(0, s) * 2.6
            p.smile = 0.15
        case .sleeping:
            p.eyeL = 0
            p.eyeR = 0
            p.mouth = 0.06
            p.mouthWidth = 0.42
            p.round = 1
            p.sy = 1 + s * 0.008
            p.y = 1.8 * s
            p.decoration = "sleep"
        case .alerting:
            p.eyeL = 1.14
            p.eyeR = 1.14
            p.browL = 0.7
            p.browR = 0.7
            p.mouth = 0.55
            p.mouthWidth = 0.65
            p.round = 1
            p.y = -max(0, s) * 9
            p.decoration = "alert"
        case .listening:
            p.eyeL = 1.03
            p.eyeR = 1.03
            p.browL = 0.12
            p.browR = 0.12
            p.roll = s * 1.3
            p.finL = 0.15
            p.finR = 0.15
            p.smile = 0.35
            p.decoration = "listen"
        case .speaking:
            let frame = Int(floor(time / 111)) % 3
            p.mouth = [0, 0.46, 0.82][frame]
            p.mouthWidth = frame == 2 ? 0.62 : 1
            p.round = frame == 2 ? 1 : 0
            p.roll = s * 0.6
        case .happy:
            p.eyeL = 0.82
            p.eyeR = 0.82
            p.joy = 0.65
            p.smile = 1
            p.mouth = 0.17
            p.blush = 0.65
            p.y = -2 * s
        case .sad:
            p.eyeL = 0.76
            p.eyeR = 0.76
            p.sorrow = 1
            p.browL = 0.35
            p.browR = 0.35
            p.smile = -0.7
            p.mouthWidth = 0.75
            p.tears = 0.8
            p.roll = -1.5
            p.y = 2
        case .surprised:
            p.eyeL = 1.18
            p.eyeR = 1.18
            p.browL = 0.8
            p.browR = 0.8
            p.mouth = 0.8
            p.mouthWidth = 0.58
            p.round = 1
            p.decoration = "spark"
        case .confused:
            p.eyeL = 1
            p.eyeR = 0.70
            p.browL = 0.7
            p.browR = -0.3
            p.roll = s * 3
            p.gazeX = s * 0.55
            p.smile = -0.05
            p.mouthWidth = 0.6
            p.decoration = "question"
        case .laughing:
            p.eyeL = 0.02
            p.eyeR = 0.02
            p.joy = 1
            p.smile = 1
            p.mouth = 0.80 + 0.08 * s
            p.blush = 0.55
            p.y = -4 * abs(s)
            p.roll = s
        case .love:
            p.love = 1
            p.joy = 0.3
            p.blush = 0.9
            p.smile = 1
            p.mouth = 0.13
            p.roll = 1.3 * s
            p.decoration = "hearts"
        case .angry:
            p.eyeL = 0.72
            p.eyeR = 0.72
            p.anger = 1
            p.browL = -0.55
            p.browR = -0.55
            p.smile = -0.65
            p.blush = 0.2
            p.decoration = "anger"
        case .wink:
            p.eyeL = 0.02
            p.eyeR = 1
            p.joy = 0.8
            p.smile = 1
            p.roll = 3
            p.blush = 0.35
            p.decoration = "spark"
        case .nod:
            p.y = s * 4
            p.sy = 1 - max(0, s) * 0.015
            p.gazeY = -s * 0.15
            p.smile = 0.65
        case .shrug:
            p.finL = 1
            p.finR = 1
            p.roll = -2.2
            p.eyeL = 0.9
            p.eyeR = 0.76
            p.browL = 0.5
            p.smile = -0.05
            p.mouthWidth = 0.7
        case .celebrate:
            p.eyeL = 0.02
            p.eyeR = 0.02
            p.joy = 1
            p.mouth = 0.75
            p.smile = 1
            p.blush = 0.6
            p.finL = 1
            p.finR = 1
            p.finWave = s * 0.3
            p.y = -abs(s) * 6
            p.decoration = "confetti"
        case .poke:
            let keys: [(Double, Double, Double)] = [
                (0, 1, 1), (0.23, 1.07, 0.90), (0.57, 0.95, 1.05), (1, 1, 1),
            ]
            var a = keys[0]
            var b = keys[keys.count - 1]
            for index in 1..<keys.count where q <= keys[index].0 {
                a = keys[index - 1]
                b = keys[index]
                break
            }
            let k = BotFishMath.smooth((q - a.0) / (b.0 - a.0))
            p.sx = BotFishMath.lerp(a.1, b.1, k)
            p.sy = BotFishMath.lerp(a.2, b.2, k)
            p.blush = 0.6
            p.mouth = 0.35
            p.mouthWidth = 0.65
            p.round = 0.8
        case .waking:
            let o = BotFishMath.smooth(q)
            p.eyeL = o
            p.eyeR = o
            p.smile = 0.4
            p.y = (1 - o) * 5
            p.alpha = 0.7 + 0.3 * o
            p.decoration = q < 0.8 ? "spark" : ""
        case .waiting:
            p.eyeL = 0.90
            p.eyeR = 0.90
            p.smile = 0.25
            p.sy = 1 + s * 0.003
            p.decoration = "waiting"
        case .loading:
            p.eyeL = 0.92
            p.eyeR = 0.92
            p.smile = 0.25
            p.decoration = "loading"
        case .done:
            p.joy = 0.4
            p.smile = 1
            p.blush = 0.25
            p.sx = 1 + sin(q * Double.pi) * 0.025
            p.sy = 1 + sin(q * Double.pi) * 0.025
            p.decoration = "check"
        case .standby:
            p.eyeL = 0.35
            p.eyeR = 0.35
            p.alpha = 0.65
            p.smile = 0.2
        case .poweringDown:
            p.eyeL = 1 - BotFishMath.smooth(q)
            p.eyeR = 1 - BotFishMath.smooth(q)
            p.alpha = 1 - 0.65 * BotFishMath.smooth(q)
            p.y = q * 5
            p.smile = 0.15
        case .spawning:
            let v = 1 - pow(1 - q, 3)
            p.sx = 0.65 + 0.35 * v + sin(q * Double.pi) * 0.025
            p.sy = 0.65 + 0.35 * v + sin(q * Double.pi) * 0.025
            p.alpha = BotFishMath.smooth(q * 2)
            p.y = (1 - v) * 14
            p.decoration = q < 0.85 ? "spark" : ""
        case .bouncing:
            p.y = -abs(s) * 13
            p.sx = 1 + abs(s) * 0.01
            p.sy = 1 - abs(s) * 0.015
            p.smile = 0.8
        case .dancing:
            p.roll = s * 4.5
            p.y = -abs(s) * 4
            p.joy = 0.45
            p.mouth = 0.4
            p.smile = 1
            p.finL = 0.7
            p.finR = 0.7
            p.finWave = s
            p.decoration = "music"
        case .waving:
            p.finR = 1
            p.finWave = s
            p.roll = -1.2
            p.smile = 0.9
            p.mouth = 0.16
            p.blush = 0.2
        case .shy, .smug, .crying, .sighing, .cheering, .bowing,
             .shakingHead, .clapping, .stretching, .yawning, .kiss, .highFive:
            break
        }

        return expressiveMotion(state: state, time: time, params: p)
    }

    /// Port of `expressiveMotion(state, time, p)` from `expressive.js`.
    static func expressiveMotion(state: BotFishLifecycle, time: Double, params: BotFishParams) -> BotFishParams {
        var p = params
        let special: Double
        switch state {
        case .happy: special = 2200
        case .laughing: special = 900
        case .sad: special = 3600
        case .angry: special = 2400
        case .waving: special = 1600
        case .dancing: special = 1800
        default: special = 2400
        }
        let period = BotFishClip.forState(state).period ?? special
        let phase = period == 0 ? 0 : time.truncatingRemainder(dividingBy: period) / period
        let s = sin(phase * Double.pi * 2)
        let s2 = sin(phase * Double.pi * 4)

        p.eyeArt = nil
        p.mouthArt = nil
        p.finFold = 0
        p.hairSway = 0
        p.earFlutter = 0
        p.puff = 0
        p.breath = 0

        switch state {
        case .streaming:
            p.mouthArt = ["smile", "vowel-e", "small-o"][Int(floor(time / 170)) % 3]
        case .speaking:
            p.mouthArt = ["smile", "vowel-a", "small-o"][Int(floor(time / 111)) % 3]
        case .happy:
            p.eyeArt = "excited"
            p.mouthArt = "smile-open"
            p.finL = 0.28
            p.finR = 0.28
            p.roll = s * 1.8
            p.hairSway = s * 1.8
        case .laughing:
            p.eyeArt = "laughing"
            p.mouthArt = "laugh"
            p.mouthWidth = 1.15
            p.y = -abs(s) * 7
            p.roll = s * 2.2
            p.hairSway = -s * 2.8
            p.finL = 0.6
            p.finR = 0.6
        case .sad:
            p.eyeArt = "sad"
            p.mouthArt = "sad"
            p.tears = 0.9
            p.roll = -2.6
            p.y = 3
            p.hairSway = s * 0.8
        case .surprised:
            p.eyeArt = "surprised"
            p.mouthArt = "shocked"
            let b = BotFishMath.bump(phase, 0, 0.38)
            p.sy = 1 + 0.018 * b
            p.y = -4 * b
            p.earFlutter = 3 * b
        case .angry:
            p.eyeArt = "angry"
            p.mouthArt = "pout"
            p.puff = 0.75
            p.roll = s * 0.7
            p.y = abs(s2) * 1.5
            p.finL = 0.5
            p.finR = 0.5
        case .confused:
            p.eyeArt = "confused"
            p.mouthArt = "small-o"
            p.roll = s * 5
            p.gazeX = s * 0.65
            p.hairSway = -s * 2
        case .love:
            p.eyeArt = "love"
            p.mouthArt = "smile-open"
            p.finL = 0.7
            p.finR = 0.7
            p.finFold = 0.55
            p.y = -2 * s
            p.hairSway = s * 2
        case .wink:
            p.eyeArt = "wink"
            p.mouthArt = "smug"
            p.finR = 0.8
            p.finWave = s * 0.45
            p.earFlutter = s
        case .sleeping:
            p.eyeArt = "laughing"
            p.mouthArt = "small-o"
            p.breath = (s + 1) * 0.5
        case .working:
            p.eyeArt = "focused"
            p.mouthArt = "smile"
            p.roll = s * 0.7
        case .waiting:
            p.eyeArt = "sleepy"
            p.mouthArt = "smile"
        case .celebrate:
            p.eyeArt = "laughing"
            p.mouthArt = "laugh"
            p.finL = 1
            p.finR = 1
            p.finWave = s * 0.65
            p.hairSway = -s * 3
            p.earFlutter = abs(s) * 2
        case .waving:
            p.eyeArt = "excited"
            p.mouthArt = "smile-open"
            p.finR = 1.15
            p.finWave = s * 1.4
            p.roll = s * 2
            p.hairSway = -s * 2
        case .dancing:
            p.eyeArt = "excited"
            p.mouthArt = "smile-open"
            p.roll = s * 6
            p.y = -abs(s) * 7
            p.finL = 0.8
            p.finR = 0.8
            p.finWave = s * 1.5
            p.hairSway = -s * 3.5
            p.earFlutter = s * 2
        case .shy:
            p.eyeArt = "shy"
            p.mouthArt = "smile"
            p.blush = 1
            p.gazeX = -0.65
            p.gazeY = 0.25
            p.roll = 4 + s * 0.8
            p.sy = 0.985
            p.finL = 0.55
            p.finR = 0.55
            p.finFold = 0.8
            p.hairSway = s * 0.8
        case .smug:
            p.eyeArt = "deadpan"
            p.mouthArt = "smug"
            p.blush = 0.35
            p.roll = -4 + s
            p.smile = 1
            p.finL = 0.6
            p.finFold = 0.2
            p.y = -2
        case .crying:
            p.eyeArt = "sad"
            p.mouthArt = "sad"
            p.sorrow = 1
            p.tears = 1
            p.blush = 0.6
            p.y = 2 + abs(s2) * 3
            p.roll = s2 * 0.7
            p.finL = 0.7
            p.finR = 0.7
            p.finFold = 0.8
        case .sighing:
            let exhale = BotFishMath.smooth((phase - 0.35) / 0.45)
            p.eyeArt = phase < 0.35 ? "sleepy" : "laughing"
            p.mouthArt = phase < 0.35 ? "small-o" : "shocked"
            p.y = 2 * exhale - 2 * (1 - exhale)
            p.sy = 1 + 0.018 * sin(phase * Double.pi * 2)
            p.gazeY = 0.3
            p.breath = exhale
            p.roll = exhale * 2
        case .cheering:
            p.eyeArt = "excited"
            p.mouthArt = "laugh"
            p.finL = 0.65 + 0.5 * max(0, s)
            p.finR = 0.65 + 0.5 * max(0, -s)
            p.finWave = s * 0.6
            p.y = -abs(s) * 8
            p.decoration = "spark"
            p.hairSway = -s * 2
        case .bowing:
            let bow = BotFishMath.bump(phase, 0.12, 0.86)
            p.eyeArt = bow > 0.45 ? "laughing" : nil
            p.mouthArt = "smile"
            p.y = bow * 15
            p.sy = 1 - bow * 0.09
            p.sx = 1 + bow * 0.025
            p.roll = 0
            p.gazeY = bow * 0.6
            p.finL = 0.6
            p.finR = 0.6
            p.finFold = 0.5
            p.hairSway = -bow * 3
        case .shakingHead:
            let shake = sin(phase * Double.pi * 4) * BotFishMath.bump(phase, 0.08, 0.92)
            p.eyeArt = "sleepy"
            p.mouthArt = "pout"
            p.roll = shake * 6
            p.x = shake * 5
            p.gazeX = -shake * 0.5
            p.hairSway = -shake * 4
        case .clapping:
            let clap = (1 + cos(phase * Double.pi * 4)) * 0.5
            p.eyeArt = "laughing"
            p.mouthArt = "smile-open"
            p.finL = 1
            p.finR = 1
            p.finFold = 0.2 + 0.8 * clap
            p.finWave = s * 0.15
            p.y = -2 * clap
            p.blush = 0.5
            p.decoration = "spark"
        case .stretching:
            let stretch = BotFishMath.bump(phase, 0.05, 0.95)
            p.eyeArt = stretch > 0.5 ? "laughing" : "sleepy"
            p.mouthArt = stretch > 0.5 ? "small-o" : "smile"
            p.sy = 1 + 0.055 * stretch
            p.sx = 1 - 0.025 * stretch
            p.finL = 0.2 + stretch
            p.finR = 0.2 + stretch
            p.y = -5 * stretch
            p.finWave = stretch * 0.35
        case .yawning:
            let yawn = BotFishMath.bump(phase, 0.12, 0.85)
            p.eyeArt = yawn > 0.3 ? "laughing" : "sleepy"
            p.mouthArt = yawn > 0.3 ? "yawn" : "small-o"
            p.mouthWidth = 0.5 + 0.5 * yawn
            p.finR = 0.3 + 0.8 * yawn
            p.finFold = yawn * 0.7
            p.sy = 1 + 0.018 * yawn
            p.y = -2 * yawn
        case .kiss:
            let send = BotFishMath.bump(phase, 0.2, 0.8)
            p.eyeArt = "shy"
            p.mouthArt = "kiss"
            p.finR = 0.5 + 0.65 * send
            p.finFold = 0.8 * (1 - send)
            p.blush = 0.9
            p.roll = -3 * send
            p.decoration = "hearts"
        case .highFive:
            let up = BotFishMath.bump(phase, 0.05, 0.95)
            p.eyeArt = "excited"
            p.mouthArt = "smile-open"
            p.finR = 0.2 + 1.15 * up
            p.finWave = -0.4 * up
            p.roll = -3 * up
            p.y = -3 * up
            p.sx = 1 + 0.018 * up
            p.decoration = "spark"
        default:
            break
        }
        return p
    }
}

/// Critically damped spring, stepped in 1/120s substeps like the upstream
/// `Spring` class.
final class BotFishSpring {
    var value: Double
    var velocity = 0.0
    var target: Double
    let omega: Double

    init(_ value: Double = 0, omega: Double = 18) {
        self.value = value
        self.target = value
        self.omega = omega
    }

    @discardableResult
    func step(_ dt: Double) -> Double {
        var left = BotFishMath.clamp(dt, 0, 0.1)
        while left > 1e-8 {
            let h = min(left, 1.0 / 120.0)
            velocity += (-2 * omega * velocity - omega * omega * (value - target)) * h
            value += velocity * h
            left -= h
        }
        return value
    }

    var settled: Bool {
        abs(value - target) < 0.0002 && abs(velocity) < 0.0002
    }
}
