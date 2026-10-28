// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSH: task screen.
//
// PLAN W6-BACKGROUND: a pure-black SwiftUI screen the demo App can present while
// a long task runs, with a minimum-brightness hint and no timer, animation or
// per-frame state. The view redraws only when the caller rebuilds it with a new
// status line. The screen brightness reduction is best effort: iOS UIScreen is
// global, so the controller records the previous value and restores it on
// disappear. NOT_VERIFIED on a device.

import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Reads and writes the device screen brightness.
public protocol ScreenBrightnessControlling: Sendable {
    /// Current brightness (0...1), or `nil` when the platform has no such API.
    func screenBrightness() async -> Double?
    /// Sets the brightness (0...1); a no-op when unsupported.
    func setScreenBrightness(_ value: Double) async
}

/// iOS adapter over `UIScreen.main.brightness`; inert on macOS.
public struct PlatformScreenBrightness: ScreenBrightnessControlling {
    public init() {}

    public func screenBrightness() async -> Double? {
        #if canImport(UIKit)
        return await MainActor.run { Double(UIScreen.main.brightness) }
        #else
        return nil
        #endif
    }

    public func setScreenBrightness(_ value: Double) async {
        #if canImport(UIKit)
        let clamped = CGFloat(min(1, max(0, value)))
        await MainActor.run {
            UIScreen.main.brightness = clamped
        }
        #else
        _ = value
        #endif
    }
}

/// Saves, dims and restores the screen for ``TaskScreen``.
public final class TaskScreenBrightnessController: @unchecked Sendable {
    /// Process-wide controller used by the default view.
    public static let shared = TaskScreenBrightnessController()

    private let screen: any ScreenBrightnessControlling
    private let lock = NSLock()
    private var savedBrightness: Double?
    private var dimmed = false

    /// Creates the controller.
    ///
    /// - Parameter screen: Brightness adapter; tests inject a recording one.
    public init(screen: any ScreenBrightnessControlling = PlatformScreenBrightness()) {
        self.screen = screen
    }

    /// `true` while the controller owns a dimmed screen.
    public var isDimmed: Bool { lock.withLock { dimmed } }

    /// Dims the screen once, remembering the previous brightness. Repeated
    /// calls do not overwrite the saved value.
    public func dim(minimum: Double = 0) async {
        let alreadyDimmed: Bool = lock.withLock {
            if dimmed { return true }
            dimmed = true
            return false
        }
        guard !alreadyDimmed else { return }
        let current = await screen.screenBrightness()
        lock.withLock { savedBrightness = current }
        await screen.setScreenBrightness(min(1, max(0, minimum)))
    }

    /// Restores the brightness saved by ``dim(minimum:)``. Idempotent.
    public func restore() async {
        let saved: Double? = lock.withLock {
            guard dimmed else { return nil }
            dimmed = false
            let value = savedBrightness
            savedBrightness = nil
            return value
        }
        if let saved {
            await screen.setScreenBrightness(saved)
        }
    }
}

/// Content of the black task screen.
public struct TaskScreenConfiguration: Equatable, Sendable {
    /// Headline shown in the centre (low-contrast by design).
    public var title: String
    /// Optional one-line task status. Updates only when the caller rebuilds
    /// the view; the screen itself owns no timer.
    public var status: String?
    /// Minimum-brightness hint. The default documents the behaviour.
    public var hint: String
    /// Whether appearing should lower the screen brightness.
    public var dimsScreen: Bool
    /// Brightness value used while dimmed (0 = minimum).
    public var minimumBrightness: Double

    public init(title: String = "Task running",
                status: String? = nil,
                hint: String = "Screen dimmed for long tasks. The phone can still lock manually.",
                dimsScreen: Bool = true,
                minimumBrightness: Double = 0) {
        self.title = title
        self.status = status
        self.hint = hint
        self.dimsScreen = dimsScreen
        self.minimumBrightness = min(1, max(0, minimumBrightness))
    }

    /// The default content.
    public static let `default` = TaskScreenConfiguration()
}

#if canImport(SwiftUI)
import SwiftUI

/// Pure-black task screen with a minimal redraw surface.
///
/// The body uses only static `Color`/`Text` values: there are no timers,
/// animations, `TimelineView`s or gestures that repaint. The App changes the
/// status by rebuilding the view with a different
/// ``TaskScreenConfiguration/status``.
public struct TaskScreen: View {
    /// The content.
    public let configuration: TaskScreenConfiguration
    private let brightness: TaskScreenBrightnessController

    /// Creates the screen.
    ///
    /// - Parameters:
    ///   - configuration: Title, status and hint.
    ///   - brightness: Brightness owner; the process-wide controller by
    ///     default. Tests can render with a recording controller.
    public init(configuration: TaskScreenConfiguration = .default,
                brightness: TaskScreenBrightnessController = .shared) {
        self.configuration = configuration
        self.brightness = brightness
    }

    public var body: some View {
        ZStack {
            // Pure black (#000000); no material, blur or image layers.
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                Text(configuration.title)
                    .font(.headline)
                    .foregroundStyle(Color(white: 0.55))
                if let status = configuration.status {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(Color(white: 0.38))
                }
                Text(configuration.hint)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color(white: 0.28))
            }
            .padding(28)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            guard configuration.dimsScreen else { return }
            let minimum = configuration.minimumBrightness
            Task {
                await brightness.dim(minimum: minimum)
            }
        }
        .onDisappear {
            Task {
                await brightness.restore()
            }
        }
    }
}
#endif
