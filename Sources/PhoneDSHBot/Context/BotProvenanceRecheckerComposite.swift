// SPDX-License-Identifier: MIT

import Foundation

/// One provenance rechecker for every source family. The composition injects
/// the file (P), web/connector (R) and context (N) adapters; a missing family
/// is honestly `notPerformed`, never current. L sees one rechecker and keeps
/// owning the artifact key and status vocabulary.
public struct BotProvenanceRecheckerComposite: BotProvenanceRechecking {
    private let file: (any BotProvenanceRechecking)?
    private let web: (any BotProvenanceRechecking)?
    private let context: (any BotProvenanceRechecking)?

    public init(file: (any BotProvenanceRechecking)? = nil,
                web: (any BotProvenanceRechecking)? = nil,
                context: (any BotProvenanceRechecking)? = nil) {
        self.file = file
        self.web = web
        self.context = context
    }

    public func recheck(resource: BotResourceIdentity,
                        baseline: BotProvenanceSourceVersion,
                        botID: String?) async -> BotProvenanceRecheckOutcome {
        switch resource.kind {
        case .file:
            guard let file else { return .notPerformed }
            return await file.recheck(resource: resource, baseline: baseline, botID: botID)
        case .webURL, .connectorResource:
            guard let web else { return .notPerformed }
            return await web.recheck(resource: resource, baseline: baseline, botID: botID)
        case .contextSource:
            guard let context else { return .notPerformed }
            return await context.recheck(resource: resource, baseline: baseline, botID: botID)
        case .provider:
            return .notPerformed
        }
    }
}
