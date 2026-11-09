// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSH

/// What the App should do after `start()` hit the D24 persisted-backoff
/// window. `backoffNotElapsed` is a healthy wait, not a failed engine; the
/// policy decides whether to retry, wait for the person, or stop retrying.
public enum ChatBackoffRetryDecision: Equatable, Sendable {
    /// Wait this many seconds past `now`, then call `start()` again.
    case retry(after: TimeInterval, attempt: Int)
    /// The deadline is too far away to guess at; keep the manual start path.
    case waitForManualStart(remaining: TimeInterval)
    /// Consecutive automatic retries are exhausted; report an error.
    case exhausted(attempts: Int)
}

public enum ChatBackoffRetry {
    /// Automatic retries allowed in one uninterrupted backoff episode.
    public static let maximumAttempts = 5
    /// A deadline farther away than this is only shown, never auto-retried.
    public static let maximumAutomaticDelay: TimeInterval = 60
    /// Wake just after the persisted deadline instead of racing it.
    public static let deadlineMargin: TimeInterval = 0.3

    public static func decision(deadline: Date,
                                now: Date,
                                attempts: Int) -> ChatBackoffRetryDecision {
        guard attempts < maximumAttempts else {
            return .exhausted(attempts: attempts)
        }
        let remaining = deadline.timeIntervalSince(now)
        guard remaining <= maximumAutomaticDelay else {
            return .waitForManualStart(remaining: remaining)
        }
        return .retry(after: max(0, remaining) + deadlineMargin,
                      attempt: attempts + 1)
    }
}

public enum ChatEngineLifecycle {
    public static func needsReset(afterStartIn state: PhoneDSHState) -> Bool {
        state == .failed
    }

    public static func canStartBySending(hostIsStopped: Bool,
                                         busy: Bool,
                                         parked: Bool,
                                         hostLifecycleTransition: Bool) -> Bool {
        hostIsStopped && !busy && !parked && !hostLifecycleTransition
    }
}
