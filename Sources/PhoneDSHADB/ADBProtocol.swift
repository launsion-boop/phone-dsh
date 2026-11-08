// SPDX-License-Identifier: MIT
import Foundation

public struct ADBFailure: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

struct ADBPacket: Equatable, Sendable {
    static let connect: UInt32 = 0x4e584e43
    static let auth: UInt32 = 0x48545541
    static let open: UInt32 = 0x4e45504f
    static let okay: UInt32 = 0x59414b4f
    static let write: UInt32 = 0x45545257
    static let close: UInt32 = 0x45534c43
    static let tls: UInt32 = 0x534c5453
    let command: UInt32
    var arg0: UInt32 = 0
    var arg1: UInt32 = 0
    var payload = Data()

    var encoded: Data {
        var data = Data()
        for word in [command, arg0, arg1, UInt32(payload.count), checksum, command ^ .max] {
            data.appendLE(word)
        }
        data.append(payload)
        return data
    }
    var checksum: UInt32 { payload.reduce(0) { $0 &+ UInt32($1) } }

    static func read(from transport: any ADBTransport) async throws -> ADBPacket {
        let header = try await transport.read(count: 24)
        guard header.count == 24, header.le32(20) == header.le32(0) ^ UInt32.max else {
            throw ADBFailure("Invalid ADB packet header")
        }
        let count = Int(header.le32(12))
        guard count <= 1_048_576 else { throw ADBFailure("ADB packet exceeds size limit") }
        let data = count == 0 ? Data() : try await transport.read(count: count)
        let packet = ADBPacket(command: header.le32(0), arg0: header.le32(4), arg1: header.le32(8), payload: data)
        guard data.count == count, packet.checksum == header.le32(16) else {
            throw ADBFailure("Invalid ADB payload checksum")
        }
        return packet
    }
}

extension Data {
    func le32(_ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(self[startIndex + offset + $1]) << (8 * $1) }
    }
    mutating func appendLE(_ value: UInt32) {
        append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
    }
}

public struct ADBShellResult: Sendable, Equatable {
    public var stdout = Data()
    public var stderr = Data()
    public var exitCode: UInt8 = 0
    public init(stdout: Data = Data(), stderr: Data = Data(), exitCode: UInt8 = 0) {
        self.stdout = stdout; self.stderr = stderr; self.exitCode = exitCode
    }
}

/// shell_v2 frames can straddle any number of ADB WRTE packets.
struct ADBShellDecoder {
    private var pending = Data()
    private(set) var result = ADBShellResult()
    private(set) var exited = false
    let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    mutating func append(_ bytes: Data) throws {
        pending.append(bytes)
        while pending.count >= 5 {
            guard !exited else { throw ADBFailure("Data after ADB shell exit") }
            let size = Int(pending.le32(1))
            guard size <= min(limit, 1_048_576) else { throw ADBFailure("Android output exceeds size limit") }
            guard pending.count >= size + 5 else { return }
            let kind = pending[pending.startIndex]
            let data = Data(pending.dropFirst(5).prefix(size))
            pending = Data(pending.dropFirst(size + 5))
            switch kind {
            case 1: result.stdout.append(data)
            case 2: result.stderr.append(data)
            case 3:
                guard size == 1 else { throw ADBFailure("Invalid ADB shell exit frame") }
                result.exitCode = data[data.startIndex]; exited = true
            default: throw ADBFailure("Unexpected ADB shell frame")
            }
            guard result.stdout.count + result.stderr.count <= limit else {
                throw ADBFailure("Android output exceeds size limit")
            }
        }
    }

    mutating func takeStdout() -> Data {
        let data = result.stdout
        result.stdout = Data()
        return data
    }

    func finish() throws -> ADBShellResult {
        guard exited, pending.isEmpty else { throw ADBFailure("Android shell disconnected before reporting exit; command outcome unknown") }
        return result
    }
}
