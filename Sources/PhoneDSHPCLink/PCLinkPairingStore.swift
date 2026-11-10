// SPDX-License-Identifier: MIT
// PhoneDSHPCLink: phone pairing record, usability model and durable store (§4.6).

import Darwin
import Foundation

public enum PCLinkConnectionMode: String, Sendable {
    case relay
    case direct // reserved, never usable in v1
}

public struct PCLinkPairingRecord: Equatable, Sendable {
    public var peerMachineId: String
    public var peerPublicKey: Data
    public var peerName: String
    public var pairedAt: String
    public var relayOrigin: String
    public var connectionMode: PCLinkConnectionMode
    /// The phone-side pairing action for display (v1.6, optional). It is not an
    /// approval field and the PC never reads the phone record.
    public var pairingMode: PCLinkPairingMode?

    public init(peerMachineId: String, peerPublicKey: Data, peerName: String,
                pairedAt: String, relayOrigin: String, connectionMode: PCLinkConnectionMode = .relay,
                pairingMode: PCLinkPairingMode? = nil) {
        self.peerMachineId = peerMachineId
        self.peerPublicKey = peerPublicKey
        self.peerName = peerName
        self.pairedAt = pairedAt
        self.relayOrigin = relayOrigin
        self.connectionMode = connectionMode
        self.pairingMode = pairingMode
    }

    public var fingerprint: String {
        (try? PCLinkValidation.fingerprint(for: peerMachineId)) ?? peerMachineId
    }

    public var json: PCLinkJSON {
        var object: PCLinkJSONObject = [
            "peerMachineId": .string(peerMachineId),
            "peerPublicKey": .string(PCLinkBase64URL.encode(peerPublicKey)),
            "peerName": .string(peerName),
            "pairedAt": .string(pairedAt),
            "relayOrigin": .string(relayOrigin),
            "connection": .object(["mode": .string(connectionMode.rawValue)]),
        ]
        if let pairingMode { object["pairingMode"] = .string(pairingMode.rawValue) }
        return .object(object)
    }

    public init(json value: PCLinkJSON) throws {
        let object = try value.closedObject(required: ["peerMachineId", "peerPublicKey", "peerName",
                                                       "pairedAt", "relayOrigin", "connection"],
                                            optional: ["pairingMode"])
        try PCLinkValidation.requireMachineId(try value.requiredString("peerMachineId"))
        let publicKey = try PCLinkBase64URL.decode(try value.requiredString("peerPublicKey"), expectedBytes: 32)
        guard PCLinkBase32.machineId(fromPublicKey: publicKey) == (try value.requiredString("peerMachineId")) else {
            throw PCLinkError.storage("pairing record machineId does not match its public key")
        }
        try PCLinkValidation.name(try value.requiredString("peerName"))
        let pairedAt = try value.requiredString("pairedAt")
        guard PCLinkValidation.timestamp(pairedAt) else {
            throw PCLinkError.storage("pairing record pairedAt is not RFC 3339 UTC")
        }
        let relayOrigin = try value.requiredString("relayOrigin")
        try PCLinkValidation.origin(relayOrigin)
        guard let connection = object["connection"] else { throw PCLinkError.storage("missing connection") }
        let connectionObject = try connection.closedObject(required: ["mode"])
        guard let modeText = connectionObject["mode"]?.stringValue,
              let mode = PCLinkConnectionMode(rawValue: modeText) else {
            throw PCLinkError.storage("unknown connection mode")
        }
        guard mode == .relay else {
            throw PCLinkError.versionUnsupported("connection.mode \(mode.rawValue) is not callable in v1")
        }
        let pairingMode: PCLinkPairingMode?
        if let rawMode = object["pairingMode"] {
            guard let text = rawMode.stringValue, let parsed = PCLinkPairingMode(rawValue: text) else {
                throw PCLinkError.storage("unknown phone pairingMode")
            }
            pairingMode = parsed
        } else {
            pairingMode = nil
        }
        self.init(peerMachineId: try value.requiredString("peerMachineId"),
                  peerPublicKey: publicKey,
                  peerName: try value.requiredString("peerName"),
                  pairedAt: pairedAt,
                  relayOrigin: relayOrigin,
                  connectionMode: mode,
                  pairingMode: pairingMode)
    }

    /// Explicitly rejects the PC-only approval fields on a phone record.
    static func validatePhoneRecordJSON(_ value: PCLinkJSON) throws {
        let object = try value.closedObject(required: ["peerMachineId", "peerPublicKey", "peerName",
                                                       "pairedAt", "relayOrigin", "connection"],
                                            optional: ["pairingMode"])
        if object["approvedAt"] != nil || object["approvedVia"] != nil {
            throw PCLinkError.storage("phone records must not carry approvedAt/approvedVia")
        }
        if let mode = object["pairingMode"], mode.stringValue.flatMap(PCLinkPairingMode.init(rawValue:)) == nil {
            throw PCLinkError.storage("phone records pairingMode must be qr|manual")
        }
    }

    /// PC-side record (used by shared-fixture state machines).
    public static func validatePCRecordJSON(_ value: PCLinkJSON) throws {
        let object = try value.closedObject(required: ["peerMachineId", "peerPublicKey", "peerName",
                                                       "pairedAt", "relayOrigin", "connection",
                                                       "approvedAt", "approvedVia"])
        let approvedVia = try value.requiredString("approvedVia")
        guard ["qr", "manual", "cli", "webui"].contains(approvedVia) else {
            throw PCLinkError.badFrame("approvedVia must be qr|manual (legacy cli|webui)")
        }
        let approvedAt = try value.requiredString("approvedAt")
        guard PCLinkValidation.timestamp(approvedAt) else {
            throw PCLinkError.badFrame("approvedAt is not RFC 3339 UTC")
        }
        var base = object
        base.removeValue(forKey: "approvedAt")
        base.removeValue(forKey: "approvedVia")
        _ = try PCLinkPairingRecord(json: .object(base))
    }
}

public enum PCLinkRecordUsability: Equatable, Sendable {
    case usable
    case unapproved
    case revoked
    case stale
    case unsupported(String)
}

public enum PCLinkRecordAudit {
    /// Applies the PC audit rule from §4.6 to one record: the latest
    /// `pair`/`unpair` line for the peer must be a matching `pair` line.
    /// The phone section uses this only in the shared-fixture state-machine
    /// tests; the real PC enforces the same rule on load.
    public static func evaluate(record: PCLinkJSON, audit: [PCLinkJSON]) -> PCLinkRecordUsability {
        guard let peerMachineId = record["peerMachineId"]?.stringValue,
              let peerPublicKey = record["peerPublicKey"]?.stringValue,
              let connection = record["connection"],
              connection["mode"]?.stringValue == "relay" else {
            return .unsupported("record is not a usable relay record")
        }
        var latest: PCLinkJSON?
        for entry in audit {
            guard entry["peerMachineId"]?.stringValue == peerMachineId else { continue }
            switch entry["event"]?.stringValue {
            case "pair", "unpair": latest = entry
            default: continue
            }
        }
        guard let latest else { return .unapproved }
        guard latest["event"]?.stringValue == "pair" else { return .revoked }
        guard latest["peerPublicKey"]?.stringValue == peerPublicKey else { return .unapproved }
        let canonical = (try? PCLinkJSONEncoder.canonical(record)) ?? Data()
        let digest = PCLinkHex.encode(PCLinkCrypto.sha256(canonical))
        guard latest["recordSha256"]?.stringValue == digest else { return .unapproved }
        return .usable
    }
}

public enum PCLinkPairingStoreState: Equatable, Sendable {
    case none
    case usable(PCLinkPairingRecord)
    /// The record's phoneMachineId does not match this identity: preserved for
    /// inspection, never used, UI requires a new pairing.
    case stale(PCLinkPairingRecord)
}

public protocol PCLinkPairingStore: Sendable {
    func load(phoneMachineId: String) throws -> PCLinkPairingStoreState
    func save(_ record: PCLinkPairingRecord, phoneMachineId: String) throws
    func delete() throws
    func hasStoredFile() -> Bool
}

/// `{"v":1,"phoneMachineId":"...","records":[]}` in Application Support,
/// mode 0600, atomic replace with file and directory fsync. Exactly zero or
/// one record (§4.6).
public struct PCLinkFilePairingStore: PCLinkPairingStore {
    public let fileURL: URL

    public init(directory: URL? = nil) {
        let base: URL
        if let directory {
            base = directory
        } else {
            let support = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                        in: .userDomainMask,
                                                        appropriateFor: nil, create: true))
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            base = support.appendingPathComponent("PhoneDSHPCLink", isDirectory: true)
        }
        self.fileURL = base.appendingPathComponent("pairs.json")
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func hasStoredFile() -> Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    public func load(phoneMachineId: String) throws -> PCLinkPairingStoreState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .none }
        let data = try Data(contentsOf: fileURL)
        let value = try PCLinkJSONParser.parseObject(data)
        let object = try value.closedObject(required: ["v", "phoneMachineId", "records"])
        guard object["v"]?.intValue == 1 else {
            throw PCLinkError.storage("pairing file v is not 1")
        }
        let storedMachineId = try value.requiredString("phoneMachineId")
        try PCLinkValidation.requireMachineId(storedMachineId)
        guard let records = object["records"]?.arrayValue else {
            throw PCLinkError.storage("pairing file records is not an array")
        }
        guard records.count <= 1 else {
            throw PCLinkError.storage("the phone holds at most one pairing record")
        }
        guard let first = records.first else { return .none }
        try PCLinkPairingRecord.validatePhoneRecordJSON(first)
        let record = try PCLinkPairingRecord(json: first)
        guard storedMachineId == phoneMachineId else { return .stale(record) }
        return .usable(record)
    }

    public func save(_ record: PCLinkPairingRecord, phoneMachineId: String) throws {
        let document: PCLinkJSON = .object([
            "v": .int(1),
            "phoneMachineId": .string(phoneMachineId),
            "records": .array([record.json]),
        ])
        try AtomicFile.write(try PCLinkJSONEncoder.encode(document), to: fileURL)
    }

    public func delete() throws {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            if (error as NSError).code != NSFileNoSuchFileError { throw error }
        }
        try AtomicFile.fsyncDirectory(fileURL.deletingLastPathComponent())
    }
}

enum AtomicFile {
    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw PCLinkError.storage("cannot create \(directory.path): \(error)")
        }
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).tmp.\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            throw PCLinkError.storage("cannot create temporary file: errno \(errno)")
        }
        var success = false
        defer {
            close(descriptor)
            if !success { try? FileManager.default.removeItem(at: temporary) }
        }
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer -> Int in
                Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset),
                             bytes.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw PCLinkError.storage("write failed: errno \(errno)")
            }
            offset += written
        }
        guard fsync(descriptor) == 0 else {
            throw PCLinkError.storage("fsync failed: errno \(errno)")
        }
        guard rename(temporary.path, url.path) == 0 else {
            throw PCLinkError.storage("rename failed: errno \(errno)")
        }
        success = true
        try fsyncDirectory(directory)
        _ = chmod(url.path, 0o600)
    }

    static func fsyncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        if fsync(descriptor) != 0, errno != EINVAL {
            throw PCLinkError.storage("directory fsync failed: errno \(errno)")
        }
    }
}
