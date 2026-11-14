// SPDX-License-Identifier: MIT

import UIKit

/// The app's deliberately tiny haptic vocabulary. Everything is a short
/// light/soft impact at low intensity: these are status cues, not alarms.
@MainActor
enum PhoneHaptics {
    /// The agent accepted the message and started working.
    static func thinking() {
        // `.soft` was inaudible on the iPhone Air; the approval card proves
        // `.light` is felt. Use that same actuator style at a slightly higher
        // strength, still a single short tap. Send and turn-start may both
        // call it; they share the thinking debounce.
        impact(.light, intensity: 0.42, dedupe: true)
    }

    /// The turn settled (success, error or cancellation).
    static func completed() {
        impact(.light, intensity: 0.34, dedupe: false)
    }

    /// A new approval/confirmation card is waiting for the user.
    static func approval() {
        impact(.light, intensity: 0.36, dedupe: false)
    }

    /// Send and the turn-start observer both want the thinking cue; suppress
    /// the second one so a normal send is exactly one tap.
    private static var lastImpactAt: CFTimeInterval = 0

    private static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle,
                               intensity: CGFloat, dedupe: Bool) {
        let now = CACurrentMediaTime()
        if dedupe {
            // A send tap and the runtime's turn-start observation describe the
            // same moment but can be a network round trip apart. Keep one cue.
            guard now - lastImpactAt > 1.5 else { return }
            lastImpactAt = now
        }
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred(intensity: intensity)
    }
}
