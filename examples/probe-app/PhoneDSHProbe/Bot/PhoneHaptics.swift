// SPDX-License-Identifier: MIT

import UIKit

/// The app's deliberately tiny haptic vocabulary. Everything is a short
/// light/soft impact at low intensity: these are status cues, not alarms.
@MainActor
enum PhoneHaptics {
    /// The agent accepted the message and started working.
    static func thinking() {
        // `.soft` at low intensity was inaudible on the iPhone Air. `.medium`
        // at low strength is still a short, gentle tap but has enough travel
        // to be felt over the keyboard; send and turn-start may both call it.
        impact(.medium, intensity: 0.28)
    }

    /// The turn settled (success, error or cancellation).
    static func completed() {
        impact(.light, intensity: 0.30)
    }

    /// A new approval/confirmation card is waiting for the user.
    static func approval() {
        impact(.light, intensity: 0.36)
    }

    /// Send and the turn-start observer both want the thinking cue; suppress
    /// the second one so a normal send is exactly one tap.
    private static var lastImpactAt: CFTimeInterval = 0

    private static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle,
                               intensity: CGFloat) {
        let now = CACurrentMediaTime()
        guard now - lastImpactAt > 0.35 else { return }
        lastImpactAt = now
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred(intensity: intensity)
    }
}
