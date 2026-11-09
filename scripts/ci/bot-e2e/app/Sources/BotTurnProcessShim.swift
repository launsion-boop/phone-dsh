// SPDX-License-Identifier: MIT

// The production-composition E2E target includes `BotProductionServices.swift`
// but not the Bot page's view layer. It only needs the process-row value type
// to compile; no assertion in this target reads tool steps.
import Foundation
import PhoneDSHAgentCore
import PhoneDSHDeviceTasks

struct ChatItem: Identifiable, Equatable {
    let id: String
    var title: String
    var text: String
}

struct BotTurnProcess: Equatable {
    var turn: Int
    var items: [ChatItem]
    var startedAt: Date?
    var endedAt: Date?
    var endKind: String?
}

enum BotTurnProcessProjector {
    static func make(records: [JSONValue]) -> [Int: BotTurnProcess] { [:] }
}

/// The production-composition E2E target does not link the app's device UI.
/// The composition only installs/removes the settlement callback, so a stub
/// keeps the same shape without pulling BLE/ADB screens into the test bundle.
@MainActor
final class DeviceTaskManager {
    static let shared = DeviceTaskManager()
    func installTaskSettlementHandler(
        owner: AnyObject,
        handler: @escaping @MainActor (DeviceTaskSettlement, String) -> Void
    ) {}
    func removeTaskSettlementHandler(owner: AnyObject) {}
}
