// SPDX-License-Identifier: MIT

// Swift port of dsh-bot `src/renderer/lib/fish/controller.js` (`FishStateMachine`)
// plus the per-view frame clock. The reference type lives in `@State`, so the
// springs and sprite cross-fade survive SwiftUI rebuilds.

import Foundation
import PhoneDSHBot
import SwiftUI
import UIKit

enum BotFishFaceKey: Hashable, CaseIterable {
    case eyeL, eyeR, joy, browL, browR, anger, sorrow, smile, mouth
    case mouthWidth, round, blush, tears, love, gazeX, gazeY
}

private extension BotFishParams {
    func faceValue(_ key: BotFishFaceKey) -> Double {
        switch key {
        case .eyeL: return eyeL
        case .eyeR: return eyeR
        case .joy: return joy
        case .browL: return browL
        case .browR: return browR
        case .anger: return anger
        case .sorrow: return sorrow
        case .smile: return smile
        case .mouth: return mouth
        case .mouthWidth: return mouthWidth
        case .round: return round
        case .blush: return blush
        case .tears: return tears
        case .love: return love
        case .gazeX: return gazeX
        case .gazeY: return gazeY
        }
    }

    mutating func setFaceValue(_ key: BotFishFaceKey, _ value: Double) {
        switch key {
        case .eyeL: eyeL = value
        case .eyeR: eyeR = value
        case .joy: joy = value
        case .browL: browL = value
        case .browR: browR = value
        case .anger: anger = value
        case .sorrow: sorrow = value
        case .smile: smile = value
        case .mouth: mouth = value
        case .mouthWidth: mouthWidth = value
        case .round: round = value
        case .blush: blush = value
        case .tears: tears = value
        case .love: love = value
        case .gazeX: gazeX = value
        case .gazeY: gazeY = value
        }
    }
}

final class BotFishStateMachine {
    private(set) var state: BotFishLifecycle
    private(set) var time: Double = 0
    private(set) var elapsed: Double = 0
    private(set) var isStatic: Bool
    private(set) var reduced: Bool

    private let playing = true
    private let random: () -> Double
    private var idleEntered: Double = 0
    private var nextIdleAt: Double = .infinity
    private var directGaze: (x: Double, y: Double)?
    private var lookOverride: (x: Double, y: Double, until: Double)?
    private var blinkStart: Double = -.infinity
    private var pokeStart: Double = -.infinity
    private var morphTarget: (x: Double, y: Double) = (1, 1)
    private var faceSprings: [BotFishFaceKey: BotFishSpring] = [:]
    private let gazeXSpring = BotFishSpring(0, omega: 23)
    private let gazeYSpring = BotFishSpring(0, omega: 23)
    private let headXSpring = BotFishSpring(0, omega: 8)
    private let headYSpring = BotFishSpring(0, omega: 8)
    private let bodyXSpring = BotFishSpring(0, omega: 5)
    private let bodyYSpring = BotFishSpring(0, omega: 5)
    private let morphXSpring = BotFishSpring(1, omega: 13)
    private let morphYSpring = BotFishSpring(1, omega: 13)
    private var artFrom: (eye: String?, mouth: String?)?
    private var artStart: Double = -.infinity
    private var last: BotFishParams?

    /// Agent-driven one-shot overlay. The lifecycle `state` stays authoritative
    /// underneath; this value only masks it until its TTL expires. Actions
    /// sample a full clip; expressions overlay the face on the lifecycle body.
    private var reaction: BotFishReaction?
    private var reactionLifecycle: BotFishLifecycle?
    private var reactionStart: Double = -.infinity

    var activeReaction: BotFishReaction? {
        guard let reaction, reactionLifecycle != nil,
              time >= reactionStart,
              time - reactionStart < Double(reaction.durationMs) else { return nil }
        return reaction
    }

    var hasActiveReaction: Bool { activeReaction != nil }

    init(state: BotFishLifecycle = .idle, reduced: Bool = false, isStatic: Bool = false,
         random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.state = state == .poke ? .idle : state
        self.reduced = reduced
        self.isStatic = isStatic
        self.random = random
        armIdle()
        if state == .poke { poke() }
    }

    private func armIdle() {
        nextIdleAt = state == .idle && playing && !reduced && !isStatic
            ? time + 6000 + BotFishMath.clamp(random(), 0, 1) * 6000
            : .infinity
    }

    func updateFlags(isStatic: Bool? = nil, reduced: Bool? = nil) {
        if let isStatic { self.isStatic = isStatic }
        if let reduced { self.reduced = reduced }
        armIdle()
    }

    /// The view's lifecycle input is authoritative; the caller (or the
    /// director above it) has already resolved priorities.
    @discardableResult
    func setState(_ value: BotFishLifecycle) -> Bool {
        if value == .poke {
            poke()
            return true
        }
        if value == state { return true }
        if let last {
            artFrom = (eye: last.eyeArt, mouth: last.mouthArt)
        } else {
            artFrom = nil
        }
        artStart = time
        state = value
        elapsed = 0
        lookOverride = nil
        blinkStart = -.infinity
        pokeStart = -.infinity
        idleEntered = time
        armIdle()
        return true
    }

    func poke() {
        if reaction?.kind == .action { clearReaction() }
        pokeStart = time
        blinkStart = -.infinity
        lookOverride = nil
    }

    /// Starts (or restarts) one Agent-driven reaction at the machine's current
    /// clock. The same reaction id is filtered by `BotFishEngine.configure`;
    /// this method always restarts if called directly.
    @discardableResult
    func playReaction(_ value: BotFishReaction) -> Bool {
        guard let lifecycle = value.lifecycle else { return false }
        artFrom = last.map { (eye: $0.eyeArt, mouth: $0.mouthArt) }
        artStart = time
        reaction = value
        reactionLifecycle = lifecycle
        reactionStart = time
        if value.kind == .action {
            pokeStart = -.infinity
            blinkStart = -.infinity
            lookOverride = nil
        }
        return true
    }

    func clearReaction() {
        guard reaction != nil else { return }
        artFrom = last.map { (eye: $0.eyeArt, mouth: $0.mouthArt) }
        artStart = time
        reaction = nil
        reactionLifecycle = nil
        reactionStart = -.infinity
    }

    private func expireReactionIfNeeded() {
        guard let reaction, time - reactionStart >= Double(reaction.durationMs) else { return }
        artFrom = last.map { (eye: $0.eyeArt, mouth: $0.mouthArt) }
        artStart = time
        self.reaction = nil
        reactionLifecycle = nil
        reactionStart = -.infinity
    }

    /// Static/reduced-motion sampling phase per action. A uniform 25% leaves
    /// shaking-head and clapping at their neutral crossing, so the gallery
    /// would label a blank pose as the gesture. These beats match the key
    /// frames in upstream `expressive.js`.
    private static let staticActionPhase: [String: Double] = [
        "waving": 0.25, "bowing": 0.50, "clapping": 0.125, "kiss": 0.50,
        "cheering": 0.25, "shy": 0.50, "smug": 0.50, "crying": 0.50,
        "sighing": 0.60, "shaking-head": 0.125, "stretching": 0.50,
        "yawning": 0.50, "high-five": 0.50, "nod": 0.25,
        "celebrate": 0.25, "dancing": 0.25,
    ]

    private func reactionSampleTime(_ reaction: BotFishReaction, expression: Bool) -> Double {
        if isStatic || reduced {
            // A still/gallery frame must show the gesture's recognisable beat,
            // not its neutral first frame; expressions match upstream's 650 ms
            // frozen sample.
            if expression { return 650 }
            let phase = Self.staticActionPhase[reaction.name] ?? 0.25
            return max(1, Double(reaction.durationMs) * phase)
        }
        return max(0, time - reactionStart)
    }

    private func blink() {
        blinkStart = time
    }

    private func spring(for key: BotFishFaceKey, initial: Double) -> BotFishSpring {
        if let existing = faceSprings[key] { return existing }
        let spring = BotFishSpring(initial, omega: 22)
        faceSprings[key] = spring
        return spring
    }

    @discardableResult
    func step(_ dtMilliseconds: Double) -> BotFishParams {
        let dt = BotFishMath.clamp(dtMilliseconds, 0, 100)
        time += dt
        if playing && !isStatic {
            elapsed += dt
        }

        if state == .idle, reaction == nil, time - idleEntered >= 3000,
           time >= nextIdleAt, playing, !reduced, !isStatic {
            if random() < 0.6 {
                blink()
            } else {
                let directions: [(x: Double, y: Double)] = [(-0.8, 0), (0.8, 0), (0, -0.7)]
                let index = min(2, Int(floor(random() * 3)))
                let direction = directions[index]
                lookOverride = (direction.x, direction.y, time + 700)
            }
            armIdle()
        }

        expireReactionIfNeeded()
        let pokeAge = time - pokeStart
        let poking = pokeAge >= 0 && pokeAge < 420
        let stateTime = (reduced || isStatic) ? 650 : elapsed
        let active = activeReaction
        let action = active?.kind == .action ? active : nil
        let expression = active?.kind == .expression ? active : nil
        let sampledState: BotFishLifecycle
        let sampledTime: Double
        if poking {
            sampledState = .poke
            sampledTime = pokeAge
        } else if let action, let actionLifecycle = reactionLifecycle {
            sampledState = actionLifecycle
            sampledTime = reactionSampleTime(action, expression: false)
        } else {
            sampledState = state
            sampledTime = stateTime
        }
        var p = BotFishModel.sample(state: sampledState, time: sampledTime)
        if !poking, let expression, let expressionLifecycle = reactionLifecycle {
            // Upstream expressive.js: an expression only changes the face and
            // art, never the body pose or displacement.
            let face = BotFishModel.sample(
                state: expressionLifecycle,
                time: reactionSampleTime(expression, expression: true))
            for key in BotFishFaceKey.allCases {
                p.setFaceValue(key, face.faceValue(key))
            }
            p.eyeArt = face.eyeArt
            p.mouthArt = face.mouthArt
            p.puff = face.puff
            if expressionLifecycle == .love { p.decoration = "hearts" }
        }

        for key in BotFishFaceKey.allCases {
            let target = p.faceValue(key)
            let spring = spring(for: key, initial: target)
            spring.target = target
            if reduced || isStatic {
                spring.value = target
                spring.velocity = 0
            }
            p.setFaceValue(key, spring.step(dt / 1000))
        }

        if let look = lookOverride, time >= look.until {
            lookOverride = nil
        }
        let gaze = lookOverride.map { ($0.x, $0.y) } ?? directGaze ?? (0, 0)

        gazeXSpring.target = BotFishMath.clamp(gaze.0 + p.gazeX, -1, 1)
        gazeYSpring.target = BotFishMath.clamp(gaze.1 + p.gazeY, -1, 1)
        if reduced || isStatic {
            gazeXSpring.value = gazeXSpring.target
            gazeYSpring.value = gazeYSpring.target
        }
        p.gazeX = gazeXSpring.step(dt / 1000)
        p.gazeY = gazeYSpring.step(dt / 1000)

        headXSpring.target = gaze.0
        headYSpring.target = gaze.1
        p.headX = headXSpring.step(dt / 1000)
        p.headY = headYSpring.step(dt / 1000)
        bodyXSpring.target = p.headX
        bodyYSpring.target = p.headY
        p.bodyX = bodyXSpring.step(dt / 1000)
        p.bodyY = bodyYSpring.step(dt / 1000)
        p.x += p.bodyX * 1.6
        p.y += p.bodyY * 0.9
        p.roll += p.bodyX * 0.35

        let blinkAge = time - blinkStart
        var blink = 1.0
        if blinkAge >= 0, blinkAge < 260 {
            let q = blinkAge / 260
            blink = q < 0.45 ? 1 - q / 0.45 : (q - 0.45) / 0.55
        }
        p.blink = max(0.02, blink)

        morphXSpring.target = morphTarget.x
        morphYSpring.target = morphTarget.y
        p.morphX = morphXSpring.step(dt / 1000)
        p.morphY = morphYSpring.step(dt / 1000)

        if reduced || isStatic {
            p.headX = 0
            p.headY = 0
            p.bodyX = 0
            p.bodyY = 0
        }
        if reduced {
            p.hairSway = 0
            p.earFlutter = 0
            p.x = 0
            p.y = 0
            p.roll = 0
            p.sx = 1
            p.sy = 1
            p.morphX = 1
            p.morphY = 1
            p.finWave = 0
        }

        p.artMix = (reduced || isStatic) ? 1 : BotFishMath.clamp((time - artStart) / 180, 0, 1)
        p.eyeArtPrev = artFrom?.eye
        p.mouthArtPrev = artFrom?.mouth
        last = p
        return p
    }

    var needsAnimation: Bool {
        if reaction != nil { return true }
        let clip = BotFishClip.forState(state)
        let continuous = playing && !reduced && !isStatic && !clip.isStatic
            && (clip.period != nil || elapsed < (clip.duration ?? 0))
        if continuous { return true }
        if !reduced, !isStatic, time - artStart < 180 { return true }
        let pokeAge = time - pokeStart
        if pokeAge >= 0, pokeAge < 420 { return true }
        let blinkAge = time - blinkStart
        if blinkAge >= 0, blinkAge < 260 { return true }
        if lookOverride != nil { return true }
        for spring in [gazeXSpring, gazeYSpring, headXSpring, headYSpring,
                       bodyXSpring, bodyYSpring, morphXSpring, morphYSpring] where !spring.settled {
            return true
        }
        for spring in faceSprings.values where !spring.settled {
            return true
        }
        return false
    }
}

/// One display-ready frame. The two layers are already at the output pixel
/// size; the pose is applied by SwiftUI on the GPU.
struct BotFishFrame {
    var base: Image
    var face: Image
    var baseID: ObjectIdentifier
    var faceID: ObjectIdentifier
    var pose: BotFishPose = BotFishPose()
    var alpha: Double = 1
}

/// Owns the state machine and the Core Graphics renderer for one avatar view.
final class BotFishEngine {
    private let machine: BotFishStateMachine
    private let renderer = BotFishRenderer()
    private var lastTimestamp: TimeInterval?
    private var configuredState: BotFishLifecycle?
    private(set) var currentFrame: BotFishFrame?
    private var configuredReactionID: String?

    /// 0.25 output pixel, matching the renderer's pose quantisation. Scale is
    /// quantised so the edge of the crop moves by the same threshold; roll
    /// uses the 0.1° requested by the acceptance criteria.
    private static let offsetQuantum: CGFloat = 0.25
    private static let rollQuantum = 0.1

    init() {
        machine = BotFishStateMachine()
        configuredState = machine.state
    }

    var needsAnimation: Bool { machine.needsAnimation }

    func configure(state: BotFishLifecycle, still: Bool, reduced: Bool,
                   reaction: BotFishReaction? = nil) {
        // `.poke` is a transient: the machine keeps its lifecycle state, so
        // compare against the last requested value instead of machine.state.
        if configuredState != state {
            configuredState = state
            machine.setState(state)
        }
        if machine.isStatic != still || machine.reduced != reduced {
            machine.updateFlags(isStatic: still, reduced: reduced)
        }
        // Dedupe by reaction id: SwiftUI can re-render or rebuild the view for
        // unrelated inputs, but one Agent call must play exactly once.
        if configuredReactionID != reaction?.id {
            configuredReactionID = reaction?.id
            if let reaction {
                _ = machine.playReaction(reaction)
            } else {
                machine.clearReaction()
            }
        }
    }

    func advance(at date: Date, state: BotFishLifecycle, still: Bool, reduced: Bool,
                 size: CGFloat, displayScale: CGFloat,
                 appearance: BotFishAppearance = .classic,
                 crowned: Bool = false,
                 reaction: BotFishReaction? = nil) -> BotFishFrame? {
        configure(state: state, still: still, reduced: reduced, reaction: reaction)
        let timestamp = date.timeIntervalSinceReferenceDate
        let delta = lastTimestamp.map { min(100, max(0, (timestamp - $0) * 1000)) } ?? 0
        lastTimestamp = timestamp
        var params = machine.step(delta)

        // Small avatars get the upstream 2.2× readable-motion boost. The
        // boost is part of the pose now, so it no longer forces a repaint.
        let boost = BotFishRenderer.motionBoost(for: size)
        params.motionScale = boost
        if boost > 1 {
            params.x = BotFishMath.clamp(params.x * boost,
                                         -BotFishRenderer.motionBoostMaxTranslation,
                                         BotFishRenderer.motionBoostMaxTranslation)
            params.y = BotFishMath.clamp(params.y * boost,
                                         -BotFishRenderer.motionBoostMaxTranslation,
                                         BotFishRenderer.motionBoostMaxTranslation)
            params.roll = BotFishMath.clamp(params.roll * boost,
                                            -BotFishRenderer.motionBoostMaxRoll,
                                            BotFishRenderer.motionBoostMaxRoll)
        }

        let target = BotFishRenderer.pixelSide(size: size, displayScale: displayScale)
        guard let prepared = renderer.prepare(params, time: machine.time, size: size,
                                              displayScale: displayScale,
                                              appearance: appearance,
                                              crowned: crowned) else {
            return currentFrame
        }
        let baseID = ObjectIdentifier(prepared.base)
        let faceID = ObjectIdentifier(prepared.face)
        let pose = Self.pose(params, size: size, pixelSide: target, crowned: crowned)
        let alpha = Self.quantisedAlpha(params.alpha)
        if var frame = currentFrame {
            var changed = false
            if frame.baseID != baseID {
                frame.base = Image(decorative: prepared.base, scale: 1, orientation: .up)
                frame.baseID = baseID
                changed = true
            }
            if frame.faceID != faceID {
                frame.face = Image(decorative: prepared.face, scale: 1, orientation: .up)
                frame.faceID = faceID
                changed = true
            }
            if frame.pose != pose {
                frame.pose = pose
                changed = true
            }
            if frame.alpha != alpha {
                frame.alpha = alpha
                changed = true
            }
            if changed { currentFrame = frame }
        } else {
            currentFrame = BotFishFrame(
                base: Image(decorative: prepared.base, scale: 1, orientation: .up),
                face: Image(decorative: prepared.face, scale: 1, orientation: .up),
                baseID: baseID, faceID: faceID, pose: pose, alpha: alpha)
        }
        return currentFrame
    }

    func poke() {
        machine.poke()
    }

    func resetClock() {
        lastTimestamp = nil
    }

    private static func pose(_ p: BotFishParams, size: CGFloat,
                             pixelSide: Int, crowned: Bool) -> BotFishPose {
        let target = CGFloat(max(1, pixelSide))
        let cropSide = crowned ? BotFishRenderer.crownedCropSide : BotFishRenderer.cropSide
        let pixelScale = target / cropSide
        let pointsPerPixel = max(1, size) / target
        func offset(_ value: Double) -> CGFloat {
            let pixels = CGFloat(value) * pixelScale
            return (pixels / offsetQuantum).rounded() * offsetQuantum * pointsPerPixel
        }
        let scaleQuantum = 0.5 / target
        func scale(_ value: Double) -> Double {
            (value / Double(scaleQuantum)).rounded() * Double(scaleQuantum)
        }
        return BotFishPose(
            offsetX: offset(p.x),
            offsetY: offset(p.y),
            roll: (p.roll / rollQuantum).rounded() * rollQuantum,
            scaleX: scale(p.sx * p.morphX),
            scaleY: scale(p.sy * p.morphY))
    }

    private static func quantisedAlpha(_ value: Double) -> Double {
        (BotFishMath.clamp(value, 0, 1) * 64).rounded() / 64
    }
}
