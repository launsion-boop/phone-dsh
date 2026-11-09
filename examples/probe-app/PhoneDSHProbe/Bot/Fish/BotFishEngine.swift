// SPDX-License-Identifier: MIT

// Swift port of dsh-bot `src/renderer/lib/fish/controller.js` (`FishStateMachine`)
// plus the per-view frame clock. The reference type lives in `@State`, so the
// springs and sprite cross-fade survive SwiftUI rebuilds.

import Foundation
import PhoneDSHBot
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
        pokeStart = time
        blinkStart = -.infinity
        lookOverride = nil
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

        if state == .idle, time - idleEntered >= 3000, time >= nextIdleAt,
           playing, !reduced, !isStatic {
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

        let pokeAge = time - pokeStart
        let poking = pokeAge >= 0 && pokeAge < 420
        let stateTime = (reduced || isStatic) ? 650 : elapsed
        var p = BotFishModel.sample(state: poking ? .poke : state,
                                    time: poking ? pokeAge : stateTime)

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

/// Owns the state machine and the Core Graphics renderer for one avatar view.
final class BotFishEngine {
    private let machine: BotFishStateMachine
    private let renderer = BotFishRenderer()
    private var lastTimestamp: TimeInterval?
    private var configuredState: BotFishLifecycle?
    private(set) var currentImage: UIImage?
    private(set) var hasRendered = false

    init() {
        machine = BotFishStateMachine()
        configuredState = machine.state
    }

    var needsAnimation: Bool { machine.needsAnimation }

    func configure(state: BotFishLifecycle, still: Bool, reduced: Bool) {
        // `.poke` is a transient: the machine keeps its lifecycle state, so
        // compare against the last requested value instead of machine.state.
        if configuredState != state {
            configuredState = state
            machine.setState(state)
            hasRendered = false
        }
        if machine.isStatic != still || machine.reduced != reduced {
            machine.updateFlags(isStatic: still, reduced: reduced)
            hasRendered = false
        }
    }

    func advance(at date: Date, state: BotFishLifecycle, still: Bool, reduced: Bool,
                 size: CGFloat, displayScale: CGFloat,
                 appearance: BotFishAppearance = .classic) -> UIImage? {
        configure(state: state, still: still, reduced: reduced)
        let timestamp = date.timeIntervalSinceReferenceDate
        let delta = lastTimestamp.map { min(100, max(0, (timestamp - $0) * 1000)) } ?? 0
        lastTimestamp = timestamp
        let params = machine.step(delta)
        currentImage = renderer.render(params, time: machine.time,
                                       size: size, displayScale: displayScale,
                                       appearance: appearance)
        hasRendered = true
        return currentImage
    }

    func poke() {
        machine.poke()
    }

    func resetClock() {
        lastTimestamp = nil
    }
}
