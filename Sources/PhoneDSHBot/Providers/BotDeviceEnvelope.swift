// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

public enum BotDeviceTransport: String, Codable, Sendable {
    case bluetooth
    case lan
}

public enum BotDeviceEnvelopeError: Error, Sendable, Equatable {
    case invalid(String)
    case wrongSession
    case untrustedOrigin
    case conflict(String)
    case sequence(String)
}

public struct BotDeviceAudio: Codable, Sendable, Equatable {
    public let codec: String
    public let rate: Int
    public let ms: Int?

    public init(codec: String, rate: Int, ms: Int? = nil) {
        self.codec = codec
        self.rate = rate
        self.ms = ms
    }

    private enum CodingKeys: String, CodingKey { case codec, rate, ms }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let allowed: Set<String> = ["codec", "rate", "ms"]
        guard container.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw BotDeviceEnvelopeError.invalid("unknown audio fields")
        }
        codec = try container.decode(String.self, forKey: .codec)
        rate = try container.decode(Int.self, forKey: .rate)
        ms = try container.decodeIfPresent(Int.self, forKey: .ms)
    }
}

public struct BotDeviceEnvelope: Codable, Sendable, Equatable {
    public let v: Int
    public let msgID: String
    public let deviceID: String
    public let sessionID: String
    public let dir: String
    public let kind: String
    public let origin: String
    public let audience: String?
    public let seq: Int64
    public let epoch: Int64
    public let tsMs: Int64?
    public let text: String?
    public let audio: BotDeviceAudio?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case v
        case msgID = "msg_id"
        case deviceID = "device_id"
        case sessionID = "session_id"
        case dir, kind, origin, audience, seq, epoch
        case tsMs = "ts_ms"
        case text, audio
    }

    public init(v: Int = 1, msgID: String, deviceID: String, sessionID: String,
                dir: String = "up", kind: String = "text", origin: String = "device",
                audience: String? = "phone", seq: Int64, epoch: Int64 = 0,
                tsMs: Int64? = nil, text: String? = nil, audio: BotDeviceAudio? = nil) throws {
        self.v = v
        self.msgID = msgID
        self.deviceID = deviceID
        self.sessionID = sessionID
        self.dir = dir
        self.kind = kind
        self.origin = origin
        self.audience = audience
        self.seq = seq
        self.epoch = epoch
        self.tsMs = tsMs
        self.text = text
        self.audio = audio
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Contract 1 decoders ignore members they do not know; the schema stays
        // closed as an encoder target. Audio remains a closed nested object.
        v = try container.decode(Int.self, forKey: .v)
        msgID = try container.decode(String.self, forKey: .msgID)
        deviceID = try container.decode(String.self, forKey: .deviceID)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        dir = try container.decode(String.self, forKey: .dir)
        kind = try container.decode(String.self, forKey: .kind)
        origin = try container.decode(String.self, forKey: .origin)
        audience = try container.decodeIfPresent(String.self, forKey: .audience)
        seq = try container.decode(Int64.self, forKey: .seq)
        epoch = try container.decodeIfPresent(Int64.self, forKey: .epoch) ?? 0
        tsMs = try container.decodeIfPresent(Int64.self, forKey: .tsMs)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        audio = try container.decodeIfPresent(BotDeviceAudio.self, forKey: .audio)
        try validate()
    }

    public init(data: Data, expectedSessionID: String? = nil) throws {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let object = raw as? [String: Any] else {
            throw BotDeviceEnvelopeError.invalid("envelope must be an object")
        }
        if let audio = object["audio"] as? [String: Any],
           !Set(audio.keys).isSubset(of: ["codec", "rate", "ms"]) {
            throw BotDeviceEnvelopeError.invalid("unknown audio fields")
        }
        self = try JSONDecoder().decode(Self.self, from: data)
        if let expectedSessionID, sessionID != expectedSessionID {
            throw BotDeviceEnvelopeError.wrongSession
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(v, forKey: .v)
        try container.encode(msgID, forKey: .msgID)
        try container.encode(deviceID, forKey: .deviceID)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(dir, forKey: .dir)
        try container.encode(kind, forKey: .kind)
        try container.encode(origin, forKey: .origin)
        try container.encodeIfPresent(audience, forKey: .audience)
        try container.encode(seq, forKey: .seq)
        if epoch != 0 { try container.encode(epoch, forKey: .epoch) }
        try container.encodeIfPresent(tsMs, forKey: .tsMs)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(audio, forKey: .audio)
    }

    public func validate() throws {
        let identifier = #"^[A-Za-z0-9][A-Za-z0-9:._-]{0,127}$"#
        guard v == 1,
              msgID.range(of: identifier, options: .regularExpression) != nil,
              deviceID.range(of: identifier, options: .regularExpression) != nil,
              !sessionID.isEmpty, sessionID.count <= 256,
              ["up", "down"].contains(dir),
              ["device", "phone", "agent"].contains(origin),
              seq >= 0, seq < Int64.max, epoch >= 0, epoch < Int64.max,
              tsMs ?? 0 >= 0,
              (text?.count ?? 0) <= 1_048_576 else {
            throw BotDeviceEnvelopeError.invalid("invalid DeviceEnvelope v1")
        }
        if let audience, !["phone", "device", "both"].contains(audience) {
            throw BotDeviceEnvelopeError.invalid("invalid audience")
        }
        switch kind {
        case "text":
            guard text != nil else { throw BotDeviceEnvelopeError.invalid("text is required") }
        case "voice":
            guard let audio, !audio.codec.isEmpty, audio.codec.count <= 64,
                  audio.rate > 0, audio.ms ?? 1 > 0 else {
                throw BotDeviceEnvelopeError.invalid("voice requires a valid audio descriptor")
            }
        case "event", "ack", "command_result":
            break
        default:
            throw BotDeviceEnvelopeError.invalid("unknown envelope kind")
        }
    }

    public func validateIngress(expectedSessionID: String) throws {
        guard dir == "up", origin == "device" else { throw BotDeviceEnvelopeError.untrustedOrigin }
        guard sessionID == expectedSessionID else { throw BotDeviceEnvelopeError.wrongSession }
        guard kind != "voice" || text != nil else {
            throw BotDeviceEnvelopeError.invalid("voice without a transcript is not replayable")
        }
    }

    public func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public var jsonValue: BotJSONValue {
        get throws { try BotJSONValue.parse(canonicalData()) }
    }

    public var eventID: String {
        BotDeviceIdentifiers.durableID(deviceID: deviceID, epoch: epoch, msgID: msgID)
    }

    public func ingressEvent(botID: String, mainSessionID: String, transport: BotDeviceTransport,
                             displayName: String? = nil, receivedAt: Int64) throws -> BotEvent {
        let eventID = eventID
        var data: [String: BotJSONValue] = [
            "envelope": try jsonValue,
            "transport": .string(transport.rawValue),
            "receivedAt": .number(Double(receivedAt)),
        ]
        if let displayName, !displayName.isEmpty {
            data["displayName"] = .string(String(displayName.prefix(120)))
        }
        return BotEvent(
            type: "device.event", eventId: eventID, time: tsMs ?? receivedAt,
            origin: .local(source: "device:\(transport.rawValue):\(deviceID)"),
            traceId: eventID,
            principal: BotPrincipal(botId: botID, sessionId: mainSessionID, kind: "device"),
            causationId: nil, correlationId: eventID,
            data: .object(data))
    }

    public func heldItem(transport: BotDeviceTransport, displayName: String,
                         receivedAt: Int64) throws -> WakeInboxItem {
        let eventID = eventID
        let safeName = displayName.unicodeScalars.allSatisfy {
            $0 != "\n" && $0 != "\r" && $0.properties.generalCategory != .control
        } ? String(displayName.prefix(120)) : "device"
        return try WakeInboxItem(
            id: eventID, kind: "device-event", fromAgentId: deviceID,
            fromAgentName: safeName.isEmpty ? "device" : safeName,
            title: transport.rawValue, text: String((text ?? "").prefix(1200)),
            requestId: eventID, threadId: "device:\(deviceID)", createdAt: tsMs ?? receivedAt,
            deviceID: deviceID, transport: transport.rawValue, deviceSeq: seq,
            deviceEpoch: epoch)
    }
}

public enum BotDeviceIdentifiers {
    /// P23 event/held identity. The key is scoped to the device incarnation so
    /// two devices (or two epochs of one device) may both use msg_id "1".
    public static func durableID(deviceID: String, epoch: Int64, msgID: String) -> String {
        "dev:\(deviceID):\(epoch):\(msgID)"
    }

    /// P07 downlink msg_id must match the envelope identifier grammar and stay
    /// within 128 bytes; long scoped source ids are hashed deterministically.
    public static func downMessageID(deviceID: String, epoch: Int64, msgID: String) -> String {
        let preferred = "reply:" + durableID(deviceID: deviceID, epoch: epoch, msgID: msgID)
        guard preferred.utf8.count <= 128 else {
            let scoped = durableID(deviceID: deviceID, epoch: epoch, msgID: msgID)
            let digest = SHA256.hash(data: Data(scoped.utf8))
                .map { String(format: "%02x", $0) }.joined()
            return "reply:" + digest
        }
        return preferred
    }
}
