// SPDX-License-Identifier: MIT
import XCTest
@testable import PhoneDSHBLE

final class TonoLinkUSBOTAProtocolTests: XCTestCase {
    /// First 0xd0 bytes of a real `agent_s3.bin` (galic build, 2026-10-28).
    static let realHeader = """
    e9060240385a3740ee0000000900000000630000000000012000163c40c705003254cdab00000000000000000000000031000000
    000000000000000000000000000000000000000000000000000000006167656e745f733300000000000000000000000000000000
    000000000000000032303a30303a303600000000000000004f63742032382032303236000000000076362e310000000000000000
    00000000000000000000000000000000000000003e56aabe1faeec8060dc3c667818b584e0839de5686c296a4a58f72d089fb546
    """

    static func hexData(_ text: String) -> Data {
        let digits = Array(text.filter { $0.isHexDigit })
        return Data(stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0...$0 + 1]), radix: 16)! })
    }

    func testCRC32MatchesZlib() {
        XCTAssertEqual(TonoLinkCRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(TonoLinkCRC32.checksum(Data()), 0)
        XCTAssertEqual(TonoLinkCRC32.header(0x0012_abcd), "0012abcd")
    }

    func testParsesRealAppDescription() throws {
        let header = Self.hexData(Self.realHeader)
        XCTAssertEqual(header.count, 0xd0)
        let image = try TonoLinkFirmwareImage(data: header + Data(repeating: 0xff, count: 8192))
        XCTAssertEqual(image.version, "1")
        XCTAssertEqual(image.projectName, "agent_s3")
        XCTAssertEqual(image.buildDate, "Oct 28 2026 20:00:06")
        XCTAssertEqual(image.elfSHA256, "3e56aabe1faeec8060dc3c667818b584e0839de5686c296a4a58f72d089fb546")
    }

    func testRejectsNonImages() {
        var bad = Self.hexData(Self.realHeader) + Data(repeating: 0, count: 8192)
        bad[0] = 0x7f
        XCTAssertThrowsError(try TonoLinkFirmwareImage(data: bad))
        var noDesc = Self.hexData(Self.realHeader) + Data(repeating: 0, count: 8192)
        noDesc[32] = 0
        XCTAssertThrowsError(try TonoLinkFirmwareImage(data: noDesc))
        XCTAssertThrowsError(try TonoLinkFirmwareImage(data: Self.hexData(Self.realHeader)))
    }

    func testAckParsing() {
        XCTAssertEqual(TonoLinkCtrlAck.parse(Data("ack 12 ok".utf8)), TonoLinkCtrlAck(seq: 12, error: nil))
        XCTAssertEqual(TonoLinkCtrlAck.parse(Data("ack 7 err range\n".utf8)), TonoLinkCtrlAck(seq: 7, error: "range"))
        XCTAssertNil(TonoLinkCtrlAck.parse(Data("st bat=90 hid=1 ver=1 up=3 q=0".utf8)))
        XCTAssertNil(TonoLinkCtrlAck.parse(Data("ack - ok".utf8)))
        XCTAssertNil(TonoLinkCtrlAck.parse(Data("ack 70000 ok".utf8)))
        XCTAssertNil(TonoLinkCtrlAck.parse(Data("ack 1 ok extra".utf8)))
    }

    func testUSBNetLineAndTokens() throws {
        let token = TonoLinkTokens.makeUSBToken()
        XCTAssertTrue(TonoLinkTokens.isUSBToken(token))
        XCTAssertEqual(token, token.lowercased())
        XCTAssertNotEqual(token, TonoLinkTokens.makeUSBToken())
        XCTAssertEqual(try TonoLinkCtrlCommand.usbNet(seq: 42, token: token), Data("42 usb_net \(token)".utf8))
        XCTAssertEqual(try TonoLinkCtrlCommand.usbNet(seq: 1, token: "off"), Data("1 usb_net off".utf8))
        XCTAssertThrowsError(try TonoLinkCtrlCommand.usbNet(seq: 1, token: "abc"))
        XCTAssertThrowsError(try TonoLinkCtrlCommand.usbNet(seq: 1, token: String(repeating: "g", count: 32)))
    }

    func testLANTokenNormalization() {
        let hex = String(repeating: "aB3", count: 21) + "f"
        XCTAssertEqual(TonoLinkTokens.normalizedLANToken("  \(hex)\n"), hex)
        XCTAssertEqual(TonoLinkTokens.normalizedLANToken("Bearer \(hex)"), hex)
        XCTAssertNil(TonoLinkTokens.normalizedLANToken(String(hex.dropLast())))
        XCTAssertNil(TonoLinkTokens.normalizedLANToken(String(hex.dropLast()) + "z"))
    }

    func testFrameCodec() throws {
        let token = String(repeating: "0123456789abcdef", count: 2)
        let auth = try TonoLinkUSBFrame.authenticate(token: token)
        XCTAssertEqual(Array(auth.prefix(3)), [0, 33, 0])
        XCTAssertEqual(auth.dropFirst(3), Data(token.utf8))
        XCTAssertThrowsError(try TonoLinkUSBFrame.authenticate(token: "short"))
        XCTAssertThrowsError(try TonoLinkUSBFrame.encode(kind: 1, payload: Data(count: 1025)))

        var decoder = TonoLinkUSBFrame.Decoder()
        let ack = Data([0, 3, 0, 0x6f, 0x6b]), pong = try TonoLinkUSBFrame.encode(kind: 4, payload: Data([1, 2]))
        let stream = ack + pong
        XCTAssertTrue(try decoder.append(stream.prefix(4)).isEmpty)
        let frames = try decoder.append(stream.dropFirst(4))
        XCTAssertEqual(frames.count, 2)
        XCTAssertTrue(TonoLinkUSBFrame.isAuthAck(kind: frames[0].kind, payload: frames[0].payload))
        XCTAssertEqual(frames[1].kind, TonoLinkUSBFrame.pong)
        XCTAssertEqual(frames[1].payload, Data([1, 2]))
        XCTAssertFalse(TonoLinkUSBFrame.isAuthAck(kind: 0, payload: Data("no".utf8)))

        var broken = TonoLinkUSBFrame.Decoder()
        XCTAssertThrowsError(try broken.append(Data([0, 0])))
        var oversized = TonoLinkUSBFrame.Decoder()
        XCTAssertThrowsError(try oversized.append(Data([0x04, 0x02])))
    }

    func testStateDecoding() throws {
        let json = #"{"version":"1","slot":"ota_1","boot":"0000002a","elf_sha256":"ab","state":"pending","transport":"usb","reset_reason":3,"needs_usb_confirmation":true}"#
        let state = try TonoLinkOTAState.decode(Data(json.utf8))
        XCTAssertEqual(state.slot, "ota_1")
        XCTAssertEqual(state.transport, "usb")
        XCTAssertTrue(state.needsUSBConfirmation)
        XCTAssertFalse(state.isConfirmed)
        XCTAssertThrowsError(try TonoLinkOTAState.decode(Data("<html>".utf8)))
    }

    func testWiFiStateAndCredentialLimits() throws {
        let state = try TonoLinkWiFiState.decode(Data(#"{"ok":true,"ssid":"vaca","connected":true,"ip":"192.168.6.40","rssi":-48}"#.utf8))
        XCTAssertEqual(state, TonoLinkWiFiState(ssid: "vaca", connected: true, ip: "192.168.6.40", rssi: -48))
        XCTAssertThrowsError(try TonoLinkWiFiState.decode(Data("{}".utf8)))
        XCTAssertNoThrow(try TonoLinkWiFiCredentials(ssid: String(repeating: "s", count: 32), password: ""))
        XCTAssertNoThrow(try TonoLinkWiFiCredentials(ssid: "a", password: String(repeating: "p", count: 64)))
        XCTAssertThrowsError(try TonoLinkWiFiCredentials(ssid: "", password: "x"))
        XCTAssertThrowsError(try TonoLinkWiFiCredentials(ssid: String(repeating: "s", count: 33), password: ""))
        XCTAssertThrowsError(try TonoLinkWiFiCredentials(ssid: "a", password: String(repeating: "p", count: 65)))
    }

    func testRequests() throws {
        let image = try TonoLinkFirmwareImage(data: makeImage(version: "v2", sha: 0x11))
        let lan = String(repeating: "c", count: 64), usb = String(repeating: "d", count: 32)
        let upload = TonoLinkOTARequest.upload(image: image, lanToken: lan, usbToken: usb)
        XCTAssertEqual(upload.url?.absoluteString, "http://192.168.247.1:8767/ota")
        XCTAssertEqual(upload.httpMethod, "POST")
        XCTAssertEqual(upload.value(forHTTPHeaderField: "Authorization"), "Bearer \(lan)")
        XCTAssertEqual(upload.value(forHTTPHeaderField: "X-CRC32"), TonoLinkCRC32.header(TonoLinkCRC32.checksum(image.data)))
        XCTAssertEqual(upload.value(forHTTPHeaderField: "X-USB-Token"), usb)

        let confirm = TonoLinkOTARequest.confirm(elfSHA256: image.elfSHA256, lanToken: lan, usbToken: usb)
        XCTAssertEqual(confirm.url?.path, "/ota/confirm")
        XCTAssertEqual(confirm.httpMethod, "POST")
        XCTAssertEqual(confirm.value(forHTTPHeaderField: "X-ELF-SHA256"), image.elfSHA256)
        XCTAssertEqual(confirm.value(forHTTPHeaderField: "X-USB-Token"), usb)

        let tokenless = TonoLinkOTARequest.upload(image: image, lanToken: nil, usbToken: usb)
        XCTAssertNil(tokenless.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(tokenless.value(forHTTPHeaderField: "X-USB-Token"), usb)
        XCTAssertNil(TonoLinkOTARequest.confirm(elfSHA256: "ab", lanToken: nil, usbToken: usb).value(forHTTPHeaderField: "Authorization"))

        let wifi = try TonoLinkOTARequest.setWiFi(try TonoLinkWiFiCredentials(ssid: "vaca", password: "pw"), lanToken: nil, usbToken: usb)
        XCTAssertEqual(wifi.url?.path, "/v1/wifi")
        XCTAssertEqual(wifi.httpMethod, "POST")
        XCTAssertEqual(wifi.value(forHTTPHeaderField: "X-USB-Token"), usb)
        XCTAssertNil(wifi.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: wifi.httpBody!), ["ssid": "vaca", "password": "pw"])
        XCTAssertEqual(TonoLinkOTARequest.wifiState().httpMethod, "GET")

        let state = TonoLinkOTARequest.state()
        XCTAssertEqual(state.url?.path, "/ota/state")
        XCTAssertNil(state.value(forHTTPHeaderField: "Authorization"))
    }
}

/// Builds a minimal app image with the given description fields.
func makeImage(version: String, sha: UInt8, size: Int = 8192) -> Data {
    var data = Data(repeating: 0, count: size)
    data[0] = 0xE9
    data.replaceSubrange(32..<36, with: [0x32, 0x54, 0xcd, 0xab])
    data.replaceSubrange(48..<(48 + version.utf8.count), with: Array(version.utf8))
    data.replaceSubrange(80..<88, with: Array("agent_s3".utf8))
    data.replaceSubrange(176..<208, with: [UInt8](repeating: sha, count: 32))
    data[size - 1] = sha
    return data
}

// MARK: - Simulated board

@MainActor final class SimBoard {
    var version = "v1", elf = String(repeating: "aa", count: 32), state = "valid", boot = 1
    var needsUSB = false
    var usbToken: String?          // set by usb_net
    var authenticated: String?     // token of the live :8768 session
    var lanToken = String(repeating: "e", count: 64)
    var log: [String] = []
    var rejectUpload: Int?
    var dropUploadResponse = false
    var flashAccepted = true
    var failSessionAttempts = 0
    /// venus-demo a0a95ef+: the USB session alone authorizes /ota, /ota/confirm, POST /v1/wifi.
    var usbSessionAuth = true
    var wifi = TonoLinkWiFiState(ssid: "vaca", connected: false, ip: "0.0.0.0", rssi: 0)

    func reboot(into image: TonoLinkFirmwareImage?) {
        boot += 1; usbToken = nil; authenticated = nil
        if let image { version = image.version; elf = image.elfSHA256; state = "pending"; needsUSB = true }
    }

    var stateJSON: Data {
        Data(#"{"version":"\#(version)","slot":"ota_\#(boot % 2)","boot":"\#(String(format: "%08x", boot))","elf_sha256":"\#(elf)","state":"\#(state)","transport":"usb","reset_reason":1,"needs_usb_confirmation":\#(needsUSB)}"#.utf8)
    }
}

@MainActor final class SimCtrl: TonoLinkCtrlLink {
    let board: SimBoard
    var connected = false
    init(_ board: SimBoard) { self.board = board }
    func connect(timeout: Duration) async throws { connected = true; board.log.append("ble.connect") }
    func command(_ line: Data, seq: UInt16, timeout: Duration) async throws -> TonoLinkCtrlAck {
        guard connected else { throw TonoLinkUSBOTAError("not connected") }
        let parts = String(decoding: line, as: UTF8.self).split(separator: " ")
        XCTAssertEqual(parts.count, 3); XCTAssertEqual(parts[0], "\(seq)"); XCTAssertEqual(parts[1], "usb_net")
        board.usbToken = String(parts[2]); board.authenticated = nil
        board.log.append("usb_net")
        return TonoLinkCtrlAck(seq: seq, error: nil)
    }
    func disconnect() { if connected { board.log.append("ble.disconnect") }; connected = false }
}

@MainActor final class SimSession: TonoLinkUSBSession {
    let board: SimBoard, token: String
    init(_ board: SimBoard, _ token: String) { self.board = board; self.token = token }
    var isAlive: Bool { board.authenticated == token }
    func close() { if isAlive { board.authenticated = nil } }
}

@MainActor final class SimNetwork: TonoLinkUSBNetwork {
    let board: SimBoard
    init(_ board: SimBoard) { self.board = board }
    func openSession(token: String) async throws -> TonoLinkUSBSession {
        if board.failSessionAttempts > 0 { board.failSessionAttempts -= 1; throw TonoLinkUSBOTAError("no route") }
        guard board.usbToken == token else { throw TonoLinkUSBOTAError("auth rejected") }
        board.authenticated = token
        board.log.append("usb.auth")
        return SimSession(board, token)
    }
}

@MainActor final class SimHTTP: TonoLinkHTTP {
    let board: SimBoard
    var progress: [Double] = []
    init(_ board: SimBoard) { self.board = board }
    func send(_ request: URLRequest, body: Data?, progress: ((Double) -> Void)?) async throws -> (status: Int, body: Data) {
        let path = request.url!.path
        func usbAuthorized() -> Bool {
            request.value(forHTTPHeaderField: "X-USB-Token") == board.authenticated && board.authenticated != nil
        }
        func lanAuthorized() -> Bool {
            let bearer = request.value(forHTTPHeaderField: "Authorization")
            if bearer == "Bearer \(board.lanToken)" { return true }
            return bearer == nil && board.usbSessionAuth && usbAuthorized()
        }
        func wifiJSON() throws -> Data { try JSONEncoder().encode(board.wifi) }
        switch (request.httpMethod ?? "GET", path) {
        case ("GET", "/ota/state"):
            return (200, board.stateJSON)
        case ("POST", "/ota"):
            board.log.append("POST /ota")
            if let code = board.rejectUpload { return (code, Data("nope".utf8)) }
            guard lanAuthorized() else { return (401, Data()) }
            guard usbAuthorized() else { return (403, Data("USB session required".utf8)) }
            let body = try XCTUnwrap(body)
            guard request.value(forHTTPHeaderField: "X-CRC32") == TonoLinkCRC32.header(TonoLinkCRC32.checksum(body)) else { return (400, Data("crc".utf8)) }
            progress?(0.5); progress?(1)
            board.reboot(into: board.flashAccepted ? try TonoLinkFirmwareImage(data: body) : nil)
            if board.dropUploadResponse { throw URLError(.networkConnectionLost) }
            return (200, Data("OTA OK\n".utf8))
        case ("POST", "/ota/confirm"):
            board.log.append("POST /ota/confirm")
            guard lanAuthorized() else { return (401, Data()) }
            guard usbAuthorized() else { return (403, Data("USB session required".utf8)) }
            guard request.value(forHTTPHeaderField: "X-ELF-SHA256") == board.elf else { return (400, Data("running image mismatch".utf8)) }
            // The verify task marks the image valid on its next tick.
            board.needsUSB = false; board.state = "valid"
            return (200, Data("USB confirmation received\n".utf8))
        case ("GET", "/v1/wifi"):
            return (200, try wifiJSON())
        case ("POST", "/v1/wifi"):
            guard lanAuthorized() else { return (401, Data()) }
            let credentials = try JSONDecoder().decode([String: String].self, from: try XCTUnwrap(request.httpBody))
            board.wifi = TonoLinkWiFiState(ssid: credentials["ssid"]!, connected: true, ip: "192.168.6.77", rssi: -51)
            return (200, try wifiJSON())
        default:
            return (404, Data())
        }
    }
}

@MainActor final class SimClock: TonoLinkOTAClock {
    var now = ContinuousClock.now
    func sleep(for duration: Duration) async throws { now += duration }
}

@MainActor final class TonoLinkUSBOTAFlowTests: XCTestCase {
    var board: SimBoard!, http: SimHTTP!, ctrl: SimCtrl!, tokens: [String] = []

    func makeFlow() -> TonoLinkUSBOTA {
        board = SimBoard(); http = SimHTTP(board); ctrl = SimCtrl(board); tokens = []
        return TonoLinkUSBOTA(ctrl: ctrl, network: SimNetwork(board), http: http, clock: SimClock(),
                              makeToken: { [unowned self] in
                                  let token = String(format: "%032x", self.tokens.count + 1); self.tokens.append(token); return token
                              }, firstSeq: 10)
    }

    func testUploadsRebootsAndConfirmsWithAFreshUSBSession() async throws {
        let flow = makeFlow()
        var events: [TonoLinkOTAEvent] = []
        flow.onEvent = { events.append($0) }
        let image = try TonoLinkFirmwareImage(data: makeImage(version: "v2", sha: 0x22))
        let outcome = try await flow.run(image: image, lanToken: board.lanToken)

        guard case .confirmed(let state) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(state.version, "v2")
        XCTAssertEqual(state.elfSHA256, image.elfSHA256)
        XCTAssertTrue(state.isConfirmed)
        XCTAssertEqual(tokens.count, 2, "the post-reboot session must use a new token")
        XCTAssertEqual(board.log, ["ble.connect", "usb_net", "usb.auth", "POST /ota", "ble.disconnect",
                                   "ble.connect", "usb_net", "usb.auth", "POST /ota/confirm", "ble.disconnect"])
        XCTAssertNil(board.authenticated, "the session is closed at the end")
        XCTAssertTrue(events.contains(.uploadProgress(1)))
    }

    func testRetriesUntilTheNCMRouteIsUp() async throws {
        let flow = makeFlow()
        board.failSessionAttempts = 3
        let image = try TonoLinkFirmwareImage(data: makeImage(version: "v2", sha: 0x22))
        guard case .confirmed = try await flow.run(image: image, lanToken: board.lanToken) else { return XCTFail() }
    }

    func testAlreadyRunningImageIsNotUploadedAgain() async throws {
        let flow = makeFlow()
        let image = try TonoLinkFirmwareImage(data: makeImage(version: "v1", sha: 0xaa))
        XCTAssertEqual(image.elfSHA256, board.elf)
        guard case .alreadyRunning = try await flow.run(image: image, lanToken: board.lanToken) else { return XCTFail() }
        XCTAssertFalse(board.log.contains("POST /ota"))
    }

    func testPendingImageFromAnEarlierAttemptIsConfirmedWithoutUpload() async throws {
        let flow = makeFlow()
        let image = try TonoLinkFirmwareImage(data: makeImage(version: "v2", sha: 0x22))
        board.reboot(into: image)
        guard case .confirmed(let state) = try await flow.run(image: image, lanToken: board.lanToken) else { return XCTFail() }
        XCTAssertTrue(state.isConfirmed)
        XCTAssertFalse(board.log.contains("POST /ota"))
    }

    func testLostUploadResponseStillVerifiesTheRunningImage() async throws {
        let flow = makeFlow()
        board.dropUploadResponse = true
        let image = try TonoLinkFirmwareImage(data: makeImage(version: "v2", sha: 0x22))
        guard case .confirmed = try await flow.run(image: image, lanToken: board.lanToken) else { return XCTFail() }
    }

    func testOldImageAfterRebootIsAnError() async throws {
        let flow = makeFlow()
        board.flashAccepted = false
        let image = try TonoLinkFirmwareImage(data: makeImage(version: "v2", sha: 0x22))
        do { _ = try await flow.run(image: image, lanToken: board.lanToken); XCTFail("expected failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("not the uploaded image"), error.localizedDescription) }
        XCTAssertFalse(board.log.contains("POST /ota/confirm"))
    }

    func testRejectedUploadSurfacesTheBoardError() async throws {
        let flow = makeFlow()
        board.rejectUpload = 500
        let image = try TonoLinkFirmwareImage(data: makeImage(version: "v2", sha: 0x22))
        do { _ = try await flow.run(image: image, lanToken: board.lanToken); XCTFail("expected failure") }
        catch { XCTAssertEqual(error.localizedDescription, "POST /ota → 500: nope") }
    }

    func testCurrentFirmwareNeedsNoLANToken() async throws {
        let flow = makeFlow()
        let image = try TonoLinkFirmwareImage(data: makeImage(version: "v2", sha: 0x22))
        guard case .confirmed(let state) = try await flow.run(image: image) else { return XCTFail() }
        XCTAssertEqual(state.version, "v2")
    }

    func testOldFirmwareWithoutLANTokenExplainsWhy() async throws {
        let flow = makeFlow()
        board.usbSessionAuth = false
        let image = try TonoLinkFirmwareImage(data: makeImage(version: "v2", sha: 0x22))
        do { _ = try await flow.run(image: image); XCTFail("expected failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("predates USB-session auth"), error.localizedDescription) }
        XCTAssertEqual(board.version, "v1")
    }

    func testOldFirmwareStillUpdatesWithTheLANToken() async throws {
        let flow = makeFlow()
        board.usbSessionAuth = false
        let image = try TonoLinkFirmwareImage(data: makeImage(version: "v2", sha: 0x22))
        guard case .confirmed = try await flow.run(image: image, lanToken: board.lanToken) else { return XCTFail() }
    }

    func testReadsAndSetsWiFiOverTheUSBSession() async throws {
        let flow = makeFlow()
        let before = try await flow.readWiFi()
        XCTAssertEqual(before.ssid, "vaca")
        let state = try await flow.setWiFi(try TonoLinkWiFiCredentials(ssid: "office", password: "secret"))
        XCTAssertEqual(state, TonoLinkWiFiState(ssid: "office", connected: true, ip: "192.168.6.77", rssi: -51))
        XCTAssertEqual(board.log.filter { $0 == "usb_net" }.count, 2)
        XCTAssertNil(board.authenticated)
    }

    func testWrongLANTokenIsRejected() async throws {
        let flow = makeFlow()
        let image = try TonoLinkFirmwareImage(data: makeImage(version: "v2", sha: 0x22))
        do { _ = try await flow.run(image: image, lanToken: String(repeating: "0", count: 64)); XCTFail("expected failure") }
        catch { XCTAssertTrue(error.localizedDescription.hasPrefix("POST /ota → 401")) }
        XCTAssertEqual(board.version, "v1")
    }
}
