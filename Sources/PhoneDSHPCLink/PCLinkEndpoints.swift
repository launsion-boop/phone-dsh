// SPDX-License-Identifier: MIT
// PhoneDSHPCLink: normative workspace/1 endpoint inventory and retry classes.
//
// `spec/pclink/v1/endpoints.json` is normative (§7). An app bundle cannot read
// the repository at runtime, so the inventory is embedded here; the test suite
// re-reads endpoints.json by #filePath and proves every row matches exactly.
// The inventory is for retry classification and version compatibility only:
// PCLink v1 has no endpoint allowlist, and an endpoint missing here is still
// forwarded and treated as `unsafe` for retry purposes.

import Foundation

public enum PCLinkRetryClass: String, Sendable, CaseIterable {
    case read
    case idempotent
    case unsafe
}

public enum PCLinkEndpointKind: String, Sendable, CaseIterable {
    case unary
    case stream
}

public struct PCLinkEndpointSpec: Equatable, Sendable {
    public var kind: PCLinkEndpointKind
    public var retry: PCLinkRetryClass
    public var phoneOnly: Bool

    public init(kind: PCLinkEndpointKind, retry: PCLinkRetryClass, phoneOnly: Bool) {
        self.kind = kind
        self.retry = retry
        self.phoneOnly = phoneOnly
    }
}

public enum PCLinkEndpoints {
    public static let suite = "workspace/1"
    public static let dshTestedRange = ">=0.2.2-rc.1 <0.3.0"
    public static let defaultRetry = PCLinkRetryClass.unsafe
    public static let forbiddenRemotePrefix = "pclink.admin/"

    public static let inventory: [String: PCLinkEndpointSpec] = [
        "$events": .init(kind: .stream, retry: .read, phoneOnly: false),
        "$events/result": .init(kind: .unary, retry: .unsafe, phoneOnly: false),
        "agentPresets/list": .init(kind: .unary, retry: .read, phoneOnly: false),
        "agentPresets/read": .init(kind: .unary, retry: .read, phoneOnly: false),
        "commands/execute": .init(kind: .unary, retry: .unsafe, phoneOnly: false),
        "commands/list": .init(kind: .unary, retry: .read, phoneOnly: false),
        "goals/complete": .init(kind: .unary, retry: .unsafe, phoneOnly: false),
        "goals/get": .init(kind: .unary, retry: .read, phoneOnly: false),
        "goals/pause": .init(kind: .unary, retry: .unsafe, phoneOnly: false),
        "goals/resume": .init(kind: .unary, retry: .unsafe, phoneOnly: false),
        "job/kill": .init(kind: .unary, retry: .unsafe, phoneOnly: false),
        "job/list": .init(kind: .stream, retry: .read, phoneOnly: false),
        "messageFeedback/put": .init(kind: .unary, retry: .idempotent, phoneOnly: false),
        "permissionPresets/catalog": .init(kind: .unary, retry: .read, phoneOnly: false),
        "phone/botClaimSession": .init(kind: .unary, retry: .unsafe, phoneOnly: true),
        "phone/createSchedule": .init(kind: .unary, retry: .unsafe, phoneOnly: true),
        "phone/importAbort": .init(kind: .unary, retry: .unsafe, phoneOnly: true),
        "phone/importBegin": .init(kind: .unary, retry: .unsafe, phoneOnly: true),
        "phone/importCommit": .init(kind: .unary, retry: .unsafe, phoneOnly: true),
        "phone/importWrite": .init(kind: .unary, retry: .unsafe, phoneOnly: true),
        "phone/listTools": .init(kind: .unary, retry: .read, phoneOnly: true),
        "phone/mcpList": .init(kind: .unary, retry: .read, phoneOnly: true),
        "phone/mcpReconnect": .init(kind: .unary, retry: .unsafe, phoneOnly: true),
        "phone/mcpRemove": .init(kind: .unary, retry: .unsafe, phoneOnly: true),
        "phone/mcpUpsert": .init(kind: .unary, retry: .unsafe, phoneOnly: true),
        "phone/pluginList": .init(kind: .unary, retry: .read, phoneOnly: true),
        "pluginInventory/list": .init(kind: .unary, retry: .read, phoneOnly: false),
        "schedule/catalog": .init(kind: .unary, retry: .read, phoneOnly: false),
        "schedule/edit": .init(kind: .unary, retry: .unsafe, phoneOnly: false),
        "schedule/history": .init(kind: .unary, retry: .read, phoneOnly: false),
        "session/cancel": .init(kind: .unary, retry: .unsafe, phoneOnly: false),
        "session/create": .init(kind: .unary, retry: .unsafe, phoneOnly: false),
        "session/follow": .init(kind: .stream, retry: .read, phoneOnly: false),
        "session/fork": .init(kind: .unary, retry: .unsafe, phoneOnly: false),
        "session/list": .init(kind: .unary, retry: .read, phoneOnly: false),
        "session/modelCatalog": .init(kind: .unary, retry: .read, phoneOnly: false),
        "session/page": .init(kind: .unary, retry: .read, phoneOnly: false),
        "session/prompt": .init(kind: .unary, retry: .idempotent, phoneOnly: false),
        "session/projections": .init(kind: .unary, retry: .read, phoneOnly: false),
        "session/rename": .init(kind: .unary, retry: .idempotent, phoneOnly: false),
        "session/search": .init(kind: .unary, retry: .read, phoneOnly: false),
        "session/selectModel": .init(kind: .unary, retry: .idempotent, phoneOnly: false),
        "session/updateQueue": .init(kind: .unary, retry: .unsafe, phoneOnly: false),
        "settings/describe": .init(kind: .unary, retry: .read, phoneOnly: false),
        "settings/mutate": .init(kind: .unary, retry: .unsafe, phoneOnly: false),
        "settings/update": .init(kind: .unary, retry: .unsafe, phoneOnly: false),
        "skills/list": .init(kind: .unary, retry: .read, phoneOnly: false),
        "subagents/interruptByParent": .init(kind: .unary, retry: .unsafe, phoneOnly: false),
        "workspace/archiveSession": .init(kind: .unary, retry: .idempotent, phoneOnly: false),
        "workspace/create": .init(kind: .unary, retry: .unsafe, phoneOnly: false),
        "workspace/delete": .init(kind: .unary, retry: .unsafe, phoneOnly: false),
        "workspace/follow": .init(kind: .stream, retry: .read, phoneOnly: false),
        "workspace/insertSessionBefore": .init(kind: .unary, retry: .idempotent, phoneOnly: false),
        "workspace/pinSession": .init(kind: .unary, retry: .idempotent, phoneOnly: false),
        "workspace/rename": .init(kind: .unary, retry: .idempotent, phoneOnly: false),
        "workspace/unarchiveSession": .init(kind: .unary, retry: .idempotent, phoneOnly: false),
        "workspace/unpinSession": .init(kind: .unary, retry: .idempotent, phoneOnly: false),
    ]

    public static func spec(for endpoint: String) -> PCLinkEndpointSpec? {
        inventory[endpoint]
    }

    public static func retryClass(for endpoint: String) -> PCLinkRetryClass {
        inventory[endpoint]?.retry ?? defaultRetry
    }

    /// The one forbidden remote endpoint prefix (§6.1). Admin routes are not a
    /// general allowlist; every other endpoint is forwarded.
    public static func isForbiddenRemoteAdmin(_ endpoint: String) -> Bool {
        endpoint.hasPrefix(forbiddenRemotePrefix)
    }
}
