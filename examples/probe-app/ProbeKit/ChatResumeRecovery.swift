// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — App-side resume recovery policy.
//
// The host owns the source of truth (`Parked -> Recovering -> Running` and the
// resume budgets); the App owns what the person sees while that runs. These
// predicates are pure so the decision table — rebuild once, then offer the
// manual button, queue a session switch or a send instead of refusing them —
// is tested without a host or WebKit.

import Foundation

/// One session switch the person requested while the engine was recovering.
public struct ChatPendingSessionSwitch: Equatable, Sendable {
    /// Existing session id, or `nil` for a new session.
    public var id: String?
    /// Preset for a new session.
    public var preset: String?

    public init(id: String?, preset: String? = nil) {
        self.id = id
        self.preset = preset
    }
}

/// What the App should do after one resume attempt failed.
public enum ChatResumeRecoveryDecision: Equatable, Sendable {
    /// Stop the old host, clear the old WKWebView and cold-boot once.
    case rebuildEngine
    /// The one automatic rebuild already failed: show the explicit Chinese
    /// error and the "重新启动引擎" button.
    case offerManualRestart
}

public enum ChatResumeRecovery {
    /// One automatic full rebuild per foreground return, as required by the
    /// device incident: the first resume may rebuild; a second failure is
    /// manual.
    public static let maximumAutomaticRebuilds = 1
    /// Show the slower message after this many seconds of recovery.
    public static let slowThreshold: TimeInterval = 5

    public static let recoveringText = "引擎恢复中…"
    public static let slowText = "恢复较慢，正在重新启动引擎…"
    public static let queuedSessionHint = "恢复完成后自动切换"
    public static let queuedPromptHint = "恢复完成后自动发送"
    public static let manualRestartText = "引擎恢复失败，请点击「重新启动引擎」重试"

    /// True while the App must hold queued actions instead of refusing them.
    public static func isRecovering(parked: Bool,
                                    hostLifecycleTransition: Bool,
                                    rebuilding: Bool) -> Bool {
        parked || hostLifecycleTransition || rebuilding
    }

    public static func decision(afterResumeFailure automaticRebuildsUsed: Int)
        -> ChatResumeRecoveryDecision {
        automaticRebuildsUsed < maximumAutomaticRebuilds
            ? .rebuildEngine : .offerManualRestart
    }

    /// A session switch during recovery is remembered, never refused.
    public static func shouldQueueSessionSwitch(parked: Bool,
                                                hostLifecycleTransition: Bool,
                                                rebuilding: Bool) -> Bool {
        isRecovering(parked: parked,
                     hostLifecycleTransition: hostLifecycleTransition,
                     rebuilding: rebuilding)
    }

    /// A send during recovery is queued, never dropped and never refused.
    public static func shouldQueuePrompt(parked: Bool,
                                         hostLifecycleTransition: Bool,
                                         rebuilding: Bool) -> Bool {
        isRecovering(parked: parked,
                     hostLifecycleTransition: hostLifecycleTransition,
                     rebuilding: rebuilding)
    }

    /// Top-of-chat banner text, or nil when the engine is idle/healthy.
    public static func bannerText(parked: Bool,
                                  hostLifecycleTransition: Bool,
                                  rebuilding: Bool,
                                  slow: Bool) -> String? {
        guard isRecovering(parked: parked,
                           hostLifecycleTransition: hostLifecycleTransition,
                           rebuilding: rebuilding)
        else { return nil }
        return (rebuilding || slow) ? slowText : recoveringText
    }

    /// Maps the engine's static visibility warning to the only value the status
    /// log may contain: an enum token. Paths and user content never appear.
    public static func visibilityToken(fromConsoleText text: String) -> String? {
        if text.contains("webview-visibility=not_attached") { return "not_attached" }
        if text.contains("webview-visibility=not_occlusion_visible") {
            return "not_occlusion_visible"
        }
        if text.contains("webview-visibility=not_visible_timeout") {
            return "not_visible_timeout"
        }
        return nil
    }
}
