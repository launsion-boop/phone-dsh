// SPDX-License-Identifier: MIT
import Foundation
import CryptoKit
import Darwin
import PhoneDSHAgentCore

/// Used under DeviceMCPServer's actor isolation. An existing intent is query-only,
/// even when upload may not have reached the device. Never evict uncertain actions.
struct LinkToolJournal {
    struct Intent: Codable {
        var requestID: UUID
        var deviceID: UUID
        var name: String
        var arguments: JSONValue
        var fingerprint: Data
    }
    let directory: URL
    func prepare(key: String, deviceID: UUID, name: String, arguments: JSONValue) throws -> (Intent, Bool) {
        guard !key.isEmpty, key.utf8.count <= 256 else { throw BLEFailure("Link calls require a journal idempotency key") }
        let data = try JSONValue.object(["device": .string(deviceID.uuidString), "name": .string(name), "args": arguments]).encoded()
        let fingerprint = Data(SHA256.hash(data: data))
        let file = directory.appendingPathComponent(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".json")
        if FileManager.default.fileExists(atPath: file.path) {
            let old = try JSONDecoder().decode(Intent.self, from: Data(contentsOf: file))
            guard old.fingerprint == fingerprint else { throw BLEFailure("Idempotency key conflict") }
            return (old, false)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard try FileManager.default.contentsOfDirectory(atPath: directory.path).count < 4096 else { throw BLEFailure("Link intent storage full") }
        let intent = Intent(requestID: UUID(), deviceID: deviceID, name: name, arguments: arguments, fingerprint: fingerprint)
        try JSONEncoder().encode(intent).write(to: file, options: .atomic)
        let handle = try FileHandle(forWritingTo: file); try handle.synchronize(); try handle.close()
        for path in [directory, directory.deletingLastPathComponent(), directory.deletingLastPathComponent().deletingLastPathComponent()] {
            let fd = Darwin.open(path.path, O_RDONLY)
            guard fd >= 0 else { throw BLEFailure("Cannot open Link intent directory") }
            let status = Darwin.fsync(fd); Darwin.close(fd)
            guard status == 0 else { throw BLEFailure("Cannot persist Link intent") }
        }
        return (intent, true)
    }
    func find(deviceID: UUID, requestID: UUID) throws -> Intent {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard files.count <= 4096 else { throw BLEFailure("Link intent storage corrupt") }
        for file in files where file.pathExtension == "json" {
            let record = try JSONDecoder().decode(Intent.self, from: Data(contentsOf: file))
            if record.requestID == requestID && record.deviceID == deviceID { return record }
        }
        throw BLEFailure("Unknown local Link request; refusing to query another tool's result")
    }
}
