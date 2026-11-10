// SPDX-License-Identifier: MIT
// Pure management rows shared by the App's drawer/automation surfaces and by
// any `WorkspaceBackend` that consumes DSH's management endpoints.
//
// The decoders are the former private `DSHManagementModel.decodeSessions` /
// `decodeWorkspace`. App-only policy stays in the App: session title hints are
// passed in as a closure, and the phone-only `BotSessionRegistry` filter is an
// `isExcludedSessionID` closure, so a PC backend can decode the same rows with
// no Bot coupling.

import Foundation
import PhoneDSHAgentCore

public struct ManagedSession: Identifiable, Hashable {
    public let id: String
    public var title: String
    public var updatedAt: Date
    public var running: Bool
    public var blank: Bool
    public var cwd: String?
    public var parentSessionID: String?
    public var searchSnippet: String?

    public init(id: String, title: String, updatedAt: Date, running: Bool,
                blank: Bool, cwd: String?, parentSessionID: String?,
                searchSnippet: String?) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.running = running
        self.blank = blank
        self.cwd = cwd
        self.parentSessionID = parentSessionID
        self.searchSnippet = searchSnippet
    }
}

public struct ManagedWorkspace: Identifiable, Hashable {
    public let id: String
    public var title: String
    public var path: String
    public var sessionIDs: [String]

    public init(id: String, title: String, path: String, sessionIDs: [String]) {
        self.id = id
        self.title = title
        self.path = path
        self.sessionIDs = sessionIDs
    }
}

public enum ManagementDecoding {
    /// Default session names. The host sends no title for a fresh session, so
    /// these are the only names the user ever sees for one.
    public static let newSessionName = "新会话"
    public static let untitledSessionName = "未命名会话"

    /// Decodes `session/list` rows. `titleHint` is the App's local first-prompt
    /// hint; callers without one pass nil and fall back to the host projection.
    public static func decodeSessions(
        _ value: JSONValue,
        titleHint: ((String) -> String?)? = nil,
        newSessionName: String = ManagementDecoding.newSessionName,
        untitledSessionName: String = ManagementDecoding.untitledSessionName
    ) -> [ManagedSession] {
        (value["items"]?.arrayValue ?? []).compactMap { item in
            guard let id = item["sessionId"]?.stringValue else { return nil }
            // `title` is a plain string in the session projection (or null),
            // not { title: string }. The old wrapper made every projected
            // title nil and forced the local hint fallback.
            let projected = item["projections"]?["values"]?["title"]?.stringValue
                .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            let title = projected
                ?? titleHint?(id)
                ?? (item["blank"]?.boolValue == true ? newSessionName : untitledSessionName)
            return ManagedSession(
                id: id, title: title,
                // DSH stores wall-clock timestamps in milliseconds (Date.now).
                updatedAt: Date(timeIntervalSince1970: (item["updatedAt"]?.numberValue ?? 0) / 1_000),
                running: item["running"]?.boolValue ?? false,
                blank: item["blank"]?.boolValue ?? false,
                cwd: item["cwd"]?.stringValue,
                parentSessionID: item["parentSessionId"]?.stringValue,
                searchSnippet: nil)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Decodes one `workspace/follow` row. `isExcludedSessionID` keeps the
    /// phone's Bot-session filter outside this shared decoder.
    public static func decodeWorkspace(
        _ value: JSONValue,
        isExcludedSessionID: ((String) -> Bool)? = nil
    ) -> ManagedWorkspace? {
        guard let id = value["workspaceId"]?.stringValue,
              let title = value["title"]?.stringValue,
              let path = value["path"]?.stringValue else { return nil }
        var sessionIDs = value["sessionIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if let isExcludedSessionID {
            sessionIDs = sessionIDs.filter { !isExcludedSessionID($0) }
        }
        return ManagedWorkspace(id: id, title: title, path: path, sessionIDs: sessionIDs)
    }
}
