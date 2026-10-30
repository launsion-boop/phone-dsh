// SPDX-License-Identifier: MIT
// phone-dsh — transactional delivery state for human replies in the probe app.

import Foundation
import Observation
import PhoneDSHAgentCore

/// Keeps a human reply retryable until the harness confirms that it accepted it.
@MainActor
@Observable
public final class ReplyDelivery {
    public private(set) var requestID: String?
    public private(set) var isSending = false
    public private(set) var errorMessage: String?
    private var completedRequestIDs: Set<String> = []

    public init() {}

    /// Starts one delivery for the current request. Concurrent taps are ignored.
    /// The request remains available to the caller on failure and is cleared by
    /// the caller only after this method returns `true`.
    @discardableResult
    public func send(requestID: String,
                     operation: () async throws -> Void) async -> Bool {
        guard self.requestID == requestID, !isSending,
              !completedRequestIDs.contains(requestID) else { return false }
        isSending = true
        errorMessage = nil
        defer {
            if self.requestID == requestID { isSending = false }
        }
        do {
            try await operation()
            // The next question can arrive before the previous reply's API
            // response. Its arrival does not undo the completed delivery.
            completedRequestIDs.insert(requestID)
            return true
        } catch {
            if self.requestID == requestID { errorMessage = String(describing: error) }
            return false
        }
    }

    /// Selects a new request while retaining state when a duplicate event for
    /// the same request is observed.
    @discardableResult
    public func present(_ requestID: String) -> Bool {
        guard !completedRequestIDs.contains(requestID) else { return false }
        guard self.requestID != requestID else { return true }
        self.requestID = requestID
        isSending = false
        errorMessage = nil
        return true
    }

    public func complete(ifMatching requestID: String) {
        guard self.requestID == requestID else { return }
        completedRequestIDs.insert(requestID)
        self.requestID = nil
        isSending = false
        errorMessage = nil
    }

    public func clear(ifMatching requestID: String) {
        guard self.requestID == requestID else { return }
        self.requestID = nil
        isSending = false
        errorMessage = nil
    }
}

/// Ordered cleanup actions shared by terminal turn paths.
@MainActor
public enum TurnResourceCleanup {
    public static func finish(shouldPark: Bool,
                              stopHeartbeat: () -> Void,
                              stopPageAudio: () -> Void,
                              stopNativeAudio: () -> Void,
                              endBackgroundTask: () -> Void,
                              park: () async -> Void) async {
        stopHeartbeat()
        stopPageAudio()
        stopNativeAudio()
        if shouldPark { await park() }
        endBackgroundTask()
    }

    public static func isTerminal(_ kind: HarnessEvent.Kind) -> Bool {
        switch kind {
        case .turnEnded, .exited: return true
        default: return false
        }
    }
}
