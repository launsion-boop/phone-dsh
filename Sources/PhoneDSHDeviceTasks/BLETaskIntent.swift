// SPDX-License-Identifier: MIT
import CryptoKit
import Darwin
import Foundation
import PhoneDSHAgentCore

/// A Link mutation must be recorded before its first possible upload.
struct BLETaskIntent: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable { case accept, complete, fail }
    let v: Int
    let msgID: String
    let deviceID: String
    let taskID: String
    let action: Action
    let requestID: String
    let idemKey: String
    let argumentsSHA256: String

    enum CodingKeys: String, CodingKey {
        case v, action
        case msgID = "msg_id", deviceID = "device_id", taskID = "task_id", requestID = "request_id"
        case idemKey = "idem_key", argumentsSHA256 = "arguments_sha256"
    }

    static func make(record: DeviceTaskRecord, action: Action, arguments: JSONValue) throws -> BLETaskIntent {
        guard record.deviceID.hasPrefix("ble:"),
              let uuid = UUID(uuidString: String(record.deviceID.dropFirst(4))),
              record.deviceID == "ble:" + uuid.uuidString.lowercased(),
              record.msgID == DeviceTaskJournal.msgID(deviceID: record.deviceID, key: record.task.idempotencyKey),
              arguments["id"]?.stringValue == record.task.id else { throw DeviceTaskError.invalidTask }
        var input = Data("phoneDSH BLE task v1".utf8)
        input.append(0); input.append(contentsOf: record.msgID.utf8)
        input.append(0); input.append(contentsOf: action.rawValue.utf8)
        let digest = Array(SHA256.hash(data: input))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return BLETaskIntent(v: 1, msgID: record.msgID, deviceID: record.deviceID,
                             taskID: record.task.id, action: action, requestID: id.uuidString.lowercased(),
                             idemKey: digest.map { String(format: "%02x", $0) }.joined(),
                             argumentsSHA256: SHA256.hash(data: try arguments.encoded()).map { String(format: "%02x", $0) }.joined())
    }
}
