// SPDX-License-Identifier: MIT

import Foundation

/// Non-throwing read result for the App UI and composition.
///
/// The strict `observations` method throws so a caller cannot ignore a revoked
/// read; this result exists for the UI path, where the correct behavior is an
/// empty list plus a stable reason. It is not a second observation store.
public struct BotContextObservationRead: Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case ok
        case notStarted = "not-started"
        case notAuthorized = "not-authorized"
        case revoked
        case unavailable
    }

    public var status: Status
    public var reason: String
    public var observations: [BotContextObservation]

    public init(status: Status, reason: String,
                observations: [BotContextObservation] = []) {
        self.status = status
        self.reason = String(reason.prefix(240))
        self.observations = observations
    }

    public var isEmpty: Bool { observations.isEmpty }
    public var isReadable: Bool { status == .ok }
}

/// Stable, non-secret diagnostic reasons shared by the App surface and tests.
public enum BotContextObservationReadReason {
    public static let assemblyNotStarted = "assembly-not-started"
    public static let sourceNotAuthorized = "source-not-authorized"
    public static let sourceRevoked = "source-revoked"
    public static let sourceUnavailable = "source-unavailable"
    public static let noObservations = "no-observations"
    public static let readFailed = "read-failed"
}
