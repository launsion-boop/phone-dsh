// SPDX-License-Identifier: MIT
import Foundation
import PhoneDSHAgentCore
import PDSHLinkWire

public enum PDSHLink {
    public static let service = "6e400100-7f1b-4c5a-9a1e-786c696e6b00"
    public static let rx = "6e400101-7f1b-4c5a-9a1e-786c696e6b00"
    public static let tx = "6e400102-7f1b-4c5a-9a1e-786c696e6b00"
    public static let audioUp = "6e400103-7f1b-4c5a-9a1e-786c696e6b00"
    public static let capability: UInt32 = 1 << 20
    public static let appCapability: UInt32 = 1 << 10
    public static let maxRPC = 4096

    public struct Envelope: Equatable, Sendable {
        public var opcode: UInt8
        public var requestID: UInt16
        public var body: Data
        public init(opcode: UInt8, requestID: UInt16, body: Data) { self.opcode = opcode; self.requestID = requestID; self.body = body }
        public func encoded() throws -> Data {
            guard body.count <= 505 else { throw BLEFailure("Link message too large") }
            var output = [UInt8](repeating: 0, count: 512)
            let bytes = [UInt8](body)
            let count = pdsh_frame(opcode, requestID, bytes, bytes.count, &output)
            guard count > 0 else { throw BLEFailure("Invalid Link frame") }
            return Data(output.prefix(count))
        }
        public static func decode(_ data: Data) throws -> Self {
            try [UInt8](data).withUnsafeBufferPointer { input in
                var op: UInt8 = 0; var id: UInt16 = 0; var body: UnsafePointer<UInt8>?; var count = 0
                guard pdsh_decode(input.baseAddress, input.count, &op, &id, &body, &count) == 0, let body else { throw BLEFailure("Invalid Link length or CRC") }
                return Self(opcode: op, requestID: id, body: Data(bytes: body, count: count))
            }
        }
        public func segments(writeLimit: Int) throws -> [Data] {
            guard writeLimit >= 20 else { throw BLEFailure("Link ATT write budget too small") }
            let data = try encoded(), size = min(writeLimit, 244) - 1
            return stride(from: 0, to: data.count, by: size).map { offset in
                var segment = Data([UInt8((offset == 0 ? 2 : 0) | (offset + size >= data.count ? 1 : 0))])
                segment.append(data[offset..<min(offset + size, data.count)]); return segment
            }
        }
    }
    public struct Reassembler {
        private var bytes = Data()
        private var active = false
        public init() {}
        public mutating func push(_ segment: Data) throws -> Envelope? {
            guard (2...244).contains(segment.count), let flags = segment.first, flags & ~3 == 0 else { reset(); throw BLEFailure("Invalid Link segment") }
            if flags & 2 != 0 { bytes.removeAll(keepingCapacity: true); active = true }
            guard active, bytes.count + segment.count - 1 <= 512 else { reset(); throw BLEFailure("Invalid Link segment sequence") }
            bytes.append(segment.dropFirst())
            if flags & 1 != 0 { let data = bytes; reset(); return try Envelope.decode(data) }
            return nil
        }
        public mutating func reset() { active = false; bytes.removeAll(keepingCapacity: true) }
    }
    public struct Peer: Sendable {
        public let version: UInt16
        public let capabilities: UInt32
        public let bootID: UInt32
        public let supportsTools: Bool
        public init(helloACK data: Data) throws {
            let bytes = [UInt8](data)
            guard bytes.count >= 25, bytes[0] == 0, bytes.u16(1) >> 8 == 1, bytes.u16(23) >= 512 else { throw BLEFailure("Unsupported Link HELLO_ACK") }
            version = bytes.u16(1); capabilities = bytes.u32(3); bootID = bytes.u32(19)
            // A local extension tag avoids mistaking a future upstream capability allocation for this profile.
            supportsTools = capabilities & PDSHLink.capability != 0 && bytes.count >= 33 && Data(bytes[25..<29]) == Data("PDSH".utf8) && bytes.u16(29) == 1 && bytes.u16(31) == 4096
        }
    }
    public static var hello: Data { var data = Data(); data.put(UInt16(0x0102)); data.put(appCapability); return data }
}

@MainActor public protocol PDSHLinkTransport: AnyObject {
    func exchange(opcode: UInt8, body: Data) async throws -> Data
}

@MainActor public final class PDSHLinkClient {
    private let transport: any PDSHLinkTransport
    private var peer: PDSHLink.Peer?
    public init(transport: any PDSHLinkTransport) { self.transport = transport }
    public func handshake() async throws -> PDSHLink.Peer {
        peer = nil
        let value = try await PDSHLink.Peer(helloACK: transport.exchange(opcode: 1, body: PDSHLink.hello))
        peer = value; return value
    }
    public func invoke(requestID: UUID, name: String, arguments: JSONValue, idempotencyKey: String, ttlMS: UInt32 = 15000) async throws -> JSONValue {
        guard peer?.supportsTools == true else { throw BLEFailure("PDSH Tools was not negotiated; refusing extension request") }
        guard (100...30000).contains(ttlMS) else { throw BLEFailure("Invalid Link deadline") }
        let request = JSONValue.object(["request_id": .string(requestID.uuidString.lowercased()), "name": .string(name), "args": arguments, "idem_key": .string(idempotencyKey)])
        let bytes = try request.encoded()
        guard !bytes.isEmpty, bytes.count <= PDSHLink.maxRPC else { throw BLEFailure("Tool request exceeds 4096 bytes") }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(ttlMS)))
        for offset in stride(from: 0, to: bytes.count, by: 481) {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw BLEFailure("Link upload expired") }
            var packet = requestID.linkBytes; packet.put(UInt16(bytes.count)); packet.put(UInt16(offset)); packet.put(ttlMS)
            packet.append(bytes[offset..<min(offset + 481, bytes.count)])
            let reply = [UInt8](try await transport.exchange(opcode: 0x54, body: packet))
            guard reply.count == 3, reply[0] == 0, reply.u16(1) == min(offset + 481, bytes.count) else { throw BLEFailure("Link upload rejected") }
        }
        // No automatic commit retry. Once submitted, only read-only result queries are safe.
        let reply = [UInt8](try await transport.exchange(opcode: 0x55, body: requestID.linkBytes))
        guard reply.count >= 2, reply[0] == 0 else { throw BLEFailure("Link commit rejected; query request_id before any new action") }
        while ContinuousClock.now < deadline {
            if let result = try await query(requestID: requestID) { return result }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw BLEFailure("outcome_unknown: Link deadline elapsed; query request_id, never repeat the action automatically")
    }
    /// nil = still executing; missing receipts explicitly mean outcome_unknown, never permission to replay.
    public func query(requestID: UUID) async throws -> JSONValue? {
        guard peer?.supportsTools == true else { throw BLEFailure("PDSH Tools was not negotiated; refusing result query") }
        var result = Data(), total: Int?
        repeat {
            try Task.checkCancellation()
            var packet = requestID.linkBytes; packet.put(UInt16(result.count))
            let reply = [UInt8](try await transport.exchange(opcode: 0x56, body: packet))
            guard reply.count >= 6, reply[0] == 0 else { throw BLEFailure("Link result query rejected") }
            switch reply[1] {
            case 0, 3: return .object(["request_id": .string(requestID.uuidString.lowercased()), "status": .string("outcome_unknown")])
            case 1: guard result.isEmpty else { throw BLEFailure("Link result changed during read") }; return nil
            case 2: break
            default: throw BLEFailure("Unknown Link result state")
            }
            let length = Int(reply.u16(2)), offset = Int(reply.u16(4))
            guard length > 0, length <= PDSHLink.maxRPC, offset == result.count, total == nil || total == length,
                  reply.count > 6, result.count + reply.count - 6 <= length else { throw BLEFailure("Invalid Link result chunk") }
            total = length; result.append(contentsOf: reply.dropFirst(6))
        } while result.count != total
        let value = try JSONValue.parse(result)
        guard case .object(let fields) = value, fields["request_id"] == .string(requestID.uuidString.lowercased()),
              fields["status"] == .string("completed") || fields["status"] == .string("failed") || fields["status"] == .string("outcome_unknown") else { throw BLEFailure("Mismatched Link tool result") }
        return value
    }
}

extension UUID {
    var linkBytes: Data { var value = uuid; return withUnsafeBytes(of: &value) { Data($0) } }
}
extension Data {
    mutating func put(_ value: UInt16) { append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8)) }
    mutating func put(_ value: UInt32) { put(UInt16(truncatingIfNeeded: value)); put(UInt16(truncatingIfNeeded: value >> 16)) }
}
extension Array where Element == UInt8 {
    func u16(_ i: Int) -> UInt16 { UInt16(self[i]) | UInt16(self[i+1]) << 8 }
    func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i+2)) << 16 }
}

public struct PDSHLinkEvent: Sendable {
    public let sequence: UInt32
    public let type: String
    public init(data: Data, expectedBootID: UInt32, expectedDeviceID: String) throws {
        guard data.count <= 505, !expectedDeviceID.isEmpty,
              case .object(let fields) = try JSONValue.parse(data),
              fields["boot_id"] == .number(Double(expectedBootID)), fields["device_id"] == .string(expectedDeviceID),
              case .number(let seq) = fields["seq"], seq >= 1, seq <= Double(UInt32.max), seq.rounded() == seq,
              case .string(let kind) = fields["type"], !kind.isEmpty, kind.utf8.count <= 64, fields["payload"] != nil else { throw BLEFailure("Invalid Link event identity or sequence") }
        sequence = UInt32(seq); type = kind
        guard fields["event_id"] == .string(String(format: "%08x-%08x", expectedBootID, sequence)) else { throw BLEFailure("Invalid Link event ID") }
    }
}
