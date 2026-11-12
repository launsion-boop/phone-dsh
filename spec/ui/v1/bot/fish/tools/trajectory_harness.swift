// SPDX-License-Identifier: MIT

// Fish trajectory harness.
//
// This file is compiled together with the *original* app fish sources
// (`examples/probe-app/PhoneDSHProbe/Bot/Fish/BotFish{Model,Engine,Renderer,
// Assets,ImageCache,LivelyMotion,MotionProfile}.swift`) by
// `generate_trajectory.py`. It emits the numeric model output the frozen
// contract in `spec/ui/v1/bot/fish/fish.md` describes: the state-machine
// parameters, the view-layer pose quantisation and the LUT.
//
// Nothing here re-implements the model. The harness only:
//   * defines the fixture cases (inputs and the fixed time grid),
//   * drives `BotFishStateMachine` and `BotFishEngine` from the app code,
//   * serialises their values.
//
// The one local algorithm is the fixture RNG (a 32-bit LCG). Its consumed
// prefix is emitted in every case so a second implementation never needs a
// system RNG.
//
// Usage: FishHarness --out <path>   (assets must be next to the executable)
// Exit codes: 0 ok, 2 model/asset failure.

import Foundation
import PhoneDSHBot
import UIKit

// MARK: - Failure

func harnessFail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("trajectory_harness: \(message)\n".utf8))
    exit(2)
}

// MARK: - Deterministic JSON numbers

func r12(_ value: Double) -> Double {
    guard value.isFinite else { harnessFail("non-finite number in output") }
    let rounded = (value * 1_000_000_000_000).rounded() / 1_000_000_000_000
    return rounded == 0 ? 0 : rounded
}

func num(_ value: Double) -> Any { NSNumber(value: r12(value)) }
func num(_ value: CGFloat) -> Any { NSNumber(value: r12(Double(value))) }
func optString(_ value: String?) -> Any { value ?? NSNull() }

// MARK: - Fixture RNG

/// 32-bit LCG (Numerical Recipes). The fixture seed and the consumed prefix
/// are both in the golden, so no end calls a system RNG.
final class FixtureRandom {
    private var state: UInt64
    private(set) var values: [Double] = []

    init(seed: UInt64) {
        state = seed == 0 ? 1 : seed & 0xffff_ffff
    }

    func next() -> Double {
        state = (1_664_525 &* state &+ 1_013_904_223) & 0xffff_ffff
        let value = Double(state) / 4_294_967_296.0
        values.append(r12(value))
        return value
    }
}

// MARK: - Lifecycle order

/// `BotFishLifecycle` is not `CaseIterable`; this is the declaration order of
/// `Sources/PhoneDSHBot/Avatar/BotFishDirector.swift`. The count is asserted
/// below so a new case cannot silently escape the clip table.
let lifecycleNames: [String] = [
    "idle", "thinking", "streaming", "working", "sleeping", "alerting",
    "listening", "speaking", "happy", "sad",
    "surprised", "confused", "laughing", "love", "angry", "wink", "nod",
    "shrug", "celebrate", "poke",
    "waking", "waiting", "loading", "done", "standby",
    "spawning", "bouncing", "dancing", "waving",
    "shy", "smug", "crying", "sighing", "cheering", "bowing", "clapping",
    "stretching", "yawning", "kiss", "shaking-head", "high-five",
    "powering-down",
]

func lifecycle(_ raw: String) -> BotFishLifecycle {
    guard let value = BotFishLifecycle(rawValue: raw) else {
        harnessFail("unknown lifecycle \(raw)")
    }
    return value
}

// MARK: - Case definitions

struct ReactionSpec {
    let name: String
    let startStep: Int
}

struct CaseSpec {
    let name: String
    let group: String
    let state: BotFishLifecycle
    let color: BotFishColor
    let hairstyle: BotFishHairstyle
    let crowned: Bool
    let sizePt: Double
    let displayScale: Double
    let still: Bool
    let reduced: Bool
    let profile: BotFishMotionProfile
    let workStyle: BotFishWorkStyle
    let seed: UInt64
    let dtMs: Double
    let steps: Int
    let sampleSteps: [Int]?
    let reaction: ReactionSpec?
    let pokeAtStep: Int?
}

let defaultDT = 1000.0 / 60.0

func makeCase(_ name: String, group: String,
              state: BotFishLifecycle = .idle,
              color: BotFishColor = .blue,
              hairstyle: BotFishHairstyle = .long,
              crowned: Bool = false,
              sizePt: Double = 64,
              displayScale: Double = 2,
              still: Bool = false,
              reduced: Bool = false,
              profile: BotFishMotionProfile = .standard,
              workStyle: BotFishWorkStyle = .generic,
              seed: UInt64 = 1,
              dtMs: Double = defaultDT,
              steps: Int = 0,
              sampleSteps: [Int]? = [0],
              reaction: ReactionSpec? = nil,
              pokeAtStep: Int? = nil) -> CaseSpec {
    CaseSpec(name: name, group: group, state: state, color: color,
             hairstyle: hairstyle, crowned: crowned, sizePt: sizePt,
             displayScale: displayScale, still: still, reduced: reduced,
             profile: profile, workStyle: workStyle, seed: seed,
             dtMs: dtMs, steps: steps, sampleSteps: sampleSteps,
             reaction: reaction, pokeAtStep: pokeAtStep)
}

func stepIndex(_ milliseconds: Double, dtMs: Double = defaultDT) -> Int {
    Int((milliseconds / dtMs).rounded())
}

func p0Cases() -> [CaseSpec] {
    let states = ["idle", "thinking", "streaming", "working", "sleeping",
                  "alerting", "listening", "speaking", "happy", "sad"]
    let sample = [0, stepIndex(250), stepIndex(500), stepIndex(1000),
                  stepIndex(2000), stepIndex(4000)]
    return states.map { raw in
        makeCase("p0-\(raw)", group: "p0", state: lifecycle(raw),
                 steps: stepIndex(4000), sampleSteps: sample)
    }
}

func samplingCases() -> [CaseSpec] {
    [
        makeCase("sample-idle-32", group: "sampling", state: .idle,
                 sizePt: 32, displayScale: 3,
                 steps: stepIndex(500), sampleSteps: [0, stepIndex(250), stepIndex(500)]),
        makeCase("sample-alerting-32", group: "sampling", state: .alerting,
                 sizePt: 32, displayScale: 3,
                 steps: stepIndex(500), sampleSteps: [0, stepIndex(250), stepIndex(500)]),
        makeCase("sample-idle-crowned", group: "sampling", state: .idle,
                 crowned: true, steps: 0, sampleSteps: [0]),
        makeCase("sample-alerting-crowned", group: "sampling", state: .alerting,
                 crowned: true, steps: stepIndex(500),
                 sampleSteps: [0, stepIndex(250), stepIndex(500)]),
        makeCase("sample-standby", group: "sampling", state: .standby,
                 steps: 0, sampleSteps: [0]),
    ]
}

func oneShotCases() -> [CaseSpec] {
    var result: [CaseSpec] = []
    result.append(makeCase("one-shot-poke", group: "one-shot", state: .poke,
                           steps: stepIndex(500),
                           sampleSteps: [0, stepIndex(200), stepIndex(416.6667),
                                         stepIndex(433.3333), stepIndex(500)]))
    let actions: [(String, Double, [Double])] = [
        ("celebrate", 1500, [0, 750, 1483.3333, 1500, 1600]),
        ("waving", 1600, [0, 800, 1583.3333, 1600, 1700]),
        ("bowing", 2800, [0, 1400, 2783.3333, 2800, 2900]),
    ]
    for (name, _, times) in actions {
        result.append(makeCase("one-shot-\(name)-reaction", group: "one-shot",
                               state: .idle, steps: stepIndex(times.last!),
                               sampleSteps: times.map { stepIndex($0) },
                               reaction: ReactionSpec(name: name, startStep: 0)))
    }
    result.append(makeCase("one-shot-happy-expression", group: "one-shot",
                           state: .working, steps: stepIndex(4100),
                           sampleSteps: [0, stepIndex(2000), 239,
                                         stepIndex(4000), stepIndex(4100)],
                           reaction: ReactionSpec(name: "happy", startStep: 0)))
    result.append(makeCase("still-idle", group: "still-reduced", state: .idle,
                           still: true, steps: 0, sampleSteps: [0]))
    result.append(makeCase("still-reaction-bowing", group: "still-reduced",
                           state: .idle, still: true, steps: 0,
                           sampleSteps: [0],
                           reaction: ReactionSpec(name: "bowing", startStep: 0)))
    result.append(makeCase("reduced-thinking", group: "still-reduced",
                           state: .thinking, reduced: true, steps: 0,
                           sampleSteps: [0]))
    result.append(makeCase("reduced-reaction-celebrate", group: "still-reduced",
                           state: .idle, reduced: true, steps: 0,
                           sampleSteps: [0],
                           reaction: ReactionSpec(name: "celebrate", startStep: 0)))
    return result
}

func appearanceCases() -> [CaseSpec] {
    var result: [CaseSpec] = []
    for color in BotFishColor.allCases {
        for hairstyle in BotFishHairstyle.allCases {
            result.append(makeCase("appearance-\(color.rawValue)-\(hairstyle.rawValue)",
                                   group: "appearance", state: .idle,
                                   color: color, hairstyle: hairstyle,
                                   steps: 0, sampleSteps: [0]))
        }
    }
    return result
}

func livelyCases() -> [CaseSpec] {
    var result: [CaseSpec] = []
    for style in BotFishWorkStyle.allCases {
        result.append(makeCase("lively-working-\(style.rawValue)", group: "lively",
                               state: .working, sizePt: 28, displayScale: 3,
                               profile: .lively, workStyle: style,
                               steps: stepIndex(500),
                               sampleSteps: [stepIndex(500)]))
    }
    for state in ["streaming", "speaking", "celebrate", "done"] {
        result.append(makeCase("lively-\(state)", group: "lively",
                               state: lifecycle(state), sizePt: 28, displayScale: 3,
                               profile: .lively, steps: stepIndex(500),
                               sampleSteps: [stepIndex(500)]))
    }
    // Celebration is a 1.2s one-shot that holds its final pose after the clip.
    result.append(makeCase("lively-celebrate-after-clip", group: "lively",
                           state: .celebrate, sizePt: 28, displayScale: 3,
                           profile: .lively, steps: stepIndex(1600),
                           sampleSteps: [stepIndex(1200), stepIndex(1600)]))
    return result
}

func replayCases() -> [CaseSpec] {
    [
        makeCase("replay-standard-poke-celebrate", group: "replay",
                 state: .working, seed: 7, steps: 240, sampleSteps: nil,
                 reaction: ReactionSpec(name: "celebrate", startStep: 61),
                 pokeAtStep: 31),
        makeCase("replay-lively-idle-blink", group: "replay", state: .idle,
                 sizePt: 28, displayScale: 3, profile: .lively,
                 seed: 11, steps: 300, sampleSteps: nil),
        makeCase("replay-lively-thinking-reading", group: "replay",
                 state: .thinking, sizePt: 28, displayScale: 3,
                 profile: .lively, workStyle: .reading,
                 seed: 13, steps: 240, sampleSteps: nil),
    ]
}

// MARK: - Serialisation

func paramsJSON(_ p: BotFishParams) -> [String: Any] {
    [
        "eyeL": num(p.eyeL), "eyeR": num(p.eyeR), "joy": num(p.joy),
        "browL": num(p.browL), "browR": num(p.browR),
        "anger": num(p.anger), "sorrow": num(p.sorrow), "smile": num(p.smile),
        "mouth": num(p.mouth), "mouthWidth": num(p.mouthWidth),
        "round": num(p.round), "blush": num(p.blush), "tears": num(p.tears),
        "love": num(p.love), "gazeX": num(p.gazeX), "gazeY": num(p.gazeY),
        "roll": num(p.roll), "y": num(p.y), "x": num(p.x),
        "sx": num(p.sx), "sy": num(p.sy), "alpha": num(p.alpha),
        "finL": num(p.finL), "finR": num(p.finR), "finWave": num(p.finWave),
        "decoration": p.decoration, "progress": num(p.progress),
        "phase": num(p.phase),
        "eyeArt": optString(p.eyeArt), "mouthArt": optString(p.mouthArt),
        "finFold": num(p.finFold), "hairSway": num(p.hairSway),
        "earFlutter": num(p.earFlutter), "puff": num(p.puff),
        "breath": num(p.breath),
        "headX": num(p.headX), "headY": num(p.headY),
        "bodyX": num(p.bodyX), "bodyY": num(p.bodyY),
        "blink": num(p.blink), "morphX": num(p.morphX), "morphY": num(p.morphY),
        "artMix": num(p.artMix),
        "eyeArtPrev": optString(p.eyeArtPrev),
        "mouthArtPrev": optString(p.mouthArtPrev),
        "motionScale": num(p.motionScale),
        "gazeEmphasis": num(p.gazeEmphasis),
        "dotLift": num(p.dotLift), "dotScale": num(p.dotScale),
        "dotStagger": num(p.dotStagger),
        "isLivelyMotion": p.isLivelyMotion,
    ]
}

func poseJSON(_ pose: BotFishPose) -> [String: Any] {
    [
        "offsetX": num(pose.offsetX), "offsetY": num(pose.offsetY),
        "roll": num(pose.roll),
        "scaleX": num(pose.scaleX), "scaleY": num(pose.scaleY),
    ]
}

func clipJSON(_ clip: BotFishClip) -> [String: Any] {
    [
        "period": clip.period.map { num($0) } ?? NSNull(),
        "duration": clip.duration.map { num($0) } ?? NSNull(),
        "isStatic": clip.isStatic,
    ]
}

func rgb255(_ color: UIColor) -> [Int] {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let converted = color.cgColor.converted(to: space, intent: .defaultIntent,
                                                 options: nil),
          let components = converted.components,
          components.count >= 3 else {
        harnessFail("cannot convert palette colour to sRGB")
    }
    return [
        Int((components[0] * 255).rounded()),
        Int((components[1] * 255).rounded()),
        Int((components[2] * 255).rounded()),
    ]
}

func paletteJSON(_ color: BotFishColor) -> [String: Any] {
    let palette = BotFishPalette(color: color)
    return [
        "id": color.rawValue,
        "hex": color.hex,
        "lut": palette.lut.map { Int($0) },
        "ink": rgb255(palette.ink),
        "mid": rgb255(palette.mid),
        "light": rgb255(palette.light),
    ]
}

/// FISH-1: head-slice quantisation and restore must use the active profile's
/// quantum end to end. The inputs are raw source-space values; levels and
/// displacement come from the shared `BotFishHeadSlice` in PhoneDSHBot.
func headSliceJSON() -> [String: Any] {
    let specs: [(String, Bool, Double, Double, Double, Double)] = [
        ("standard-values", false, 0.37, -0.42, 1.03, -0.28),
        ("standard-half-away", false, 0.05, -0.05, 0.15, -0.15),
        ("standard-identity", false, 0, 0, 0, 0),
        ("lively-values", true, 0.37, -0.42, 1.03, -0.28),
        ("lively-half-away", true, 0.125, -0.125, 0.375, -0.375),
        ("lively-identity", true, 0, 0, 0, 0),
    ]
    let cases = specs.map { id, lively, headX, headY, hairSway, earFlutter -> [String: Any] in
        let quantum = BotFishHeadSlice.quantum(lively: lively)
        let levels = BotFishHeadSlice.levels(
            headX: headX, headY: headY, hairSway: hairSway,
            earFlutter: earFlutter, quantum: quantum)
        let displacement = BotFishHeadSlice.displacement(levels, quantum: quantum)
        return [
            "id": id,
            "profile": lively ? "lively" : "standard",
            "quantum": num(quantum),
            "input": [
                "headX": num(headX),
                "headY": num(headY),
                "hairSway": num(hairSway),
                "earFlutter": num(earFlutter),
            ],
            "levels": [
                "headX": num(Double(levels.headX)),
                "headY": num(Double(levels.headY)),
                "hairSway": num(Double(levels.hairSway)),
                "earFlutter": num(Double(levels.earFlutter)),
            ],
            "displacement": [
                "headX": num(displacement.headX),
                "headY": num(displacement.headY),
                "hairSway": num(displacement.hairSway),
                "earFlutter": num(displacement.earFlutter),
            ],
        ]
    }
    return [
        "profiles": [
            "standard": ["quantum": num(BotFishHeadSlice.standardQuantum)],
            "lively": ["quantum": num(BotFishHeadSlice.livelyQuantum)],
        ],
        "cases": cases,
    ]
}

// MARK: - Runner

func runCase(_ spec: CaseSpec) -> [String: Any] {
    let random = FixtureRandom(seed: spec.seed)
    let machine = BotFishStateMachine(random: { random.next() })
    let engine = BotFishEngine()
    let appearance = BotFishAppearance(color: spec.color, hairstyle: spec.hairstyle)
    let reaction: BotFishReaction? = spec.reaction.map { item in
        guard let kind = BotFishReactionVocabulary.kind(for: item.name),
              let duration = BotFishReactionVocabulary.durationMs(for: item.name)
        else { harnessFail("unknown reaction \(item.name)") }
        return BotFishReaction(id: "trajectory-\(spec.name)", kind: kind,
                               name: item.name, startedAt: 0, durationMs: duration)
    }
    let pixelSide = BotFishRenderer.pixelSide(size: CGFloat(spec.sizePt),
                                              displayScale: CGFloat(spec.displayScale))
    let boost = BotFishRenderer.motionBoost(for: CGFloat(spec.sizePt))

    var configuredState = machine.state
    var configuredProfile = machine.profile
    var configuredWorkStyle = machine.workStyle
    var configuredReactionID: String?
    var lastTimestamp: TimeInterval?
    var frames: [[String: Any]] = []
    let baseTimestamp = 1_000_000.0

    for step in 0...spec.steps {
        let date = Date(timeIntervalSinceReferenceDate:
            baseTimestamp + Double(step) * spec.dtMs / 1000.0)
        let timestamp = date.timeIntervalSinceReferenceDate
        let delta = lastTimestamp.map { min(100, max(0, (timestamp - $0) * 1000)) } ?? 0
        lastTimestamp = timestamp

        if spec.pokeAtStep == step {
            engine.poke()
        }
        let activeReaction: BotFishReaction? = {
            guard let specReaction = spec.reaction, let reaction else { return nil }
            return step >= specReaction.startStep ? reaction : nil
        }()
        let engineFrame = engine.advance(
            at: date, state: spec.state, still: spec.still, reduced: spec.reduced,
            size: CGFloat(spec.sizePt), displayScale: CGFloat(spec.displayScale),
            appearance: appearance, crowned: spec.crowned,
            reaction: activeReaction, profile: spec.profile,
            workStyle: spec.workStyle)

        // Mirror `BotFishEngine.configure` on the standalone machine. The
        // engine owns its own machine and does not expose its params, so the
        // numeric fixture is read from this machine while the pose is read
        // from the engine (the only real implementation of the view layer).
        if spec.pokeAtStep == step {
            machine.poke()
        }
        if configuredProfile != spec.profile || configuredWorkStyle != spec.workStyle {
            configuredProfile = spec.profile
            configuredWorkStyle = spec.workStyle
            machine.updateProfile(spec.profile, workStyle: spec.workStyle)
        }
        if configuredState != spec.state {
            configuredState = spec.state
            _ = machine.setState(spec.state)
        }
        if machine.isStatic != spec.still || machine.reduced != spec.reduced {
            machine.updateFlags(isStatic: spec.still, reduced: spec.reduced)
        }
        if configuredReactionID != activeReaction?.id {
            configuredReactionID = activeReaction?.id
            if let activeReaction {
                _ = machine.playReaction(activeReaction)
            } else {
                machine.clearReaction()
            }
        }

        let params = machine.step(delta)
        let needsAnimation = machine.needsAnimation

        let record = spec.sampleSteps == nil || spec.sampleSteps!.contains(step)
        if record {
            guard let engineFrame else {
                harnessFail("engine returned no frame at \(spec.name) step \(step) "
                    + "(BotFish assets are probably not next to the executable)")
            }
            var frame: [String: Any] = [
                "step": step,
                "timeMs": num(machine.time),
                "params": paramsJSON(params),
                "pose": poseJSON(engineFrame.pose),
                "alpha": num(engineFrame.alpha),
                "needsAnimation": needsAnimation,
                "static": spec.still || spec.reduced,
                "view": [
                    "motionScale": num(params.isLivelyMotion ? 1 : boost),
                    "pixelSide": pixelSide,
                ],
            ]
            if let sampledReaction = spec.reaction, step >= sampledReaction.startStep {
                frame["reactionActive"] = machine.hasActiveReaction
            }
            frames.append(frame)
        }
    }

    var json: [String: Any] = [
        "name": spec.name,
        "group": spec.group,
        "state": spec.state.rawValue,
        "appearance": [
            "color": spec.color.rawValue,
            "hairstyle": spec.hairstyle.rawValue,
        ],
        "crowned": spec.crowned,
        "viewport": [
            "sizePt": num(spec.sizePt),
            "displayScale": num(spec.displayScale),
            "pixelSide": pixelSide,
        ],
        "still": spec.still,
        "reduced": spec.reduced,
        "motionProfile": spec.profile.rawValue,
        "workStyle": spec.workStyle.rawValue,
        "seed": Int(spec.seed),
        "randomValues": random.values,
        "dtMs": num(spec.dtMs),
        "steps": spec.steps,
        "sampleSteps": spec.sampleSteps.map { $0 as Any } ?? NSNull(),
        "reaction": spec.reaction.map { item -> Any in
            let duration = BotFishReactionVocabulary.durationMs(for: item.name) ?? 0
            let kind = BotFishReactionVocabulary.kind(for: item.name)?.rawValue ?? ""
            return [
                "name": item.name,
                "kind": kind,
                "startStep": item.startStep,
                // Events are applied by `configure` before `step`; the
                // machine clock at that moment is (startStep - 1) * dt for
                // startStep >= 1, and 0 for the first step (which has dt = 0).
                "startTimeMs": num(item.startStep == 0
                    ? 0 : Double(item.startStep - 1) * spec.dtMs),
                "durationMs": Int(duration),
            ]
        } ?? NSNull(),
        "pokeAtStep": spec.pokeAtStep.map { $0 as Any } ?? NSNull(),
        "frames": frames,
    ]
    json["needsAnimationAtEnd"] = machine.needsAnimation
    return json
}

// MARK: - Main

func main() -> Never {
    var outputPath: String?
    var arguments = CommandLine.arguments.dropFirst()
    while let argument = arguments.first {
        arguments = arguments.dropFirst()
        switch argument {
        case "--out":
            guard let value = arguments.first else { harnessFail("--out needs a path") }
            arguments = arguments.dropFirst()
            outputPath = value
        case "--help":
            print("usage: FishHarness [--out PATH]")
            exit(0)
        default:
            harnessFail("unknown argument \(argument)")
        }
    }

    guard BotFishAssets.shared != nil else {
        harnessFail("BotFishAssets.shared is nil; put the BotFish asset folder "
            + "next to the executable")
    }
    guard lifecycleNames.count == 42 else {
        harnessFail("expected 42 lifecycle cases, found \(lifecycleNames.count)")
    }
    for name in lifecycleNames where BotFishLifecycle(rawValue: name) == nil {
        harnessFail("lifecycle \(name) no longer exists")
    }

    var clips: [String: Any] = [:]
    for name in lifecycleNames {
        clips[name] = clipJSON(BotFishClip.forState(lifecycle(name)))
    }

    var palettes: [[String: Any]] = []
    for color in BotFishColor.allCases {
        palettes.append(paletteJSON(color))
    }

    let cases = p0Cases() + samplingCases() + oneShotCases()
        + appearanceCases() + livelyCases() + replayCases()

    let geometry: [String: Any] = [
        "designCanvas": num(Double(BotFishRenderer.size)),
        "pad": num(Double(BotFishRenderer.pad)),
        "designScale": num(Double(BotFishRenderer.scale)),
        "crop": [
            "origin": [num(Double(BotFishRenderer.cropOrigin.x)),
                       num(Double(BotFishRenderer.cropOrigin.y))],
            "side": num(Double(BotFishRenderer.cropSide)),
        ],
        "crownedCrop": [
            "origin": [num(Double(BotFishRenderer.crownedCropOrigin.x)),
                       num(Double(BotFishRenderer.crownedCropOrigin.y))],
            "side": num(Double(BotFishRenderer.crownedCropSide)),
        ],
        "pivot": [
            "normal": [0.5, num(320.0 / Double(BotFishRenderer.cropSide))],
            "crowned": [0.5, num(340.0 / Double(BotFishRenderer.crownedCropSide))],
        ],
        "motionBoost": [
            "smallSize": num(Double(BotFishRenderer.motionBoostSmallSize)),
            "largeSize": num(Double(BotFishRenderer.motionBoostLargeSize)),
            "factor": num(BotFishRenderer.motionBoostFactor),
            "maxTranslation": num(BotFishRenderer.motionBoostMaxTranslation),
            "maxRoll": num(BotFishRenderer.motionBoostMaxRoll),
        ],
        "headSlicing": [
            "minimumSize": num(Double(BotFishRenderer.headSlicingMinimumSize)),
            "livelyMinimumSize": num(Double(BotFishRenderer.livelyHeadSlicingMinimumSize)),
            "quantum": num(BotFishRenderer.headSliceQuantum),
            "livelyQuantum": num(BotFishRenderer.livelyHeadSliceQuantum),
        ],
        "ink": rgb255(BotFishRenderer.designInk),
    ]

    let root: [String: Any] = [
        "schemaVersion": 1,
        "vector": "bot-fish-trajectory",
        "geometry": geometry,
        "clips": clips,
        "spriteOrder": [
            "eyes": BotFishEyeCel.names,
            "mouths": BotFishMouthCel.names,
        ],
        "palettes": palettes,
        "headSlice": headSliceJSON(),
        "cases": cases.map(runCase),
    ]

    let data: Data
    do {
        data = try JSONSerialization.data(withJSONObject: root,
                                          options: [.sortedKeys])
    } catch {
        harnessFail("cannot serialise output: \(error)")
    }
    if let outputPath {
        do {
            try data.write(to: URL(fileURLWithPath: outputPath))
        } catch {
            harnessFail("cannot write \(outputPath): \(error)")
        }
        let caseCount = (root["cases"] as? [Any])?.count ?? 0
        FileHandle.standardError.write(Data(
            "trajectory_harness: wrote \(caseCount) cases to \(outputPath)\n".utf8))
    } else {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
    exit(0)
}

main()
