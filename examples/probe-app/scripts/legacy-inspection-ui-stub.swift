// SPDX-License-Identifier: MIT
// Test-only stand-in for the result type and default inspector; no filesystem access.
public struct DeviceTaskLegacyInspection: Sendable, Equatable {
    public enum Status: String, Sendable { case busy, incomplete }
    public enum Reason: String, Sendable {
        case rootMissing, rootUnreadable, rootUnsupported, entryBudget, byteBudget, ioError, cancelled
    }
    public struct Entry: Identifiable, Sendable, Equatable {
        public enum Kind: String, Sendable { case observed, unparsed, unreadable, symlink, nonRegular, unexamined }
        public struct Claims: Sendable, Equatable {
            public let deviceID: String?
            public let taskID: String?
            public let phase: String?
            public let outcomeKind: String?
            public init(deviceID: String?, taskID: String?, phase: String?, outcomeKind: String?) {
                self.deviceID = deviceID; self.taskID = taskID; self.phase = phase; self.outcomeKind = outcomeKind
            }
        }
        public let id: String
        public let label: String
        public let kind: Kind
        public let claims: Claims?
        public init(id: String, label: String, kind: Kind, claims: Claims?) {
            self.id = id; self.label = label; self.kind = kind; self.claims = claims
        }
    }
    public let status: Status
    public let entries: [Entry]
    public let cancelled: Bool
    public let reasons: [Reason]
    public init(status: Status, entries: [Entry], cancelled: Bool, reasons: [Reason]) {
        self.status = status; self.entries = entries; self.cancelled = cancelled; self.reasons = reasons
    }
}
public enum DeviceTaskLegacyInspector {
    public static func inspect() async -> DeviceTaskLegacyInspection {
        .init(status: .incomplete, entries: [], cancelled: false, reasons: [.rootUnreadable])
    }
}
