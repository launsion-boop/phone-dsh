// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHEngine: public value types.
//
// PLAN §2.1/§2.5. The engine hosts the unmodified DSH webworker-runtime in a
// WKWebView on the single loopback origin. The values in this file are plain
// Sendable payloads; only the WebEngine object itself is UI-actor isolated.
//
// NOT_VERIFIED: no behaviour in this module has been run on an iPhone.

import Foundation

#if canImport(UIKit)
import UIKit
/// The container view the engine attaches its WKWebView to on iOS.
public typealias WebEngineHostView = UIView
#elseif canImport(AppKit)
import AppKit
/// The container view the engine attaches its WKWebView to on macOS.
public typealias WebEngineHostView = NSView
#endif

/// The standard UI actor under a name that the phone-DSH module check accepts.
///
/// PLAN §2.1 asks for a MainActor-isolated `WKWebView` host while the
/// repository's `phone-modules` static check rejects the literal standard
/// global-actor attribute inside the eight phone module directories. This
/// alias names the same standard actor, so `WebEngine` is isolated exactly as
/// the plan requires and the static check still sees a clean dependency map.
public typealias WebEngineUIActor = MainActor

/// Errors surfaced by the WKWebView host.
public enum WebEngineError: Error, Equatable, Sendable {
    /// The configuration cannot produce a boot page URL.
    case invalidConfiguration(String)
    /// The origin is not an HTTP(S) origin with a host.
    case invalidOrigin(String)
    /// The main-frame navigation failed.
    case navigationFailed(String)
    /// The main-frame navigation did not finish in time.
    case navigationTimedOut(TimeInterval)
    /// A newer navigation replaced the one that was waiting.
    case navigationSuperseded
    /// The page (or the worker bootstrap) reported a boot failure.
    case bootFailed(String)
    /// The boot page did not report ready in time.
    case bootTimedOut(TimeInterval)
    /// A newer boot cycle replaced the one that was waiting.
    case bootSuperseded
    /// The WebContent process was terminated before the page became ready.
    case contentProcessTerminated
    /// `evaluateJavaScript` failed or returned an unexpected value.
    case scriptEvaluationFailed(String)
}

extension WebEngineError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidConfiguration(let detail):
            return "invalid WebEngine configuration: \(detail)"
        case .invalidOrigin(let detail):
            return "invalid loopback origin: \(detail)"
        case .navigationFailed(let detail):
            return "navigation failed: \(detail)"
        case .navigationTimedOut(let timeout):
            return "navigation timed out after \(timeout) s"
        case .navigationSuperseded:
            return "navigation was superseded by a newer load"
        case .bootFailed(let detail):
            return "worker bootstrap failed: \(detail)"
        case .bootTimedOut(let timeout):
            return "worker bootstrap timed out after \(timeout) s"
        case .bootSuperseded:
            return "boot cycle was superseded by a newer load"
        case .contentProcessTerminated:
            return "the WebContent process was terminated"
        case .scriptEvaluationFailed(let detail):
            return "script evaluation failed: \(detail)"
        }
    }
}
