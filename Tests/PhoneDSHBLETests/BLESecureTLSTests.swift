// SPDX-License-Identifier: MIT
// Loopback TLS 1.3 handshakes of the phone's real client against a profile
// test server (positive and every §6.1/§6.2 negative the phone must refuse),
// an independent OpenSSL peer, and phone readiness over the TLS session.
import CryptoKit
import Darwin
import Foundation
import Network
import XCTest
@testable import PhoneDSHBLE
import PhoneDSHDeviceTasks

final class BLESecureTLSTests: XCTestCase {
    let phoneSigner = BLESecureSoftwareSigner()
    let deviceSigner = BLESecureSoftwareSigner()
    var phoneFP: String { try! BLESecureIdentifiers.fingerprint(publicKey: phoneSigner.publicKey) }
    var deviceFP: String { try! BLESecureIdentifiers.fingerprint(publicKey: deviceSigner.publicKey) }

    func client(_ stream: BLESecureByteStream, selected: String? = nil) throws -> BLESecureTLSClient {
        BLESecureTLSClient(stream: stream, credentials: .init(certificate: try BLESecureCertificate.make(role: .phone, signer: phoneSigner),
                                                              signer: phoneSigner), selectedDevice: selected ?? deviceFP)
    }

    /// Runs one handshake; returns the client's result and the server outcome.
    func handshake(_ faults: BLESecureTestServer.Faults, selected: String? = nil)
        async throws -> (Result<String, Error>, BLESecureTestServer.Outcome, BLESecureTestServer, BLESecureTLSClient, BLESecureMemoryPipe) {
        let pipe = BLESecureMemoryPipe()
        let server = try BLESecureTestServer(stream: pipe.server, signer: deviceSigner, phonePins: [phoneFP], faults: faults)
        let tls = try client(pipe.client, selected: selected)
        async let serverOutcome = server.run()
        let clientResult: Result<String, Error>
        do { clientResult = .success(try await tls.handshake()) } catch { clientResult = .failure(error) }
        return (clientResult, await serverOutcome, server, tls, pipe)
    }

    func testLoopbackHandshakeProfileAndApplicationData() async throws {
        var faults = BLESecureTestServer.Faults()
        faults.compatibilityCCS = true
        faults.sendTicket = true
        let (result, outcome, server, tls, pipe) = try await handshake(faults)
        XCTAssertEqual(try result.get(), deviceFP)
        XCTAssertEqual(outcome, .established)
        XCTAssertTrue(server.clientHelloOK, "ClientHello is exactly the §6.1 profile")
        XCTAssertEqual(Set(server.clientHelloExtensions), [43, 10, 13, 50, 51, 16])
        for forbidden: UInt16 in [0, 1, 28, 41, 42, 45, 49] { XCTAssertFalse(server.clientHelloExtensions.contains(forbidden)) }

        // matrix tls-server-sends-ticket: the ticket is discarded; data flows both ways.
        try server.send(Array("hello phone".utf8))
        let first = try await tls.receive()
        XCTAssertEqual(first, Array("hello phone".utf8))
        // matrix tls-record-sender-cap: a 4098-byte frame and a larger write.
        try await tls.send(try BLESecureFrameEncoder.frame([UInt8](repeating: 0x42, count: 4096)))
        var frame: [UInt8] = []
        while frame.count < 4098 { frame += try await server.receive() ?? [] }
        XCTAssertEqual(frame.count, 4098)
        let big = [UInt8](repeating: 0x41, count: 10_000)
        try await tls.send(big)
        var received: [UInt8] = []
        while received.count < big.count { received += try await server.receive() ?? [] }
        XCTAssertEqual(received, big)
        // §6.1: every record the phone wrote carries ≤ 4352 plaintext bytes.
        XCTAssertTrue(pipe.client.written.allSatisfy { $0.count <= 5 + 4352 + 1 + 16 }, "record size cap")
        server.closeNotify()
        let end = try await tls.receive()
        XCTAssertNil(end)
    }

    func testClientRefusesEveryProfileDeviation() async throws {
        typealias F = BLESecureTestServer.Faults
        func f(_ edit: (inout F) -> Void) -> F { var x = F(); edit(&x); return x }
        let cases: [(String, F, UInt8)] = [
            ("TLS 1.2 server", f { $0.omitSupportedVersions = true }, 70),
            ("cipher 0x1302", f { $0.cipher = 0x1302 }, 47),
            ("cipher 0x1303", f { $0.cipher = 0x1303 }, 47),
            ("group x25519", f { $0.group = 0x001d }, 47),
            ("HelloRetryRequest", f { $0.helloRetry = true }, 47),
            ("pre_shared_key in ServerHello", f { $0.serverHelloExtra = [(41, [0, 0])] }, 110),
            ("no ALPN", f { $0.alpn = nil }, 120),
            ("other ALPN", f { $0.alpn = Array("pdsh-ble-task/2".utf8) }, 120),
            ("early_data in EncryptedExtensions", f { $0.encryptedExtensionsExtra = [(42, [])] }, 110),
            ("server_name ack", f { $0.encryptedExtensionsExtra = [(0, [])] }, 110),
            ("record_size_limit", f { $0.encryptedExtensionsExtra = [(28, [0x40, 0x01])] }, 110),
            ("no CertificateRequest", f { $0.sendCertificateRequest = false }, 10),
            ("certificate_authorities", f { $0.certificateRequestExtra = [(47, [0, 0])] }, 47),
            ("bad CertificateVerify", f { $0.corruptCertificateVerify = true }, 51),
            ("bad Finished", f { $0.corruptFinished = true }, 51),
        ]
        for (name, faults, alert) in cases {
            let (result, outcome, _, _, _) = try await handshake(faults)
            guard case .failure(let error) = result else { XCTFail("\(name): accepted"); continue }
            XCTAssertEqual(error as? BLESecureTLSError, .sentAlert(alert, (error as? BLESecureTLSError).map { e -> String in
                if case .sentAlert(_, let d) = e { return d }; return "" } ?? ""), name)
            XCTAssertEqual(outcome, .clientAlert(alert), name)
        }
    }

    func testClientRejectsEveryCertificateReasonWithBadCertificate() async throws {
        // Wrong key: a live peer with another key than the pinned device.
        let other = BLESecureSoftwareSigner()
        var faults = BLESecureTestServer.Faults()
        faults.chain = [try BLESecureCertificate.make(role: .device, signer: other)]
        var (result, outcome, _, _, _) = try await handshake(faults)
        XCTAssertEqual(result.failure as? BLESecureTLSError, .certificate(.pinMismatch))
        XCTAssertEqual(outcome, .clientAlert(42))

        // Shared fixture certificates (CA, EKU, unknown critical extension, ...).
        for row in try BLESecureGolden.rows("ble-secure-certificates.jsonl") where row["accept"]?.boolValue == false {
            var f = BLESecureTestServer.Faults()
            f.chain = row["chain_hex"]!.array.map { BLESecureGolden.bytes(hex: $0.s) }
            (result, outcome, _, _, _) = try await handshake(f, selected: row["pin"]!.s)
            let reason = row["reason"]!.s
            if reason == "no_certificate" || reason == "chain_length" || reason == "oversize" || reason == "malformed"
                || reason == "curve" || reason == "pin_mismatch" || reason == "signature_algorithm" || reason == "bad_self_signature"
                || reason == "ca_true" || reason == "eku_present" || reason == "key_usage" || reason == "unknown_critical_extension" {
                XCTAssertEqual(result.failure as? BLESecureTLSError, .certificate(.init(rawValue: reason)!), row.name)
                XCTAssertEqual(outcome, .clientAlert(42), row.name)
            }
        }
    }

    func testServerRecordOverCapIsRecordOverflow() async throws {
        let (result, _, _, tls, pipe) = try await handshake(.init())
        XCTAssertNoThrow(try result.get())
        try pipe.server.write([23, 3, 3, 0x13, 0x88] + [UInt8](repeating: 0, count: 5000))
        do { _ = try await tls.receive(); XCTFail("accepted oversize record") } catch {
            guard case .sentAlert(22, _)? = error as? BLESecureTLSError else { return XCTFail("\(error)") }
        }
    }

    func testRecordLimitIsDecidedFromTheHeader() async throws {
        // v2.1 §6.1: a protected record over 4352 + 1 + 16 = 4369 bytes is
        // record_overflow before decryption; an invalid record within the
        // limit fails the session with another alert (here bad_record_mac).
        var (result, _, _, tls, pipe) = try await handshake(.init())
        XCTAssertNoThrow(try result.get())
        try pipe.server.write([23, 3, 3, 0x11, 0x12] + [UInt8](repeating: 0, count: 4370))
        do { _ = try await tls.receive(); XCTFail("accepted a 4370-byte protected record") } catch {
            guard case .sentAlert(22, _)? = error as? BLESecureTLSError else { return XCTFail("\(error)") }
        }
        (result, _, _, tls, pipe) = try await handshake(.init())
        XCTAssertNoThrow(try result.get())
        try pipe.server.write([23, 3, 3, 0x11, 0x11] + [UInt8](repeating: 0, count: 4369))
        do { _ = try await tls.receive(); XCTFail("accepted a forged record") } catch {
            guard case .sentAlert(20, _)? = error as? BLESecureTLSError else { return XCTFail("within the limit is not record_overflow: \(error)") }
        }
        (result, _, _, tls, pipe) = try await handshake(.init())
        XCTAssertNoThrow(try result.get())
        try pipe.server.write([22, 3, 3, 0x11, 0x01] + [UInt8](repeating: 0, count: 4353))
        do { _ = try await tls.receive(); XCTFail("accepted an unprotected record over 4352") } catch {
            guard case .sentAlert(22, _)? = error as? BLESecureTLSError else { return XCTFail("\(error)") }
        }
    }

    func testPhoneCertificateIsAcceptedByServerVerifier() async throws {
        // The server side of the loopback pins the phone with the same §6.2
        // verifier: a phone key it does not know is refused.
        let pipe = BLESecureMemoryPipe()
        let server = try BLESecureTestServer(stream: pipe.server, signer: deviceSigner,
                                             phonePins: [String(repeating: "1", count: 64)])
        let tls = try client(pipe.client)
        async let outcome = server.run()
        _ = try? await tls.handshake()
        let serverOutcome = await outcome
        XCTAssertEqual(serverOutcome, .serverRejectedClient("bad_certificate"))
    }

    func testKeyUpdateReceivedFailsSession() async throws {
        // matrix tls-key-update-received (scripted peer; see the OpenSSL variant below).
        var faults = BLESecureTestServer.Faults()
        faults.keyUpdate = true
        let (result, outcome, _, tls, _) = try await handshake(faults)
        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(outcome, .established)
        do { _ = try await tls.receive(); XCTFail("KeyUpdate accepted") } catch {
            guard case .sentAlert(10, _)? = error as? BLESecureTLSError else { return XCTFail("\(error)") }
        }
    }

    func testOtherCertificateVerifySchemeFailsHandshake() async throws {
        var faults = BLESecureTestServer.Faults()
        faults.certificateVerifyScheme = 0x0503
        let (result, outcome, _, _, _) = try await handshake(faults)
        guard case .sentAlert(47, _)? = result.failure as? BLESecureTLSError else { return XCTFail("\(result)") }
        XCTAssertEqual(outcome, .clientAlert(47))
    }

    // MARK: generation and sessions over TLS (§8.2) against a scripted device

    struct DeviceScript: Sendable {
        var ackEID: String?
        var ackCC: String?
        var silent = false
        var nextReply: BLESecureServerMessage?
    }

    func runDevice(_ server: BLESecureTestServer, script: DeviceScript) async {
        guard await server.run() == .established else { return }
        var frames = BLESecureFrameDecoder()
        let sc = String(repeating: "5c", count: 32)
        while let chunk = try? await server.receive() {
            for payload in frames.push(chunk).payloads {
                guard let message = try? BLESecureMessageCodec.decodeClient(payload), !script.silent else { continue }
                let reply: BLESecureServerMessage
                switch message {
                case .readyReq(_, let device, let phone, let eid, let cc):
                    reply = .readyAck(device: device, phone: phone, eid: script.ackEID ?? eid, cc: script.ackCC ?? cc, sc: sc)
                case .next(let seq, let got):
                    reply = script.nextReply ?? (got == sc ? .nextR(re: seq, task: nil, phase: nil) : .err(re: seq, code: .badChallenge))
                case .status(let seq, _, _, _): reply = .statusR(re: seq, phase: .unknown, mine: false, outcome: nil)
                case .accept(let seq, _, _, _): reply = .err(re: seq, code: .wrongOwner)
                default: continue
                }
                try? server.send(try BLESecureFrameEncoder.frame(BLESecureMessageCodec.encode(reply)))
            }
        }
    }

    func generation(timers: BLESecurePhoneGeneration.Timers = .init(), selected: String? = nil) throws -> BLESecurePhoneGeneration {
        let key = try BLESecurePhoneKey(signer: phoneSigner, isHardwareBacked: false)
        let record = BLESecureEnrollmentRecord(state: .committed, device: selected ?? deviceFP, phone: key.fingerprint,
                                               eid: "6f1c0a8e2b9d4c3fa1e0b7d6c5f4e3d2", rev: 2)
        return try BLESecurePhoneGeneration(key: key, selected: record, timers: timers,
                                            isCurrent: { true }, recordStillCurrent: { true })
    }

    func session(_ generation: BLESecurePhoneGeneration, _ script: DeviceScript, faults: BLESecureTestServer.Faults = .init(),
                 signer: BLESecureSigner? = nil) async throws -> Error? {
        let pipe = BLESecureMemoryPipe()
        let server = try BLESecureTestServer(stream: pipe.server, signer: signer ?? deviceSigner, phonePins: [phoneFP], faults: faults)
        Task { await runDevice(server, script: script) }
        do { try await generation.openSession(over: pipe.client); return nil } catch { return error }
    }

    func testGenerationReadinessGrantRequestsAndRenewal() async throws {
        let generation = try generation()
        let error = try await session(generation, DeviceScript())
        XCTAssertNil(error)
        let ready = await generation.state
        XCTAssertEqual(ready, .ready)
        // Ready is not permission.
        let refused = try await generation.request(.next)
        XCTAssertEqual(refused.result, .refusedNoGrant)
        let v1 = await generation.grantByUser().result
        XCTAssertEqual(v1, .granted)
        let none = try await generation.request(.next)
        XCTAssertEqual(none.result, .noTask)
        let status = try await generation.request(.status(id: "task-1", idem: "goal-1", intent: nil))
        XCTAssertEqual(status.result, .status)
        // A request-level error on a first send is unresolved; the session continues.
        let accept = try await generation.request(.transition(.accept(id: "task-1", idem: "goal-1"), resend: false))
        XCTAssertEqual(accept.result, .unresolved)
        let v2 = await generation.state
        XCTAssertEqual(v2, .ready)
        // Session renewal under the same grant.
        await generation.end(.background)
        let v3 = await generation.grant
        XCTAssertEqual(v3, .none, "background ends the grant")
    }

    func testGenerationSessionRenewalKeepsGrant() async throws {
        var timers = BLESecurePhoneGeneration.Timers()
        timers.lifetime = .milliseconds(400)
        let generation = try generation(timers: timers)
        _ = try await session(generation, DeviceScript())
        let v4 = await generation.grantByUser().result
        XCTAssertEqual(v4, .granted)
        try await Task.sleep(for: .milliseconds(700))
        let v5 = await generation.state
        XCTAssertEqual(v5, .closed, "lifetime closes the session")
        let v6 = await generation.grant
        XCTAssertEqual(v6, .active, "the grant survives session close")
        let error = try await session(generation, DeviceScript())
        XCTAssertNil(error)
        let next = try await generation.request(.next)
        XCTAssertEqual(next.result, .noTask, "no new grant needed")
    }

    func testGenerationRejectsReadinessFailuresAndCountsAttempts() async throws {
        let generation = try generation()
        let cases: [(DeviceScript, BLESecurePhoneSessionCore.Result)] = [
            (DeviceScript(ackEID: "0123456789abcdef0123456789abcdef"), .recordMismatch),
            (DeviceScript(ackCC: String(repeating: "c2", count: 32)), .badChallenge),
        ]
        for (script, expected) in cases {
            let error = try await session(generation, script)
            XCTAssertEqual(error as? BLESecurePhoneGeneration.Failure, .core(expected))
            let v7 = await generation.state
            XCTAssertEqual(v7, .closed)
        }
        let v8 = await generation.failedAttempts
        XCTAssertEqual(v8, 2)
        // Another enrolled board answering: pin_mismatch inside the handshake.
        let other = BLESecureSoftwareSigner()
        let error = try await session(generation, DeviceScript(), signer: other)
        XCTAssertEqual(error as? BLESecurePhoneGeneration.Failure, .tls(.certificate(.pinMismatch)))
        let v9 = await generation.failedAttempts
        XCTAssertEqual(v9, 3)
    }

    func testGenerationReadyWaitTimeout() async throws {
        var timers = BLESecurePhoneGeneration.Timers()
        timers.responseWait = .milliseconds(200)
        let generation = try generation(timers: timers)
        let error = try await session(generation, DeviceScript(silent: true))
        XCTAssertEqual(error as? BLESecurePhoneGeneration.Failure, .core(.responseTimeout))
        let v10 = await generation.state
        XCTAssertEqual(v10, .closed)
    }

    func testHalfRTTDataBeforeReadyFailsSession() async throws {
        // matrix tls-half-rtt-data-before-ready (scripted peer).
        var faults = BLESecureTestServer.Faults()
        faults.halfRTTData = try BLESecureFrameEncoder.frame(BLESecureMessageCodec.encode(BLESecureServerMessage.nextR(re: 1, task: nil, phase: nil)))
        let generation = try generation()
        let error = try await session(generation, DeviceScript(silent: true), faults: faults)
        XCTAssertEqual(error as? BLESecurePhoneGeneration.Failure, .core(.malformed))
        let v11 = await generation.state
        XCTAssertEqual(v11, .closed)
    }

    func testGenerationRefusesUncommittedSelection() async throws {
        let key = try BLESecurePhoneKey(signer: phoneSigner, isHardwareBacked: false)
        let staged = BLESecureEnrollmentRecord(state: .staged, device: deviceFP, phone: key.fingerprint, eid: String(repeating: "a", count: 32), rev: 1)
        let generation = try BLESecurePhoneGeneration(key: key, selected: staged, isCurrent: { true }, recordStillCurrent: { true })
        let pipe = BLESecureMemoryPipe()
        Task { _ = try? await BLESecureTestServer(stream: pipe.server, signer: deviceSigner, phonePins: [phoneFP]).run() }
        do { try await generation.openSession(over: pipe.client); XCTFail("staged record opened a session") } catch {}
        XCTAssertTrue(pipe.client.written.filter { $0.first == 23 }.isEmpty, "no application data without a committed record")
    }

    // MARK: independent peer (OpenSSL s_server) — conformance-matrix phone rows

    struct OpenSSLPeer {
        let process: Process
        let input: FileHandle
        let output: FileHandle
        let client: BLESecureTLSClient
        let result: Result<String, Error>
    }

    func openSSL(_ extra: [String], selected: String? = nil) async throws -> OpenSSLPeer {
        guard let openssl = ["/opt/homebrew/bin/openssl", "/usr/local/bin/openssl"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw XCTSkip("OpenSSL 3+ CLI unavailable") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ss-sserver-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let deviceKey = P256.Signing.PrivateKey()
        let deviceFingerprint = try BLESecureIdentifiers.fingerprint(publicKey: Array(deviceKey.publicKey.x963Representation))
        let phoneDER = try BLESecureCertificate.make(role: .phone, signer: phoneSigner)
        try Data(try BLESecureCertificate.make(role: .device, signer: BLESecureSoftwareSigner(deviceKey))).write(to: dir.appendingPathComponent("device.der"))
        try Data(phoneDER).write(to: dir.appendingPathComponent("phone.der"))
        try Data(deviceKey.pemRepresentation.utf8).write(to: dir.appendingPathComponent("device.key"))
        for name in ["device", "phone"] {
            let convert = Process()
            convert.executableURL = URL(fileURLWithPath: openssl)
            convert.arguments = ["x509", "-inform", "DER", "-in", dir.appendingPathComponent(name + ".der").path,
                                 "-out", dir.appendingPathComponent(name + ".pem").path]
            try convert.run(); convert.waitUntilExit()
            XCTAssertEqual(convert.terminationStatus, 0)
        }
        let port = Self.freePort()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: openssl)
        process.arguments = ["s_server", "-accept", "127.0.0.1:\(port)", "-naccept", "1",
                             "-cert", dir.appendingPathComponent("device.pem").path,
                             "-key", dir.appendingPathComponent("device.key").path,
                             "-Verify", "1", "-verify_return_error", "-partial_chain",
                             "-verifyCAfile", dir.appendingPathComponent("phone.pem").path, "-no-CAfile"] + extra
            + (extra.contains("-sigalgs") ? [] : ["-sigalgs", "ecdsa_secp256r1_sha256"])
            + ["-client_sigalgs", "ecdsa_secp256r1_sha256"]
        let input = Pipe()
        process.standardInput = input
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        addTeardownBlock { if process.isRunning { process.terminate() } }
        var stream: TCPByteStream?
        for _ in 0..<100 {
            if let s = try? await TCPByteStream.connect(port: port) { stream = s; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let stream else { throw XCTSkip("s_server did not accept") }
        let client = BLESecureTLSClient(stream: stream, credentials: .init(certificate: phoneDER, signer: phoneSigner),
                                        selectedDevice: selected ?? deviceFingerprint)
        let result: Result<String, Error>
        do { result = .success(try await client.handshake()) } catch { result = .failure(error) }
        return OpenSSLPeer(process: process, input: input.fileHandleForWriting, output: output.fileHandleForReading, client: client, result: result)
    }

    static func freePort() -> UInt16 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = Darwin.bind(fd, $0, len) } }
        withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &len) } }
        return UInt16(bigEndian: addr.sin_port)
    }

    func testMatrixHandshakeRowsAgainstOpenSSL() async throws {
        // tls-version-1-2-only, tls-cipher-suite-other, tls-signature-scheme-other,
        // tls-server-group-other, tls-alpn-not-selected: every one fails the handshake.
        let alpn = ["-alpn", "pdsh-ble-task/1"]
        let rows: [(String, [String], UInt8?)] = [
            ("tls-version-1-2-only", ["-tls1_2"] + alpn, nil),
            ("tls-cipher-suite-other", ["-tls1_3", "-ciphersuites", "TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256"] + alpn, nil),
            ("tls-signature-scheme-other", ["-tls1_3", "-sigalgs", "ecdsa_secp384r1_sha384:rsa_pss_rsae_sha256"] + alpn, nil),
            ("tls-server-group-other", ["-tls1_3", "-groups", "X25519"] + alpn, nil),
            ("tls-alpn-not-selected", ["-tls1_3"], 120),
        ]
        for (name, args, alert) in rows {
            let peer = try await openSSL(args)
            guard case .failure(let error) = peer.result else { XCTFail("\(name): handshake completed"); continue }
            if let alert { guard case .sentAlert(alert, _)? = error as? BLESecureTLSError else { XCTFail("\(name): \(error)"); continue } }
            print("matrix \(name): handshake_failed (\(error))")
        }
        // tls-negative-decision-aborts-handshake: pin mismatch decided inside the handshake.
        let peer = try await openSSL(["-tls1_3"] + alpn, selected: String(repeating: "a", count: 64))
        XCTAssertEqual(peer.result.failure as? BLESecureTLSError, .certificate(.pinMismatch))
    }

    func testInteropApplicationDataAndTicketWithOpenSSL() async throws {
        // Positive interop with an independent TLS 1.3 stack configured to the
        // §6.1 profile; tls-server-sends-ticket: OpenSSL sends two tickets,
        // the phone discards them.
        let peer = try await openSSL(["-alpn", "pdsh-ble-task/1", "-tls1_3", "-ciphersuites", "TLS_AES_128_GCM_SHA256",
                                      "-groups", "P-256", "-num_tickets", "2"])
        XCTAssertNoThrow(try peer.result.get())
        let payload = Array(#"{"v":1,"t":"next","seq":2,"sc":"\#(String(repeating: "5c", count: 32))"}"#.utf8)
        try await peer.client.send(try BLESecureFrameEncoder.frame(payload))
        peer.input.write(Data("pong\n".utf8))
        let echoed = try await peer.client.receive()
        XCTAssertEqual(echoed, Array("pong\n".utf8))
        var seen = Data()
        let deadline = Date().addingTimeInterval(10)
        while !String(decoding: seen, as: UTF8.self).contains("\"t\":\"next\""), Date() < deadline {
            seen.append(peer.output.availableData)
        }
        XCTAssertTrue(String(decoding: seen, as: UTF8.self).contains(String(decoding: payload, as: UTF8.self)), "s_server received the frame")
        await peer.client.close()
    }

    func testMatrixPostHandshakeRowsAgainstOpenSSL() async throws {
        let alpn = ["-alpn", "pdsh-ble-task/1", "-tls1_3"]
        // tls-key-update-received: s_server's "k" command sends KeyUpdate.
        var peer = try await openSSL(alpn)
        XCTAssertNoThrow(try peer.result.get())
        peer.input.write(Data("k\n".utf8))
        do { _ = try await peer.client.receive(); XCTFail("KeyUpdate accepted") } catch {
            guard case .sentAlert(10, _)? = error as? BLESecureTLSError else { return XCTFail("key update: \(error)") }
        }
        // tls-record-overflow: a record whose plaintext exceeds 4352 bytes.
        peer = try await openSSL(alpn)
        XCTAssertNoThrow(try peer.result.get())
        peer.input.write(Data((String(repeating: "A", count: 6000) + "\n").utf8))
        do {
            var total = 0
            while let chunk = try await peer.client.receive() { total += chunk.count }
            XCTFail("oversize record accepted (\(total) bytes)")
        } catch {
            guard case .sentAlert(22, _)? = error as? BLESecureTLSError else { return XCTFail("overflow: \(error)") }
        }
    }

}

extension Result {
    var failure: Failure? { if case .failure(let e) = self { return e }; return nil }
}

/// A BLESecureByteStream over a localhost TCP connection (interop tests only).
final class TCPByteStream: BLESecureByteStream, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "ss-tcp")
    private var closed = false

    private init(_ connection: NWConnection) { self.connection = connection }

    static func connect(port: UInt16) async throws -> TCPByteStream {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let stream = TCPByteStream(connection)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            connection.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready: resumed = true; continuation.resume()
                case .failed(let e), .waiting(let e): resumed = true; continuation.resume(throwing: e)
                default: break
                }
            }
            connection.start(queue: stream.queue)
        }
        return stream
    }

    func write(_ bytes: [UInt8]) throws {
        guard !closed else { throw BLEFailure("closed") }
        connection.send(content: Data(bytes), completion: .contentProcessed { _ in })
    }

    func read() async throws -> [UInt8]? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                if let data, !data.isEmpty { continuation.resume(returning: Array(data)) }
                else if complete || error != nil { continuation.resume(returning: nil) }
                else { continuation.resume(returning: []) }
            }
        }
    }

    func close() { closed = true; connection.cancel() }
}
