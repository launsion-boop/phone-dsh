// SPDX-License-Identifier: MIT
// phone-dsh — PhoneDSHBLE: lets a developer computer reach a TonoLink board
// through the iPhone it is plugged into, over the phone's Wi-Fi.
//
//   ANY  /board/<path>?<query>   proxied to http://192.168.247.1:8767/<path> over USB NCM
//   POST /ble/con                body: one console line → {"output":[…]}
//   GET  /ble/log?since=N        → {"lines":[…],"last":N}
//   POST /ble/ota                body: agent_s3.bin → BLE OTA + ota_confirm → timing
//   POST /usb/ota                body: agent_s3.bin → USB OTA + /ota/confirm after reboot
//   GET  /relay                  → relay status
//
// No credentials (owner decision, 2026-11-02): the relay is open to the local
// network, so it only listens while the user has switched it on in the
// foregrounded app; anyone on that Wi-Fi can then reach and flash the board.
// One request per connection (`Connection: close`); board operations run one
// at a time and a concurrent one gets 409.
import Foundation
import Network

public struct TonoLinkRelayRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var query: String
    /// Lowercased names.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, query: String = "", headers: [String: String] = [:], body: Data = Data()) {
        self.method = method; self.path = path; self.query = query; self.headers = headers; self.body = body
    }

    public func queryValue(_ name: String) -> String? {
        URLComponents(string: "?" + query)?.queryItems?.first { $0.name == name }?.value
    }
}

public struct TonoLinkRelayResponse: Equatable, Sendable {
    public var status: Int
    public var contentType: String
    public var body: Data

    public init(status: Int, contentType: String = "application/json", body: Data) {
        self.status = status; self.contentType = contentType; self.body = body
    }

    public static func json(_ status: Int, _ object: Any) -> TonoLinkRelayResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return TonoLinkRelayResponse(status: status, body: data + Data("\n".utf8))
    }

    public static func error(_ status: Int, _ message: String) -> TonoLinkRelayResponse { json(status, ["error": message]) }
}

/// Minimal HTTP/1.1 framing for the relay (no chunked bodies, no keep-alive).
public enum TonoLinkRelayHTTP {
    public static let maxHead = 16 * 1024
    public static let maxBody = 8 * 1024 * 1024

    public enum Head: Equatable {
        case incomplete
        case invalid(String)
        /// `bodyStart` is the offset of the body in the buffer.
        case complete(TonoLinkRelayRequest, contentLength: Int, bodyStart: Int)
    }

    public static func parseHead(_ buffer: Data) -> Head {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > maxHead ? .invalid("header too large") : .incomplete
        }
        guard let text = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid("header not UTF-8") }
        var lines = text.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count == 3, start[2].hasPrefix("HTTP/1.") else { return .invalid("bad request line") }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid("bad header") }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return .invalid("chunked bodies are not supported; send Content-Length") }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0, length <= maxBody else { return .invalid("bad Content-Length") }
        let target = String(start[1])
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let request = TonoLinkRelayRequest(method: String(start[0]).uppercased(), path: String(parts[0]),
                                           query: parts.count == 2 ? String(parts[1]) : "", headers: headers)
        return .complete(request, contentLength: length, bodyStart: end.upperBound - buffer.startIndex)
    }

    public static func encode(_ response: TonoLinkRelayResponse) -> Data {
        let reason = HTTPURLResponse.localizedString(forStatusCode: response.status).capitalized
        let head = "HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: \(response.contentType)\r\n"
            + "Content-Length: \(response.body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + response.body
    }
}

/// Routes relay requests. Transports are injected so routing is testable.
@MainActor public final class TonoLinkRelay {
    private let http: TonoLinkHTTP
    private let makeBLE: () -> TonoLinkBLEDebug
    private let makeUSB: () -> TonoLinkUSBOTA
    private var busy: String?
    public private(set) var served = 0
    public var onLog: ((String) -> Void)?
    /// Extra fields for `GET /relay` (e.g. the app's background keep-alive state).
    public var statusExtras: (() -> [String: Any])?
    /// App-provided debug routes, tried before the built-in ones (nil = not handled).
    public var extraRoutes: ((TonoLinkRelayRequest) async -> TonoLinkRelayResponse?)?

    /// Headers a proxied request keeps; anything else (cookies, Authorization) is dropped.
    static let forwarded = ["content-type", "x-crc32", "x-usb-token", "x-elf-sha256", "accept", "x-controller"]

    public init(http: TonoLinkHTTP, makeBLE: @escaping () -> TonoLinkBLEDebug,
                makeUSB: @escaping () -> TonoLinkUSBOTA) {
        self.http = http; self.makeBLE = makeBLE; self.makeUSB = makeUSB
    }

    public func handle(_ request: TonoLinkRelayRequest) async -> TonoLinkRelayResponse {
        served += 1
        onLog?("\(request.method) \(request.path)")
        do {
            if request.path == "/relay" {
                var status: [String: Any] = ["ok": true, "busy": busy ?? "", "served": served]
                status.merge(statusExtras?() ?? [:]) { current, _ in current }
                return .json(200, status)
            }
            if request.path == "/board" || request.path.hasPrefix("/board/") { return try await proxy(request) }
            if let extraRoutes, let response = await extraRoutes(request) { return response }
            switch (request.method, request.path) {
            case ("POST", "/ble/con"):
                let command = String(decoding: request.body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                return try await exclusive("ble/con") {
                    let ble = makeBLE(); defer { ble.disconnect() }
                    return .json(200, ["output": try await ble.console(command)])
                }
            case ("GET", "/ble/log"):
                let since = UInt32(request.queryValue("since") ?? "0") ?? 0
                return try await exclusive("ble/log") {
                    let ble = makeBLE(); defer { ble.disconnect() }
                    let page = try await ble.log(since: since)
                    return .json(200, ["lines": page.lines.map { "\($0.index) \($0.text)" }, "last": page.last])
                }
            case ("POST", "/ble/ota"):
                let image = try TonoLinkFirmwareImage(data: request.body)
                return try await exclusive("ble/ota") {
                    let ble = makeBLE(); defer { ble.disconnect() }
                    let report = try await ble.ota(image: image)
                    return .json(200, ["bytes": report.bytes, "chunk": report.chunk, "resends": report.resends,
                                       "transfer_s": Self.seconds(report.transfer), "total_s": Self.seconds(report.total),
                                       "bytes_per_s": Int(report.bytesPerSecond), "elf_sha256": image.elfSHA256])
                }
            case ("POST", "/usb/ota"):
                let image = try TonoLinkFirmwareImage(data: request.body)
                return try await exclusive("usb/ota") {
                    let started = ContinuousClock.now
                    let outcome = try await makeUSB().run(image: image)
                    let (kind, state): (String, TonoLinkOTAState) = switch outcome {
                    case .confirmed(let state): ("confirmed", state)
                    case .alreadyRunning(let state): ("already_running", state)
                    }
                    return .json(200, ["outcome": kind, "slot": state.slot, "state": state.state, "version": state.version,
                                       "elf_sha256": state.elfSHA256, "total_s": Self.seconds(ContinuousClock.now - started)])
                }
            default:
                return .error(404, "unknown relay route \(request.method) \(request.path)")
            }
        } catch let error as RelayBusy {
            return .error(409, "board busy with \(error.operation)")
        } catch {
            return .error(502, error.localizedDescription)
        }
    }

    private struct RelayBusy: Error { let operation: String }

    private func exclusive(_ operation: String, _ body: () async throws -> TonoLinkRelayResponse) async throws -> TonoLinkRelayResponse {
        if let busy { throw RelayBusy(operation: busy) }
        busy = operation
        defer { busy = nil }
        return try await body()
    }

    private func proxy(_ request: TonoLinkRelayRequest) async throws -> TonoLinkRelayResponse {
        var components = URLComponents(url: TonoLinkUSB.baseURL, resolvingAgainstBaseURL: false)!
        let rest = String(request.path.dropFirst("/board".count))
        components.percentEncodedPath = rest.isEmpty ? "/" : rest
        if !request.query.isEmpty { components.percentEncodedQuery = request.query }
        var forward = URLRequest(url: components.url!, timeoutInterval: rest == "/ota" ? 200 : 30)
        forward.httpMethod = request.method
        for name in Self.forwarded { if let value = request.headers[name] { forward.setValue(value, forHTTPHeaderField: name) } }
        if request.method != "GET", request.method != "HEAD" { forward.httpBody = request.body }
        let (status, body) = try await http.send(forward, body: request.body.isEmpty ? nil : request.body, progress: nil)
        // TonoLinkHTTP returns no headers; the board answers JSON or plain text.
        let type = body.first == UInt8(ascii: "{") ? "application/json" : "text/plain; charset=utf-8"
        return TonoLinkRelayResponse(status: status, contentType: type, body: body)
    }

    nonisolated static func seconds(_ duration: Duration) -> Double {
        ((Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18) * 1000).rounded() / 1000
    }
}

/// The relay's TCP listener on the phone's network interfaces.
@MainActor public final class TonoLinkRelayServer {
    public let port: UInt16
    private let relay: TonoLinkRelay
    private var listener: NWListener?
    private var running = false
    public private(set) var restarts = 0
    public private(set) var state = "stopped"
    public var onStateChange: ((String) -> Void)?

    public init(relay: TonoLinkRelay, port: UInt16 = 8780) {
        self.relay = relay; self.port = port
    }

    public func start() throws {
        guard listener == nil else { return }
        running = true
        try listen()
    }

    /// Recreates the listener 1 s after it fails or stalls while running.
    private func listen() throws {
        let parameters = NWParameters.tcp
        // Developer computers reach the phone on Wi-Fi; never expose it on cellular.
        parameters.prohibitedInterfaceTypes = [.cellular]
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self else { return }
                guard self.listener === listener else { return }
                switch state {
                case .ready: self.state = "listening on :\(self.port)" + (self.restarts > 0 ? " (restarted \(self.restarts)x)" : "")
                case .failed(let error), .waiting(let error):
                    self.state = "relistening after \(error)"
                    self.listener?.cancel(); self.listener = nil
                    self.restarts += 1
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(1))
                        guard let self, self.running, self.listener == nil else { return }
                        do { try self.listen() } catch { self.state = "failed: \(error)"; self.onStateChange?(self.state) }
                    }
                default: return
                }
                self.onStateChange?(self.state)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.serve(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    public func stop() {
        running = false
        listener?.cancel(); listener = nil
        state = "stopped"; onStateChange?(state)
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var buffer = buffer
                if let data { buffer.append(data) }
                switch TonoLinkRelayHTTP.parseHead(buffer) {
                case .invalid(let why):
                    self.reply(connection, .error(400, why))
                case .incomplete:
                    if error != nil || complete { connection.cancel() } else { self.read(connection, buffer: buffer) }
                case .complete(var request, let length, let start):
                    if buffer.count - start >= length {
                        request.body = Data(buffer[(buffer.startIndex + start)..<(buffer.startIndex + start + length)])
                        let response = await self.relay.handle(request)
                        self.reply(connection, response)
                    } else if error != nil || complete {
                        connection.cancel()
                    } else {
                        self.read(connection, buffer: buffer)
                    }
                }
            }
        }
    }

    private func reply(_ connection: NWConnection, _ response: TonoLinkRelayResponse) {
        connection.send(content: TonoLinkRelayHTTP.encode(response), completion: .contentProcessed { _ in connection.cancel() })
    }
}

public enum TonoLinkNetworkInfo {
    /// The phone's IPv4 address on Wi-Fi (`en0`), for showing the relay URL.
    public static func wifiIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard String(cString: entry.ifa_name) == "en0", let address = entry.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}
