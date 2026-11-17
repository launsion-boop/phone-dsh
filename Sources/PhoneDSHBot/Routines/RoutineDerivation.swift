// SPDX-License-Identifier: MIT

import Foundation

/// The real content basis of a routine definition/update, expressed as the
/// G-1 `derivation` member of the routine snapshot carrier. Only durable record
/// references that the host actually produced are accepted; a run trigger is
/// not content evidence and must not be passed here.
public struct RoutineDerivation: Sendable, Equatable {
    public enum Role: String, Sendable, Equatable, CaseIterable {
        case evidence
        case review
        case trigger
        case creator
        case recipient
        case basis
    }

    public struct Source: Sendable, Equatable {
        public var record: String
        public var role: Role
        /// Present only when the source is a versioned observation; a user
        /// message or approval record has no native version and must omit it.
        public var sourceVersion: BotJSONValue?

        public init(record: String, role: Role,
                    sourceVersion: BotJSONValue? = nil) {
            self.record = record
            self.role = role
            self.sourceVersion = sourceVersion
        }
    }

    public var sources: [Source]

    public init(sources: [Source]) {
        self.sources = sources
    }

    public var isEmpty: Bool { sources.isEmpty }

    /// Validates the record shape and role. Returns nil for an empty input so
    /// callers write no derivation rather than an empty/unknown assertion.
    public func validated() throws -> RoutineDerivation? {
        guard !sources.isEmpty else { return nil }
        var seen: Set<String> = []
        for source in sources {
            let pattern = #"^record://(event/[1-9][0-9]*|session/[A-Za-z0-9._-]{1,64}#(0|[1-9][0-9]*))$"#
            guard source.record.range(of: pattern, options: .regularExpression) != nil else {
                throw RoutineError.invalidRoutine(
                    "routine derivation source must be a durable record reference")
            }
            let key = "\(source.role.rawValue)|\(source.record)"
            guard seen.insert(key).inserted else {
                throw RoutineError.invalidRoutine("duplicate routine derivation source")
            }
        }
        return RoutineDerivation(sources: Array(sources.prefix(16)))
    }

    func json(artifactID: String) -> BotJSONValue {
        .object([
            "artifact": .object([
                "kind": .string("routine"),
                "id": .string(artifactID),
            ]),
            "sources": .array(sources.map { source in
                var object: [String: BotJSONValue] = [
                    "record": .string(source.record),
                    "role": .string(source.role.rawValue),
                ]
                if let version = source.sourceVersion { object["sourceVersion"] = version }
                return .object(object)
            }),
        ])
    }
}

/// C MCP seam helper: builds the routine derivation from records the host has
/// actually committed. Callers must resolve these from the real turn/approval
/// path; do not synthesize `record://event/N`.
public enum RoutineDerivationBuilder {
    public static func fromUserTurn(_ sourceRef: String?) -> RoutineDerivation? {
        guard let sourceRef, !sourceRef.isEmpty else { return nil }
        return RoutineDerivation(sources: [
            .init(record: sourceRef, role: .evidence),
        ])
    }

    public static func userTurnAndApproval(userTurn: String?,
                                           approval: String?) -> RoutineDerivation? {
        var sources: [RoutineDerivation.Source] = []
        if let userTurn, !userTurn.isEmpty {
            sources.append(.init(record: userTurn, role: .evidence))
        }
        if let approval, !approval.isEmpty {
            sources.append(.init(record: approval, role: .basis))
        }
        return sources.isEmpty ? nil : RoutineDerivation(sources: sources)
    }
}
