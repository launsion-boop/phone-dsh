// SPDX-License-Identifier: MIT
// phone-dsh — PhoneDSHBLE: the USB OTA sequence for a TonoLink board.
//
//   BLE `usb_net` → :8768 auth (kept alive) → POST /ota → board reboots →
//   BLE `usb_net` (new token) → :8768 auth → GET /ota/state (running image
//   must be the uploaded one) → POST /ota/confirm → poll until `valid`.
// The same USB session also reads and sets the board's Wi-Fi (/v1/wifi).
//
// The radio, socket and HTTP are injected so the sequence is testable without
// hardware (see `TonoLinkUSBOTATests`).
import Foundation

/// The board's BLE ctrl channel (`cmd` write + `status` notify).
@MainActor public protocol TonoLinkCtrlLink: AnyObject {
    /// Connects (or reconnects after a reboot) and subscribes to `status`.
    func connect(timeout: Duration) async throws
    /// Writes one ctrl line and returns the matching `ack`.
    func command(_ line: Data, seq: UInt16, timeout: Duration) async throws -> TonoLinkCtrlAck
    func disconnect()
}

/// An authenticated :8768 socket. While it is open the board accepts the token.
@MainActor public protocol TonoLinkUSBSession: AnyObject {
    var isAlive: Bool { get }
    func close()
}

@MainActor public protocol TonoLinkUSBNetwork: AnyObject {
    /// One connect + authenticate attempt; throws if the NCM route or auth fails.
    func openSession(token: String) async throws -> TonoLinkUSBSession
}

@MainActor public protocol TonoLinkHTTP: AnyObject {
    func send(_ request: URLRequest, body: Data?, progress: ((Double) -> Void)?) async throws -> (status: Int, body: Data)
}

@MainActor public protocol TonoLinkOTAClock: AnyObject {
    var now: ContinuousClock.Instant { get }
    func sleep(for duration: Duration) async throws
}

@MainActor public final class SystemTonoLinkOTAClock: TonoLinkOTAClock {
    public init() {}
    public var now: ContinuousClock.Instant { ContinuousClock.now }
    public func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}

public enum TonoLinkOTAEvent: Equatable, Sendable {
    case step(String)
    case uploadProgress(Double)
    case state(TonoLinkOTAState)
    case wifi(TonoLinkWiFiState)
}

public enum TonoLinkOTAOutcome: Equatable, Sendable {
    /// The uploaded image runs and is marked valid.
    case confirmed(TonoLinkOTAState)
    /// The board already ran this image as a valid one; nothing was uploaded.
    case alreadyRunning(TonoLinkOTAState)
}

@MainActor public final class TonoLinkUSBOTA {
    public struct Timing: Sendable {
        public var bleConnect: Duration = .seconds(20)
        public var reconnectBLE: Duration = .seconds(60)
        public var ack: Duration = .seconds(5)
        public var usbSession: Duration = .seconds(30)
        public var retryDelay: Duration = .seconds(1)
        public var rebootSettle: Duration = .seconds(3)
        public var confirmPoll: Duration = .seconds(15)
        public init() {}
    }

    private let ctrl: TonoLinkCtrlLink
    private let network: TonoLinkUSBNetwork
    private let http: TonoLinkHTTP
    private let clock: TonoLinkOTAClock
    private let makeToken: () -> String
    private let timing: Timing
    private var seq: UInt16
    private var session: TonoLinkUSBSession?
    private var token = ""
    public var onEvent: ((TonoLinkOTAEvent) -> Void)?

    public init(ctrl: TonoLinkCtrlLink, network: TonoLinkUSBNetwork, http: TonoLinkHTTP,
                clock: TonoLinkOTAClock? = nil, timing: Timing = Timing(),
                makeToken: @escaping () -> String = TonoLinkTokens.makeUSBToken,
                firstSeq: UInt16 = UInt16.random(in: 1...50_000)) {
        self.ctrl = ctrl; self.network = network; self.http = http; self.clock = clock ?? SystemTonoLinkOTAClock()
        self.timing = timing; self.makeToken = makeToken; self.seq = firstSeq
    }

    /// Uploads `image` over USB and confirms it after the reboot.
    public func run(image: TonoLinkFirmwareImage, lanToken: String? = nil) async throws -> TonoLinkOTAOutcome {
        defer { finish() }
        try await openUSB(bleTimeout: timing.bleConnect)
        let before = try await readState()
        if before.elfSHA256 == image.elfSHA256 {
            if before.isConfirmed { return .alreadyRunning(before) }
            // A previous attempt rebooted into this image but was not confirmed yet.
            return .confirmed(try await confirm(before, lanToken: lanToken))
        }
        let bootBefore = before.boot

        emit(.step("Uploading \(image.data.count) bytes (\(image.version))"))
        try await ensureSession()
        do {
            let (status, body) = try await http.send(
                TonoLinkOTARequest.upload(image: image, lanToken: lanToken, usbToken: token), body: image.data,
                progress: { [weak self] in self?.emit(.uploadProgress($0)) })
            guard (200..<300).contains(status) else { throw Self.rejected("POST /ota", status, body, lanToken: lanToken) }
            emit(.step("Board accepted the image; rebooting"))
        } catch let error as TonoLinkUSBOTAError {
            throw error
        } catch {
            // The board resets right after answering; a lost response is not a
            // failure by itself. The running image decides below.
            emit(.step("Upload response lost (\(error.localizedDescription)); checking after reboot"))
        }

        closeUSB()
        ctrl.disconnect()
        try await clock.sleep(for: timing.rebootSettle)
        try await openUSB(bleTimeout: timing.reconnectBLE)
        let after = try await readState()
        guard after.elfSHA256 == image.elfSHA256 else {
            let rebooted = after.boot != bootBefore ? "rebooted" : "did not reboot"
            throw TonoLinkUSBOTAError("Board \(rebooted) but runs \(after.version) (\(after.elfSHA256.prefix(12))), not the uploaded image")
        }
        return .confirmed(try await confirm(after, lanToken: lanToken))
    }

    /// Confirms an image that is already running but pending USB confirmation.
    public func confirmRunning(lanToken: String? = nil) async throws -> TonoLinkOTAState {
        defer { finish() }
        try await openUSB(bleTimeout: timing.bleConnect)
        return try await confirm(try await readState(), lanToken: lanToken)
    }

    /// Reads `/ota/state` through a fresh USB session.
    public func readStateOverUSB() async throws -> TonoLinkOTAState {
        defer { finish() }
        try await openUSB(bleTimeout: timing.bleConnect)
        return try await readState()
    }

    /// Raw GETs (path → status, body) through one fresh USB session; for diagnostics.
    public func get(paths: [String]) async throws -> [(path: String, status: Int, body: Data)] {
        defer { finish() }
        try await openUSB(bleTimeout: timing.bleConnect)
        var results: [(path: String, status: Int, body: Data)] = []
        for path in paths {
            var request = URLRequest(url: TonoLinkUSB.baseURL.appendingPathComponent(path), timeoutInterval: 5)
            request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            let (status, body) = try await http.send(request, body: nil, progress: nil)
            results.append((path, status, body))
        }
        return results
    }

    /// Reads the board's Wi-Fi state through a fresh USB session.
    public func readWiFi() async throws -> TonoLinkWiFiState {
        defer { finish() }
        try await openUSB(bleTimeout: timing.bleConnect)
        return try await wifiState()
    }

    /// Saves Wi-Fi credentials on the board; it reconnects without rebooting.
    public func setWiFi(_ credentials: TonoLinkWiFiCredentials, lanToken: String? = nil) async throws -> TonoLinkWiFiState {
        defer { finish() }
        try await openUSB(bleTimeout: timing.bleConnect)
        emit(.step("Saving Wi-Fi \(credentials.ssid)"))
        let (status, body) = try await http.send(
            try TonoLinkOTARequest.setWiFi(credentials, lanToken: lanToken, usbToken: token), body: nil, progress: nil)
        guard (200..<300).contains(status) else { throw Self.rejected("POST /v1/wifi", status, body, lanToken: lanToken) }
        let state = try TonoLinkWiFiState.decode(body)
        emit(.wifi(state))
        return state
    }

    private func wifiState() async throws -> TonoLinkWiFiState {
        let (status, body) = try await http.send(TonoLinkOTARequest.wifiState(), body: nil, progress: nil)
        guard status == 200 else { throw TonoLinkUSBOTAError("GET /v1/wifi → \(status) (firmware without /v1/wifi?)") }
        let state = try TonoLinkWiFiState.decode(body)
        emit(.wifi(state))
        return state
    }

    private func confirm(_ state: TonoLinkOTAState, lanToken: String?) async throws -> TonoLinkOTAState {
        if state.isConfirmed { return state }
        guard state.needsUSBConfirmation else {
            throw TonoLinkUSBOTAError("Image is \(state.state) but the board does not expect a USB confirmation")
        }
        emit(.step("Confirming \(state.version)"))
        try await ensureSession()
        let (status, body) = try await http.send(
            TonoLinkOTARequest.confirm(elfSHA256: state.elfSHA256, lanToken: lanToken, usbToken: token), body: nil, progress: nil)
        guard (200..<300).contains(status) else { throw Self.rejected("POST /ota/confirm", status, body, lanToken: lanToken) }
        // The board marks the image valid on its next 1 s tick, and only while
        // this USB session is still authenticated.
        let deadline = clock.now + timing.confirmPoll
        while true {
            try await clock.sleep(for: timing.retryDelay)
            try await ensureSession()
            let current = try await readState()
            if current.isConfirmed { emit(.step("Confirmed: \(current.version) in \(current.slot)")); return current }
            if clock.now >= deadline { throw TonoLinkUSBOTAError("Board did not mark \(current.version) valid (state \(current.state))") }
        }
    }

    private func openUSB(bleTimeout: Duration) async throws {
        emit(.step("Connecting to the board over Bluetooth"))
        try await ctrl.connect(timeout: bleTimeout)
        token = makeToken()
        seq = seq == UInt16.max ? 1 : seq + 1
        let ack = try await ctrl.command(try TonoLinkCtrlCommand.usbNet(seq: seq, token: token), seq: seq, timeout: timing.ack)
        guard ack.seq == seq, ack.ok else { throw TonoLinkUSBOTAError("usb_net rejected: \(ack.error ?? "seq mismatch")") }
        emit(.step("USB network enabled; opening \(TonoLinkUSB.host):\(TonoLinkUSB.socketPort)"))
        try await ensureSession(timeout: timing.usbSession)
    }

    private func ensureSession(timeout: Duration? = nil) async throws {
        if session?.isAlive == true { return }
        session?.close(); session = nil
        let deadline = clock.now + (timeout ?? timing.usbSession)
        var lastError: Error = TonoLinkUSBOTAError("USB session unavailable")
        while clock.now < deadline {
            do {
                session = try await network.openSession(token: token)
                emit(.step("USB session authenticated"))
                return
            } catch {
                lastError = error
                try await clock.sleep(for: timing.retryDelay)
            }
        }
        throw TonoLinkUSBOTAError("USB session failed: \(lastError.localizedDescription)")
    }

    private func readState() async throws -> TonoLinkOTAState {
        let (status, body) = try await http.send(TonoLinkOTARequest.state(), body: nil, progress: nil)
        guard status == 200 else { throw TonoLinkUSBOTAError("GET /ota/state → \(status)") }
        let state = try TonoLinkOTAState.decode(body)
        emit(.state(state))
        return state
    }

    private func closeUSB() { session?.close(); session = nil }

    private func finish() { closeUSB(); ctrl.disconnect() }

    private func emit(_ event: TonoLinkOTAEvent) { onEvent?(event) }

    private static func rejected(_ what: String, _ status: Int, _ body: Data, lanToken: String?) -> TonoLinkUSBOTAError {
        if status == 401 && lanToken == nil {
            return TonoLinkUSBOTAError("\(what) → 401: this board's firmware predates USB-session auth; save the LAN token once")
        }
        return TonoLinkUSBOTAError("\(what) → \(status): \(text(body))")
    }

    private static func text(_ body: Data) -> String {
        String(decoding: body.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
