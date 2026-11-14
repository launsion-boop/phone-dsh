// SPDX-License-Identifier: MIT

import UIKit

/// The app's deliberately tiny haptic vocabulary. Everything is a short
/// light/soft impact at low intensity: these are status cues, not alarms.
@MainActor
enum PhoneHaptics {
    /// The agent accepted the message and started working.
    static func thinking() {
        // `.soft` at low intensity was inaudible on the iPhone Air; `.light`
        // with a deliberately low intensity is the smallest cue we can feel.
        impact(.light, intensity: 0.34)
    }

    /// The turn settled (success, error or cancellation).
    static func completed() {
        impact(.light, intensity: 0.28)
    }

    /// A new approval/confirmation card is waiting for the user.
    static func approval() {
        impact(.light, intensity: 0.36)
    }

    private static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle,
                               intensity: CGFloat) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred(intensity: intensity)
    }
}
