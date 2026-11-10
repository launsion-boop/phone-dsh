// SPDX-License-Identifier: MIT
// Off-main `session/list` row decoding.
//
// The PC's 3,500-Session list is ~5.5 MB. `PCLinkClient` already parses the
// wire JSON on its own actor; the App then turns the parsed `JSONValue` into
// `ManagedSession` rows. That second walk (and the sort) is small next to the
// JSON parse, but it was still done on the MainActor inside
// `DSHManagementModel.refresh()`, together with per-row title-hint lookups that
// read and filter the whole UserDefaults hint map for every Session. Moving the
// shared decoder off the MainActor keeps the main thread free for the frame
// that actually renders the drawer.

import Foundation
import PhoneDSHAgentCore
import Darwin

public enum PCWorkspaceDecoding {
    /// Decode `session/list` rows away from the MainActor.
    ///
    /// - Parameters:
    ///   - value: the already-parsed `session/list` result.
    ///   - titleHints: the caller's title hints, loaded **once** before the
    ///     call. Passing a dictionary avoids the old per-row
    ///     `WorkspaceStorage.titleHints(for:)` UserDefaults scan.
    ///   - newSessionName / untitledSessionName: host-local fallbacks.
    ///   - onDecodeThread: test/instrumentation seam; receives
    ///     `Thread.isMainThread` from the worker that performs the decode.
    public static func decodeSessionsOffMain(
        _ value: JSONValue,
        titleHints: [String: String],
        newSessionName: String = ManagementDecoding.newSessionName,
        untitledSessionName: String = ManagementDecoding.untitledSessionName,
        onDecodeThread: (@Sendable (Bool) -> Void)? = nil
    ) async -> [ManagedSession] {
        await Task.detached(priority: .userInitiated) {
            onDecodeThread?(pthread_main_np() != 0)
            return ManagementDecoding.decodeSessions(
                value,
                titleHint: { titleHints[$0] },
                newSessionName: newSessionName,
                untitledSessionName: untitledSessionName)
        }.value
    }
}
