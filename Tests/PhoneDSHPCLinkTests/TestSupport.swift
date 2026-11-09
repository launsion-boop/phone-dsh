// SPDX-License-Identifier: MIT
// Shared test support: repository root, golden documents and in-memory stores.

import Foundation
import XCTest
@testable import PhoneDSHPCLink

enum TestSupport {
    static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    static func data(_ relativePath: String) throws -> Data {
        try Data(contentsOf: repoRoot.appendingPathComponent(relativePath))
    }

    static func json(_ relativePath: String) throws -> PCLinkJSON {
        try PCLinkJSONParser.parseDocumentObject(try data(relativePath))
    }

    static func vectors() throws -> PCLinkJSON {
        try json("spec/pclink/v1/golden/pclink-v1-vectors.json")
    }

    static func schemaSamples() throws -> PCLinkJSON {
        try json("spec/pclink/v1/golden/schema-samples.json")
    }

    static func endpointsDocument() throws -> PCLinkJSON {
        try json("spec/pclink/v1/endpoints.json")
    }

    static func hex(_ value: String) throws -> Data {
        try PCLinkHex.decode(value)
    }

    static func seed(_ label: String) -> Data {
        PCLinkCrypto.sha256(Data(label.utf8))
    }

    static func identity(_ label: String) throws -> PCLinkIdentity {
        try PCLinkIdentity(seed: seed(label))
    }

    static func record(peerMachineId: String, peerPublicKey: Data, peerName: String,
                       relayOrigin: String = "https://relay.example") -> PCLinkPairingRecord {
        PCLinkPairingRecord(peerMachineId: peerMachineId, peerPublicKey: peerPublicKey,
                            peerName: peerName, pairedAt: "2026-11-09T00:00:00Z",
                            relayOrigin: relayOrigin)
    }

    static func b64(_ value: PCLinkJSON?, _ key: String) -> Data? {
        guard let text = value?[key]?.stringValue else { return nil }
        return try? PCLinkBase64URL.decode(text)
    }

    static func string(_ value: PCLinkJSON?, _ path: String...) -> String? {
        var current = value
        for key in path { current = current?[key] }
        return current?.stringValue
    }

    static func int(_ value: PCLinkJSON?, _ path: String...) -> Int64? {
        var current = value
        for key in path { current = current?[key] }
        return current?.intValue
    }
}

final class InMemoryIdentityStore: PCLinkIdentityStore, @unchecked Sendable {
    private let lock = NSLock()
    private var seed: Data?

    init(seed: Data? = nil) {
        self.seed = seed
    }

    func loadSeed() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return seed
    }

    func saveSeed(_ seed: Data) throws {
        lock.lock(); defer { lock.unlock() }
        self.seed = seed
    }

    func deleteSeed() throws {
        lock.lock(); defer { lock.unlock() }
        seed = nil
    }
}

final class InMemoryPairingStore: PCLinkPairingStore, @unchecked Sendable {
    private let lock = NSLock()
    private var document: PCLinkJSON?
    private let hasFile: Bool

    init(record: PCLinkPairingRecord? = nil, phoneMachineId: String? = nil,
         rawDocument: PCLinkJSON? = nil, hasFile: Bool = false) {
        if let rawDocument {
            self.document = rawDocument
        } else if let record, let phoneMachineId {
            self.document = .object([
                "v": .int(1),
                "phoneMachineId": .string(phoneMachineId),
                "records": .array([record.json]),
            ])
        }
        self.hasFile = hasFile || rawDocument != nil || record != nil
    }

    func hasStoredFile() -> Bool { hasFile }

    func load(phoneMachineId: String) throws -> PCLinkPairingStoreState {
        lock.lock(); defer { lock.unlock() }
        guard let document else { return .none }
        let object = try document.closedObject(required: ["v", "phoneMachineId", "records"])
        let stored = try document.requiredString("phoneMachineId")
        guard let records = object["records"]?.arrayValue, records.count <= 1 else {
            throw PCLinkError.storage("bad records")
        }
        guard let first = records.first else { return .none }
        try PCLinkPairingRecord.validatePhoneRecordJSON(first)
        let record = try PCLinkPairingRecord(json: first)
        return stored == phoneMachineId ? .usable(record) : .stale(record)
    }

    func save(_ record: PCLinkPairingRecord, phoneMachineId: String) throws {
        lock.lock(); defer { lock.unlock() }
        document = .object([
            "v": .int(1),
            "phoneMachineId": .string(phoneMachineId),
            "records": .array([record.json]),
        ])
    }

    func delete() throws {
        lock.lock(); defer { lock.unlock() }
        document = nil
    }

    var stored: PCLinkJSON? {
        lock.lock(); defer { lock.unlock() }
        return document
    }
}
