// SPDX-License-Identifier: MIT
import XCTest
import Security
import Network
@testable import PhoneDSHADB

final class ADBProtocolTests: XCTestCase {
    func identity() throws -> ADBIdentity {
        let key = try XCTUnwrap(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048] as CFDictionary, nil))
        return ADBIdentity(key: key)
    }
    func testPacketGoldenAndChecksumRejection() async throws {
        let packet = ADBPacket(command: ADBPacket.open, arg0: 1, payload: Data([97, 0]))
        XCTAssertEqual(packet.encoded.map { String(format: "%02x", $0) }.joined(),
                       "4f50454e01000000000000000200000061000000b0afbab16100")
        let decoded = try await ADBPacket.read(from: ScriptedADB(packets: [packet]))
        XCTAssertEqual(decoded, packet)
        var corrupt = packet.encoded; corrupt[24] = 98
        do { _ = try await ADBPacket.read(from: ScriptedADB(bytes: corrupt)); XCTFail("checksum accepted") } catch {}
        var oversized = packet.encoded; oversized.replaceSubrange(12..<16, with: [0, 0, 32, 0])
        do { _ = try await ADBPacket.read(from: ScriptedADB(bytes: oversized)); XCTFail("oversized packet accepted") } catch {}
    }
    func testAndroidKeyMontgomeryParameters() throws {
        // N = 2^2048 - 159 => R² mod N = 159² = 25281 (0x62c1).
        var der = Data([0x30, 0x82, 0x01, 0x0a, 0x02, 0x82, 0x01, 0x01, 0])
        der.append(contentsOf: [UInt8](repeating: 255, count: 255)); der.append(97)
        der.append(contentsOf: [2, 3, 1, 0, 1])
        let encoded = try ADBIdentity.androidPublicKey(der)
        XCTAssertEqual(encoded.count, 524)
        XCTAssertEqual(encoded.le32(0), 64)
        XCTAssertEqual(encoded.le32(4) &* encoded.le32(8), UInt32.max)
        XCTAssertEqual(encoded.le32(264), 25281)
        XCTAssertTrue(encoded[268..<520].allSatisfy { $0 == 0 })
        XCTAssertEqual(encoded.le32(520), 65537)
    }
    func testSignatureAndPublicKeyUseSameIdentity() throws {
        let identity = try identity()
        let token = Data(repeating: 19, count: 20)
        let publicText = String(decoding: try identity.publicKey(), as: UTF8.self)
        let publicBytes = try XCTUnwrap(Data(base64Encoded: String(publicText.split(separator: " ")[0])))
        var der = Data([0x30, 0x82, 0x01, 0x0a, 0x02, 0x82, 0x01, 0x01, 0])
        der.append(contentsOf: publicBytes[8..<264].reversed()); der.append(contentsOf: [2, 3, 1, 0, 1])
        let key = try XCTUnwrap(SecKeyCreateWithData(der as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil))
        XCTAssertTrue(SecKeyVerifySignature(key, .rsaSignatureDigestPKCS1v15SHA1,
                                           token as CFData, try identity.sign(token) as CFData, nil))
        XCTAssertThrowsError(try identity.sign(Data()))
    }
    func testFragmentedShellFramesPreserveBinaryAndNonzeroExit() throws {
        var decoder = ADBShellDecoder(limit: 100)
        let stdout = Data([0, 255, 13, 10])
        let stream = shellFrame(1, stdout) + shellFrame(2, Data("error".utf8)) + shellFrame(3, Data([7]))
        for byte in stream { try decoder.append(Data([byte])) }
        XCTAssertEqual(try decoder.finish(), ADBShellResult(stdout: stdout, stderr: Data("error".utf8), exitCode: 7))
        XCTAssertThrowsError(try decoder.append(shellFrame(1, Data())))
    }
    func testShellMissingExitAndOutputOverflowFail() throws {
        var decoder = ADBShellDecoder(limit: 4)
        try decoder.append(shellFrame(1, Data([1, 2, 3])))
        XCTAssertThrowsError(try decoder.finish())
        XCTAssertThrowsError(try decoder.append(shellFrame(2, Data([4, 5]))))
    }
    func testAuthPublicKeyFallbackAndShellRoundTrip() async throws {
        let transport = ScriptedADB(packets: [
            ADBPacket(command: ADBPacket.auth, arg0: 1, payload: Data(repeating: 1, count: 20)),
            ADBPacket(command: ADBPacket.auth, arg0: 1, payload: Data(repeating: 2, count: 20)),
            connected(), ADBPacket(command: ADBPacket.okay, arg0: 42, arg1: 1),
            ADBPacket(command: ADBPacket.okay, arg0: 42, arg1: 1),
            ADBPacket(command: ADBPacket.write, arg0: 42, arg1: 1, payload: shellFrame(1, Data("hello".utf8)) + shellFrame(3, Data([0]))),
            ADBPacket(command: ADBPacket.close, arg0: 42, arg1: 1),
        ])
        let result = try await ADBClient.shell(transport: transport, identity: identity(), command: "echo hello", timeout: 1, outputLimit: 100)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "hello")
        XCTAssertEqual(transport.sent.map { $0.le32(0) }, [ADBPacket.connect, ADBPacket.auth, ADBPacket.auth,
            ADBPacket.open, ADBPacket.write, ADBPacket.okay, ADBPacket.close])
        XCTAssertEqual(transport.sent[1].le32(4), 2)
        XCTAssertEqual(transport.sent[2].le32(4), 3)
        XCTAssertEqual(transport.sent[3].dropFirst(24), Data("shell,v2,raw:echo hello\0".utf8))
        XCTAssertTrue(transport.closed)
    }
    func testConnectionClosedDuringAuthHandshakeReportsUnauthorized() async throws {
        let transport = ScriptedADB(packets: [
            ADBPacket(command: ADBPacket.auth, arg0: 1, payload: Data(repeating: 1, count: 20)),
            ADBPacket(command: ADBPacket.auth, arg0: 1, payload: Data(repeating: 2, count: 20)),
        ])
        do {
            _ = try await ADBClient.shell(transport: transport, identity: identity(), command: "id", timeout: 1, outputLimit: 100)
            XCTFail("expected unauthorized failure when adbd closes or times out waiting for user approval")
        } catch let failure as ADBFailure {
            XCTAssertEqual(failure.kind, .unauthorized)
        }
        XCTAssertEqual(transport.sent.map { $0.le32(0) }, [ADBPacket.connect, ADBPacket.auth, ADBPacket.auth])
        XCTAssertTrue(transport.closed)
    }
    func testTLSAndUnexpectedStreamAreRejectedWithoutRetry() async throws {
        for packets in [[ADBPacket(command: ADBPacket.tls)], [connected(), ADBPacket(command: ADBPacket.close, arg0: 0, arg1: 1)]] {
            let transport = ScriptedADB(packets: packets)
            do { _ = try await ADBClient.shell(transport: transport, identity: identity(), command: "input tap 1 2", timeout: 1, outputLimit: 100); XCTFail("accepted") }
            catch {}
            XCTAssertLessThanOrEqual(transport.sent.filter { $0.le32(0) == ADBPacket.open }.count, 1)
            XCTAssertTrue(transport.closed)
        }
    }
    func testAPKInputIsChunkedAcknowledgedAndClosedWhileReceivingOutput() async throws {
        let bytes = Data((0..<9005).map { UInt8(truncatingIfNeeded: $0) }).dropFirst(5)
        let ack = ADBPacket(command: ADBPacket.okay, arg0: 42, arg1: 1)
        let output = ADBPacket(command: ADBPacket.write, arg0: 42, arg1: 1,
                               payload: shellFrame(1, Data("Success\n".utf8)) + shellFrame(3, Data([0])))
        let transport = ScriptedADB(packets: [connected(), ack,
            ADBPacket(command: ADBPacket.write, arg0: 42, arg1: 1, payload: shellFrame(2, Data("progress".utf8))),
            ack, ack, ack, ack, output, ADBPacket(command: ADBPacket.close, arg0: 42, arg1: 1)])
        let result = try await ADBClient.shell(transport: transport, identity: identity(), command: "pm install -S 9000 -", stdin: bytes, timeout: 1, outputLimit: 100)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, Data("progress".utf8))
        let writes = transport.sent.filter { $0.le32(0) == ADBPacket.write }.map { Data($0.dropFirst(24)) }
        XCTAssertEqual(writes.count, 4)
        XCTAssertTrue(writes.allSatisfy { $0.count <= 4096 })
        XCTAssertEqual(writes.dropLast().map { Int($0.le32(1)) }, [4091, 4091, 818])
        XCTAssertEqual(writes.dropLast().reduce(Data()) { $0 + $1.dropFirst(5) }, bytes)
        XCTAssertEqual(writes.last, shellFrame(4, Data()))
        XCTAssertEqual(transport.sent[3].le32(0), ADBPacket.okay, "output is acknowledged before waiting for the upload ack")
    }

    func testFileHandleTransportStreamsWithoutRetainingStdoutAndEnforcesAggregateLimit() async throws {
        let bytes = Data([0, 255, 10, 128])
        for limit in [bytes.count, bytes.count - 1] {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            FileManager.default.createFile(atPath: file.path, contents: nil)
            defer { try? FileManager.default.removeItem(at: file) }
            let output = try FileHandle(forWritingTo: file)
            defer { try? output.close() }
            let ack = ADBPacket(command: ADBPacket.okay, arg0: 42, arg1: 1)
            let transport = ScriptedADB(packets: [connected(), ack, ack,
                ADBPacket(command: ADBPacket.write, arg0: 42, arg1: 1, payload: shellFrame(1, Data(bytes.prefix(2)))),
                ADBPacket(command: ADBPacket.write, arg0: 42, arg1: 1, payload: shellFrame(1, Data(bytes.suffix(2))) + shellFrame(3, Data([0]))),
                ADBPacket(command: ADBPacket.close, arg0: 42, arg1: 1)])
            do {
                let result = try await ADBClient.shell(transport: transport, identity: identity(), command: "cat /file", timeout: 1, outputLimit: limit, outputFile: output)
                XCTAssertEqual(limit, bytes.count)
                XCTAssertTrue(result.stdout.isEmpty)
                XCTAssertEqual(try Data(contentsOf: file), bytes)
            } catch { XCTAssertEqual(limit, bytes.count - 1) }
        }
    }

    func testEarlyInstallExitStopsUploadAndRejectsPrematureSuccess() async throws {
        for code: UInt8 in [0, 1] {
            let ack = ADBPacket(command: ADBPacket.okay, arg0: 42, arg1: 1)
            let transport = ScriptedADB(packets: [connected(), ack,
                ADBPacket(command: ADBPacket.write, arg0: 42, arg1: 1, payload: shellFrame(3, Data([code]))),
                ack, ADBPacket(command: ADBPacket.close, arg0: 42, arg1: 1)])
            do {
                let result = try await ADBClient.shell(transport: transport, identity: identity(), command: "pm install -S 9000 -",
                                                      stdin: Data(repeating: 1, count: 9000), timeout: 1, outputLimit: 100)
                XCTAssertEqual(code, 1, "success with incomplete input must throw")
                XCTAssertEqual(result.exitCode, 1)
            } catch { XCTAssertEqual(code, 0) }
            XCTAssertEqual(transport.sent.filter { $0.le32(0) == ADBPacket.write }.count, 1)
            XCTAssertTrue(transport.closed)
        }
    }
    func testRealTCPTimeoutAndCancellationSettle() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let connections = Connections()
        listener.newConnectionHandler = { connection in connections.add(connection); connection.start(queue: .global()) }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                if case .ready = state { continuation.resume(returning: listener.port!.rawValue) }
            }
            listener.start(queue: .global())
        }
        defer { listener.cancel(); connections.close() }
        let identity = try identity()
        let start = Date()
        do { _ = try await ADBClient.shell(transport: ADBTCPTransport(host: "127.0.0.1", port: port), identity: identity,
                                         command: "id", timeout: 0.1, outputLimit: 100); XCTFail("timeout missing") } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        let task = Task { try await ADBClient.shell(transport: ADBTCPTransport(host: "127.0.0.1", port: port), identity: identity,
                                                   command: "id", timeout: 30, outputLimit: 100) }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("cancellation missing") } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
}

func connected() -> ADBPacket {
    ADBPacket(command: ADBPacket.connect, arg0: 0x01000000, arg1: 4096,
              payload: Data("device::ro.product.name=test;features=shell_v2,cmd;\0".utf8))
}
func shellFrame(_ kind: UInt8, _ payload: Data) -> Data {
    var data = Data([kind]); data.appendLE(UInt32(payload.count)); data.append(payload); return data
}
final class ScriptedADB: ADBTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data
    private var writes: [Data] = []
    private var isClosed = false
    var sent: [Data] { lock.withLock { writes } }
    var closed: Bool { lock.withLock { isClosed } }
    init(bytes: Data) { self.bytes = bytes }
    convenience init(packets: [ADBPacket]) { self.init(bytes: packets.reduce(Data()) { $0 + $1.encoded }) }
    func start() async throws {}
    func read(count: Int) async throws -> Data {
        try lock.withLock {
            guard bytes.count >= count else { throw ADBFailure("fixture EOF", kind: .unreachable) }
            let value = Data(bytes.prefix(count)); bytes = Data(bytes.dropFirst(count)); return value
        }
    }
    func write(_ data: Data) async throws { lock.withLock { writes.append(data) } }
    func close() { lock.withLock { isClosed = true } }
}
private final class Connections: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [NWConnection] = []
    func add(_ connection: NWConnection) { lock.withLock { values.append(connection) } }
    func close() { lock.withLock { values.forEach { $0.cancel() } } }
}
