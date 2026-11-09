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

/// The App's automatic re-open after an engine recovery left a session open
/// without its DSH history. A park during the first load used to strand that
/// session until the person manually switched away and back; these predicates
/// keep the retry rules pure so they can be tested without a host.
public enum ChatSessionReload {
    /// Automatic re-opens allowed after one failed reload episode. The initial
    /// attempt is not counted, so at most three attempts run per episode.
    public static let maximumAutomaticRetries = 2
    /// Let the host settle after adoption/Worker restart before re-opening.
    public static let retryDelay: TimeInterval = 1.5

    /// True when an engine recovery left the open session without a transcript
    /// and no park/transition is in progress.
    public static func needsReloadAfterResume(sessionID: String?,
                                              transcriptReady: Bool,
                                              parked: Bool,
                                              hostLifecycleTransition: Bool) -> Bool {
        sessionID != nil && !transcriptReady && !parked && !hostLifecycleTransition
    }

    /// True when another automatic attempt may follow `retriesUsed` failed
    /// automatic retries. A background App or an active park is not retried.
    public static func canRetryAfterFailure(retriesUsed: Int,
                                            appIsActive: Bool,
                                            sessionID: String?,
                                            transcriptReady: Bool,
                                            parked: Bool,
                                            hostLifecycleTransition: Bool) -> Bool {
        retriesUsed < maximumAutomaticRetries
            && appIsActive
            && needsReloadAfterResume(sessionID: sessionID,
                                      transcriptReady: transcriptReady,
                                      parked: parked,
                                      hostLifecycleTransition: hostLifecycleTransition)
    }

    /// A reload is bound to the session that triggered it. A different (or
    /// missing) current session means the work must be abandoned silently.
    public static func shouldAbandonReload(initiatingSessionID: String?,
                                           currentSessionID: String?) -> Bool {
        guard let initiatingSessionID, let currentSessionID else { return true }
        return initiatingSessionID != currentSessionID
    }
}
