// SPDX-License-Identifier: MIT
import Foundation
import PhoneDSHAgentCore
import PhoneDSHDeviceTasks

/// A task inbox is tied to one explicitly granted, currently connected Link
/// identity. It never reconnects or grants itself access.
public struct BLEDeviceTaskInbox: BLETaskLinkInbox, Sendable {
    public let deviceID: String
    private let peripheralID: UUID
    private let identity: String
    private let store: BLEDeviceStore

    @MainActor public init(peripheralID: UUID, store: BLEDeviceStore = .shared) throws {
        guard let device = store.devices.first(where: { $0.id == peripheralID }),
              device.allowDeviceTasks, device.taskIdentity.hasPrefix("ble:") else {
            throw BLEFailure("Device task grant is unavailable")
        }
        self.peripheralID = peripheralID
        self.identity = device.taskIdentity
        self.store = store
        self.deviceID = device.taskIdentity
    }

    public func next() async throws -> DeviceTask? {
        let request = UUID()
        let value = try await store.invokeTaskLink(peripheralID, identity: identity,
            requestID: request, name: "pdsh.task.next", arguments: .object([:]),
            key: UUID().uuidString.lowercased(), fresh: true)
        guard value["request_id"]?.stringValue == request.uuidString.lowercased(),
              value["status"]?.stringValue == "completed", let task = value["result"]?["task"] else {
            throw BLEFailure("Invalid task inbox result")
        }
        if task == .null { return nil }
        return try DeviceTask.decode(task.encoded())
    }

    public func invokeOrQuery(requestID: UUID, name: String, arguments: JSONValue,
                              idempotencyKey: String, fresh: Bool) async throws -> JSONValue {
        try await store.invokeTaskLink(peripheralID, identity: identity,
            requestID: requestID, name: name, arguments: arguments, key: idempotencyKey, fresh: fresh)
    }
}
