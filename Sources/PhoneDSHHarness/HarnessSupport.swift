// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHHarness: reusable harness support.
//
// This target is test support, not app-facing API. It is not part of the
// `PhoneDSH` umbrella and no app product links it. It holds the one
// copy of the scripted model upstream, the smoke evidence readers, the
// kill-matrix support and the shared probe page fixture so the macOS XCTest
// suites and the iOS Simulator probe project compile the same code. It never
// imports XCTest.
//
// Why a regular target: Xcode's package resolver rejects a test target that
// depends on another test target even though the SwiftPM command line accepts
// it, so the iOS probe project links this target as a `.library` product
// instead of path-including files from `Tests/`.
//
// The AppKit event pump is not here: it lives in `PhoneDSHEngine`
// (`WebEngineAppKitEventPump`, guarded by `#if canImport(AppKit)`) next to the
// page-visibility precondition it serves. iOS compiles it out.

import Foundation
import PhoneDSHEngine

/// Yields the current task long enough for a harnessed page to make progress.
///
/// On macOS this dispatches AppKit events through the engine's shared
/// ``WebEngineAppKitEventPump``: a WKWebView in an XCTest process stays hidden
/// to WebKit (and is throttled) until the ordered window's AppKit events are
/// dequeued. iOS has no AppKit event queue: a foreground simulator test app's
/// run loop already services UIKit events, so the wait sleeps instead. Keeping
/// this switch in one place lets the shared smoke/kill support compile for both
/// platforms without a second pump copy.
public func harnessWait(_ interval: TimeInterval) async throws {
    try Task.checkCancellation()
    #if canImport(AppKit)
    try await WebEngineAppKitEventPump.wait(max(0, interval))
    #else
    try await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
    #endif
}

/// The probe page/Worker fixture shared by the macOS probe suite and the iOS
/// probe app.
public enum PhoneDSHHarnessResources {
    /// The `probe-site` folder from the target's resource bundle.
    ///
    /// The iOS probe project references the same folder as a folder resource
    /// instead of copying it, so both harnesses use one source of truth.
    public static var probeSiteDirectory: URL? {
        Bundle.module.url(forResource: "probe-site", withExtension: nil)
    }
}
