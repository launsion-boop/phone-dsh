// SPDX-License-Identifier: MIT
// PhoneDSHPCLink: QR URI, manual code, rendezvous and pairing MACs (§4).

import Foundation

public enum PCLinkPairingMode: String, Sendable, Codable {
    case qr
    case manual
}

public struct PCLinkPairingOffer: Equatable, Sendable {
    public var mode: PCLinkPairingMode
    public var relayOrigin: String
    public var secret: Data
    /// Pinned PC machineId from the QR. `nil` for the manual path until
    /// `pair.hello` arrives.
    public var pcMachineId: String?
    /// Pinned PC identity public key from the QR. `nil` for manual.
    public var pcPublicKey: Data?
    public var pcName: String?

    public init(mode: PCLinkPairingMode, relayOrigin: String, secret: Data,
                pcMachineId: String? = nil, pcPublicKey: Data? = nil, pcName: String? = nil) {
        self.mode = mode
        self.relayOrigin = relayOrigin
        self.secret = secret
        self.pcMachineId = pcMachineId
        self.pcPublicKey = pcPublicKey
        self.pcName = pcName
    }

    public var rendezvous: String {
        PCLinkCrypto.rendezvous(secret: secret, relayOrigin: relayOrigin)
    }

    public var pairKey: Data {
        PCLinkCrypto.pairKey(secret: secret)
    }

    public var websocketURL: URL {
        get throws { try PCLinkValidation.websocketURL(for: relayOrigin) }
    }
}

public enum PCLinkQRCode {
    /// Parses the frozen `pclink://pair?v=1&r=...&m=...&k=...&s=...&n=...`
    /// form. The parser is intentionally hand-written: `URLComponents` would
    /// tolerate a raw `+`, duplicate parameters and uppercase origins that the
    /// contract rejects.
    public static func parse(_ uri: String) throws -> PCLinkPairingOffer {
        guard uri.utf8.count <= 512 else { throw PCLinkError.badFrame("QR URI exceeds 512 bytes") }
        guard !uri.contains("#") else { throw PCLinkError.badFrame("QR URI must not have a fragment") }
        let prefix = "pclink://pair?"
        guard uri.hasPrefix(prefix) else { throw PCLinkError.badFrame("QR URI must be pclink://pair") }
        let query = String(uri.dropFirst(prefix.count))
        guard !query.contains("+") else { throw PCLinkError.badFrame("QR URI must not contain a raw +") }
        var parameters: [String: String] = [:]
        for pair in query.components(separatedBy: "&") {
            guard !pair.isEmpty else { throw PCLinkError.badFrame("empty QR query parameter") }
            let pieces = pair.components(separatedBy: "=")
            guard pieces.count == 2, !pieces[0].isEmpty else {
                throw PCLinkError.badFrame("QR query parameter is malformed")
            }
            guard !pieces[0].contains("%") else {
                throw PCLinkError.badFrame("QR parameter names must not be percent-encoded")
            }
            guard parameters[pieces[0]] == nil else {
                throw PCLinkError.badFrame("duplicate QR parameter \(pieces[0])")
            }
            parameters[pieces[0]] = try percentDecode(pieces[1])
        }
        let allowed: Set<String> = ["v", "r", "m", "k", "s", "n"]
        for key in parameters.keys where !allowed.contains(key) {
            throw PCLinkError.badFrame("unknown QR parameter \(key)")
        }
        guard parameters["v"] == "1" else { throw PCLinkError.badFrame("QR v must be 1") }
        guard let origin = parameters["r"], let machineId = parameters["m"],
              let keyText = parameters["k"], let secretText = parameters["s"],
              let name = parameters["n"] else {
            throw PCLinkError.badFrame("QR is missing a required parameter")
        }
        try PCLinkValidation.origin(origin)
        try PCLinkValidation.requireMachineId(machineId, field: "m")
        let publicKey = try PCLinkBase64URL.decode(keyText, expectedBytes: 32)
        let secret = try PCLinkBase64URL.decode(secretText, expectedBytes: 16)
        guard PCLinkBase32.machineId(fromPublicKey: publicKey) == machineId else {
            throw PCLinkError.authFailed("QR machineId does not match its public key")
        }
        try PCLinkValidation.name(name)
        return PCLinkPairingOffer(mode: .qr, relayOrigin: origin, secret: secret,
                                  pcMachineId: machineId, pcPublicKey: publicKey, pcName: name)
    }

    public static func makeURI(relayOrigin: String, pcMachineId: String, pcPublicKey: Data,
                               secret: Data, pcName: String) throws -> String {
        try PCLinkValidation.origin(relayOrigin)
        try PCLinkValidation.requireMachineId(pcMachineId)
        guard pcPublicKey.count == 32, secret.count == 16 else {
            throw PCLinkError.badFrame("QR key/secret length")
        }
        guard PCLinkBase32.machineId(fromPublicKey: pcPublicKey) == pcMachineId else {
            throw PCLinkError.authFailed("QR machineId does not match its public key")
        }
        try PCLinkValidation.name(pcName)
        let query = [
            "v=1",
            "r=\(percentEncode(relayOrigin))",
            "m=\(pcMachineId)",
            "k=\(PCLinkBase64URL.encode(pcPublicKey))",
            "s=\(PCLinkBase64URL.encode(secret))",
            "n=\(percentEncode(pcName))",
        ].joined(separator: "&")
        let uri = "pclink://pair?" + query
        guard uri.utf8.count <= 512 else { throw PCLinkError.badFrame("QR URI exceeds 512 bytes") }
        return uri
    }

    /// RFC 3986 unreserved characters stay literal; everything else is
    /// uppercase `%XX`, so spaces are `%20` (never `+`).
    public static func percentEncode(_ value: String) -> String {
        var result = ""
        for byte in value.utf8 {
            let unreserved = (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || (byte >= 0x30 && byte <= 0x39) || byte == 0x2D || byte == 0x2E
                || byte == 0x5F || byte == 0x7E
            if unreserved {
                result.append(Character(UnicodeScalar(byte)))
            } else {
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }

    public static func percentDecode(_ value: String) throws -> String {
        var bytes: [UInt8] = []
        let scalars = Array(value.utf8)
        var index = 0
        while index < scalars.count {
            let byte = scalars[index]
            if byte == 0x25 { // %
                guard index + 2 < scalars.count,
                      let high = hexValue(scalars[index + 1]),
                      let low = hexValue(scalars[index + 2]) else {
                    throw PCLinkError.badFrame("invalid percent escape")
                }
                bytes.append(high << 4 | low)
                index += 3
            } else if byte == 0x2B {
                throw PCLinkError.badFrame("raw + is not a space")
            } else {
                bytes.append(byte)
                index += 1
            }
        }
        guard let decoded = String(bytes: bytes, encoding: .utf8) else {
            throw PCLinkError.badFrame("percent escape is not UTF-8")
        }
        return decoded
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x61...0x66: return byte - 0x61 + 10
        case 0x41...0x46: return byte - 0x41 + 10
        default: return nil
        }
    }
}

public enum PCLinkManualCode {
    public static func parse(_ input: String, relayOrigin: String) throws -> PCLinkPairingOffer {
        try PCLinkValidation.origin(relayOrigin)
        let secret = try PCLinkCrockford.decode(input)
        return PCLinkPairingOffer(mode: .manual, relayOrigin: relayOrigin, secret: secret)
    }

    public static func display(_ secret: Data) throws -> String {
        try PCLinkCrockford.display(PCLinkCrockford.encode(secret))
    }
}

// MARK: - Pairing messages

public enum PCLinkPairingMessage: Equatable, Sendable {
    case hello(PCLinkPairHello)
    case auth(PCLinkPairAuth)
    case confirm(PCLinkPairConfirm)
    case final(PCLinkPairFinal)

    public var type: String {
        switch self {
        case .hello: return "pair.hello"
        case .auth: return "pair.auth"
        case .confirm: return "pair.confirm"
        case .final: return "pair.final"
        }
    }

    public var raw: PCLinkJSON {
        switch self {
        case .hello(let message): return message.raw
        case .auth(let message): return message.raw
        case .confirm(let message): return message.raw
        case .final(let message): return message.raw
        }
    }

    /// MAC verification uses the canonical object without `mac`.
    public func verifyMAC(pairKey: Data) throws {
        let domain: String
        switch self {
        case .hello: domain = PCLinkCrypto.pairHelloDomain
        case .auth: domain = PCLinkCrypto.pairAuthDomain
        case .confirm: domain = PCLinkCrypto.pairConfirmDomain
        case .final: domain = PCLinkCrypto.pairFinalDomain
        }
        let macText: String
        switch self {
        case .hello(let message): macText = message.mac
        case .auth(let message): macText = message.mac
        case .confirm(let message): macText = message.mac
        case .final(let message): macText = message.mac
        }
        let mac = try PCLinkBase64URL.decode(macText, expectedBytes: 32)
        guard var object = raw.objectValue else { throw PCLinkError.badFrame("pairing message is not an object") }
        object.removeValue(forKey: "mac")
        let expected = try PCLinkCrypto.pairMAC(pairKey: pairKey, domain: domain,
                                                objectWithoutMAC: .object(object))
        guard PCLinkCrypto.constantTimeEquals(mac, expected) else {
            throw PCLinkError.authFailed("pairing MAC mismatch")
        }
    }

    public func canonicalWithoutMAC() throws -> PCLinkJSON {
        guard var object = raw.objectValue else { throw PCLinkError.badFrame("pairing message is not an object") }
        object.removeValue(forKey: "mac")
        return .object(object)
    }

    public static func decode(_ value: PCLinkJSON) throws -> PCLinkPairingMessage {
        guard let object = value.objectValue else { throw PCLinkError.badFrame("pairing payload is not an object") }
        switch object["type"]?.stringValue {
        case "pair.hello": return .hello(try PCLinkPairHello(value))
        case "pair.auth": return .auth(try PCLinkPairAuth(value))
        case "pair.confirm": return .confirm(try PCLinkPairConfirm(value))
        case "pair.final": return .final(try PCLinkPairFinal(value))
        default: throw PCLinkError.badFrame("unknown pairing message type")
        }
    }

    public static func makeHello(machineId: String, publicKey: Data, name: String,
                                 relayOrigin: String, nonce: Data, pairKey: Data) throws -> PCLinkPairHello {
        var object: [String: PCLinkJSON] = [
            "v": .int(1), "type": .string("pair.hello"), "role": .string("pc"),
            "machineId": .string(machineId),
            "publicKey": .string(PCLinkBase64URL.encode(publicKey)),
            "name": .string(name),
            "relay": .string(relayOrigin),
            "nonce": .string(PCLinkBase64URL.encode(nonce)),
        ]
        let mac = try PCLinkCrypto.pairMAC(pairKey: pairKey, domain: PCLinkCrypto.pairHelloDomain,
                                           objectWithoutMAC: .object(object))
        object["mac"] = .string(PCLinkBase64URL.encode(mac))
        return try PCLinkPairHello(.object(object))
    }

    public static func makeAuth(machineId: String, publicKey: Data, name: String,
                                relayOrigin: String, nonce: Data, peerNonce: Data,
                                pairKey: Data) throws -> PCLinkPairAuth {
        var object: [String: PCLinkJSON] = [
            "v": .int(1), "type": .string("pair.auth"), "role": .string("phone"),
            "machineId": .string(machineId),
            "publicKey": .string(PCLinkBase64URL.encode(publicKey)),
            "name": .string(name),
            "relay": .string(relayOrigin),
            "nonce": .string(PCLinkBase64URL.encode(nonce)),
            "peerNonce": .string(PCLinkBase64URL.encode(peerNonce)),
        ]
        let mac = try PCLinkCrypto.pairMAC(pairKey: pairKey, domain: PCLinkCrypto.pairAuthDomain,
                                           objectWithoutMAC: .object(object))
        object["mac"] = .string(PCLinkBase64URL.encode(mac))
        return try PCLinkPairAuth(.object(object))
    }

    public static func makeConfirm(helloNonce: Data, authNonce: Data, transcriptHash: Data,
                                   pairKey: Data) throws -> PCLinkPairConfirm {
        var object: [String: PCLinkJSON] = [
            "v": .int(1), "type": .string("pair.confirm"), "role": .string("pc"),
            "nonce": .string(PCLinkBase64URL.encode(helloNonce)),
            "peerNonce": .string(PCLinkBase64URL.encode(authNonce)),
            "transcriptHash": .string(PCLinkBase64URL.encode(transcriptHash)),
        ]
        let mac = try PCLinkCrypto.pairMAC(pairKey: pairKey, domain: PCLinkCrypto.pairConfirmDomain,
                                           objectWithoutMAC: .object(object))
        object["mac"] = .string(PCLinkBase64URL.encode(mac))
        return try PCLinkPairConfirm(.object(object))
    }

    public static func makeFinal(authNonce: Data, helloNonce: Data, transcriptHash: Data,
                                 pairKey: Data) throws -> PCLinkPairFinal {
        var object: [String: PCLinkJSON] = [
            "v": .int(1), "type": .string("pair.final"), "role": .string("phone"),
            "nonce": .string(PCLinkBase64URL.encode(authNonce)),
            "peerNonce": .string(PCLinkBase64URL.encode(helloNonce)),
            "transcriptHash": .string(PCLinkBase64URL.encode(transcriptHash)),
        ]
        let mac = try PCLinkCrypto.pairMAC(pairKey: pairKey, domain: PCLinkCrypto.pairFinalDomain,
                                           objectWithoutMAC: .object(object))
        object["mac"] = .string(PCLinkBase64URL.encode(mac))
        return try PCLinkPairFinal(.object(object))
    }
}

public struct PCLinkPairHello: Equatable, Sendable {
    public var raw: PCLinkJSON
    public init(_ value: PCLinkJSON) throws {
        let object = try value.closedObject(required: ["v", "type", "role", "machineId", "publicKey",
                                                       "name", "relay", "nonce", "mac"])
        guard object["v"]?.intValue == 1, object["type"]?.stringValue == "pair.hello",
              object["role"]?.stringValue == "pc" else {
            throw PCLinkError.badFrame("pair.hello header")
        }
        try PCLinkValidation.requireMachineId(try value.requiredString("machineId"))
        _ = try PCLinkBase64URL.decode(try value.requiredString("publicKey"), expectedBytes: 32)
        try PCLinkValidation.name(try value.requiredString("name"))
        try PCLinkValidation.origin(try value.requiredString("relay"))
        _ = try PCLinkBase64URL.decode(try value.requiredString("nonce"), expectedBytes: 32)
        _ = try PCLinkBase64URL.decode(try value.requiredString("mac"), expectedBytes: 32)
        self.raw = value
    }
    public var machineId: String { (try? raw.requiredString("machineId")) ?? "" }
    public var publicKey: Data { (try? PCLinkBase64URL.decode(raw.requiredString("publicKey"), expectedBytes: 32)) ?? Data() }
    public var name: String { (try? raw.requiredString("name")) ?? "" }
    public var relay: String { (try? raw.requiredString("relay")) ?? "" }
    public var nonce: Data { (try? PCLinkBase64URL.decode(raw.requiredString("nonce"), expectedBytes: 32)) ?? Data() }
    public var mac: String { (try? raw.requiredString("mac")) ?? "" }
}

public struct PCLinkPairAuth: Equatable, Sendable {
    public var raw: PCLinkJSON
    public init(_ value: PCLinkJSON) throws {
        let object = try value.closedObject(required: ["v", "type", "role", "machineId", "publicKey",
                                                       "name", "relay", "nonce", "peerNonce", "mac"])
        guard object["v"]?.intValue == 1, object["type"]?.stringValue == "pair.auth",
              object["role"]?.stringValue == "phone" else {
            throw PCLinkError.badFrame("pair.auth header")
        }
        try PCLinkValidation.requireMachineId(try value.requiredString("machineId"))
        _ = try PCLinkBase64URL.decode(try value.requiredString("publicKey"), expectedBytes: 32)
        try PCLinkValidation.name(try value.requiredString("name"))
        try PCLinkValidation.origin(try value.requiredString("relay"))
        _ = try PCLinkBase64URL.decode(try value.requiredString("nonce"), expectedBytes: 32)
        _ = try PCLinkBase64URL.decode(try value.requiredString("peerNonce"), expectedBytes: 32)
        _ = try PCLinkBase64URL.decode(try value.requiredString("mac"), expectedBytes: 32)
        self.raw = value
    }
    public var machineId: String { (try? raw.requiredString("machineId")) ?? "" }
    public var publicKey: Data { (try? PCLinkBase64URL.decode(raw.requiredString("publicKey"), expectedBytes: 32)) ?? Data() }
    public var name: String { (try? raw.requiredString("name")) ?? "" }
    public var relay: String { (try? raw.requiredString("relay")) ?? "" }
    public var nonce: Data { (try? PCLinkBase64URL.decode(raw.requiredString("nonce"), expectedBytes: 32)) ?? Data() }
    public var peerNonce: Data { (try? PCLinkBase64URL.decode(raw.requiredString("peerNonce"), expectedBytes: 32)) ?? Data() }
    public var mac: String { (try? raw.requiredString("mac")) ?? "" }
}

public struct PCLinkPairConfirm: Equatable, Sendable {
    public var raw: PCLinkJSON
    public init(_ value: PCLinkJSON) throws {
        let object = try value.closedObject(required: ["v", "type", "role", "nonce", "peerNonce",
                                                       "transcriptHash", "mac"])
        guard object["v"]?.intValue == 1, object["type"]?.stringValue == "pair.confirm",
              object["role"]?.stringValue == "pc" else {
            throw PCLinkError.badFrame("pair.confirm header")
        }
        _ = try PCLinkBase64URL.decode(try value.requiredString("nonce"), expectedBytes: 32)
        _ = try PCLinkBase64URL.decode(try value.requiredString("peerNonce"), expectedBytes: 32)
        _ = try PCLinkBase64URL.decode(try value.requiredString("transcriptHash"), expectedBytes: 32)
        _ = try PCLinkBase64URL.decode(try value.requiredString("mac"), expectedBytes: 32)
        self.raw = value
    }
    public var nonce: Data { (try? PCLinkBase64URL.decode(raw.requiredString("nonce"), expectedBytes: 32)) ?? Data() }
    public var peerNonce: Data { (try? PCLinkBase64URL.decode(raw.requiredString("peerNonce"), expectedBytes: 32)) ?? Data() }
    public var transcriptHash: Data { (try? PCLinkBase64URL.decode(raw.requiredString("transcriptHash"), expectedBytes: 32)) ?? Data() }
    public var mac: String { (try? raw.requiredString("mac")) ?? "" }
}

public struct PCLinkPairFinal: Equatable, Sendable {
    public var raw: PCLinkJSON
    public init(_ value: PCLinkJSON) throws {
        let object = try value.closedObject(required: ["v", "type", "role", "nonce", "peerNonce",
                                                       "transcriptHash", "mac"])
        guard object["v"]?.intValue == 1, object["type"]?.stringValue == "pair.final",
              object["role"]?.stringValue == "phone" else {
            throw PCLinkError.badFrame("pair.final header")
        }
        _ = try PCLinkBase64URL.decode(try value.requiredString("nonce"), expectedBytes: 32)
        _ = try PCLinkBase64URL.decode(try value.requiredString("peerNonce"), expectedBytes: 32)
        _ = try PCLinkBase64URL.decode(try value.requiredString("transcriptHash"), expectedBytes: 32)
        _ = try PCLinkBase64URL.decode(try value.requiredString("mac"), expectedBytes: 32)
        self.raw = value
    }
    public var mac: String { (try? raw.requiredString("mac")) ?? "" }
}

public extension PCLinkPairingOffer {
    /// Validates a received `pair.hello` against the QR pin and the frozen
    /// pairing MAC rules. A manual offer has no pin, so the key-derived
    /// machineId must still match the message.
    func verifyHello(_ hello: PCLinkPairHello) throws {
        guard hello.relay == relayOrigin else {
            throw PCLinkError.authFailed("pair.hello relay does not match the pairing origin")
        }
        let derived = PCLinkBase32.machineId(fromPublicKey: hello.publicKey)
        guard derived == hello.machineId else {
            throw PCLinkError.authFailed("pair.hello machineId does not match its key")
        }
        if let pinnedMachineId = pcMachineId, hello.machineId != pinnedMachineId {
            throw PCLinkError.authFailed("pair.hello machineId does not match the QR pin")
        }
        if let pinnedKey = pcPublicKey, hello.publicKey != pinnedKey {
            throw PCLinkError.authFailed("pair.hello publicKey does not match the QR pin")
        }
        try PCLinkPairingMessage.hello(hello).verifyMAC(pairKey: pairKey)
    }
}

// MARK: - Approval fingerprints

public enum PCLinkApproval {
    /// The PC operator's typed fingerprint is valid for the phone key.
    public static func fingerprintMatches(input: String, publicKey: Data) -> Bool {
        let machineId = PCLinkBase32.machineId(fromPublicKey: publicKey)
        return PCLinkValidation.fingerprintMatches(input: input, machineId: machineId)
    }
}
