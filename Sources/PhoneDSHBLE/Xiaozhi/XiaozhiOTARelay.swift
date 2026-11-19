// SPDX-License-Identifier: MIT
// phone-dsh — PhoneDSHBLE/Xiaozhi: the OTA relay's HTTP framing and routing
// (spec/device/v1/xiaozhi-firmware.md §2.1–§2.3, §2.5). No sockets here: the
// listener is XiaozhiOTARelayServer, the upstream client and the clock are
// injected, so the route logic runs in tests without a network.
#if DEBUG
import Foundation
import PhoneDSHLoopback

public struct XiaozhiHTTPRequest: Equatable, Sendable {
    public var method: String
    /// Path without the query string.
    public var path: String
    /// Lowercased names.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method; self.path = path; self.headers = headers; self.body = body
    }
}

public struct XiaozhiHTTPResponse: Equatable, Sendable {
    public var status: Int
    public var contentType: String?
    public var body: Data

    public init(status: Int, contentType: String? = nil, body: Data = Data()) {
        self.status = status; self.contentType = contentType; self.body = body
    }
}

/// Minimal HTTP/1.1 framing: one request per connection, `Content-Length` bodies only.
public enum XiaozhiHTTP {
    public static let maxHead = 16 * 1024
    public static let maxBody = 64 * 1024

    public enum Head: Equatable {
        case incomplete
        /// Reply with this status and stop reading.
        case reject(Int)
        /// `bodyStart` is the offset of the body in the buffer.
        case complete(XiaozhiHTTPRequest, contentLength: Int, bodyStart: Int)
    }

    public static func parseHead(_ buffer: Data) -> Head {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > maxHead ? .reject(413) : .incomplete
        }
        guard end.lowerBound - buffer.startIndex <= maxHead else { return .reject(413) }
        guard let text = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else { return .reject(400) }
        var lines = text.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard start.count == 3, start[2].hasPrefix("HTTP/1.") else { return .reject(400) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .reject(400) }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return .reject(400) }
        guard let length = Int(headers["content-length"] ?? "0"), length >= 0 else { return .reject(400) }
        guard length <= maxBody else { return .reject(413) }
        let target = String(start[1])
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        let request = XiaozhiHTTPRequest(method: String(start[0]).uppercased(), path: path, headers: headers)
        return .complete(request, contentLength: length, bodyStart: end.upperBound - buffer.startIndex)
    }

    public static func encode(_ response: XiaozhiHTTPResponse) -> Data {
        encodeHead(response) + response.body
    }

    /// The status line and headers of `encode(_:)`, without the body.
    public static func encodeHead(_ response: XiaozhiHTTPResponse) -> Data {
        let reason = HTTPURLResponse.localizedString(forStatusCode: response.status).capitalized
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        if let type = response.contentType { head += "Content-Type: \(type)\r\n" }
        head += "Content-Length: \(response.body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        return Data(head.utf8)
    }
}

/// The fixed upstream version check (§2.3). Throwing means unreachable, timed out or a TLS failure.
public protocol XiaozhiUpstream: Sendable {
    func send(method: String, headers: [String: String], body: Data?) async throws -> (status: Int, contentType: String?, body: Data)
}

/// `https://api.tenclass.net/xiaozhi/ota/` over an ephemeral session that never uses cellular.
public final class XiaozhiURLSessionUpstream: XiaozhiUpstream {
    public static let url = URL(string: "https://api.tenclass.net/xiaozhi/ota/")!
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = false
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func send(method: String, headers: [String: String], body: Data?) async throws -> (status: Int, contentType: String?, body: Data) {
        var request = URLRequest(url: Self.url, timeoutInterval: 20)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (http.statusCode, http.value(forHTTPHeaderField: "Content-Type"), data)
    }
}

/// Routes relay requests. The listener hands it the peer address and the parsed request.
@MainActor public final class XiaozhiOTARelay {
    public static let port: UInt16 = 8781
    /// Copied from the device request to the upstream; nothing else is (§2.3).
    public static let forwardedHeaders = ["Device-Id", "Client-Id", "Serial-Number", "Activation-Version",
                                          "User-Agent", "Accept-Language", "Authorization", "Content-Type"]

    public let images: XiaozhiStagedImages
    public let records: XiaozhiDeviceRecords
    /// Firmware downloads, for the progress UI only (never read back into a response).
    public let downloads = XiaozhiDownloads()
    private let upstream: XiaozhiUpstream
    let now: @Sendable () -> Date
    private let wifiIPv4: @Sendable () -> String?
    public private(set) var served = 0

    public init(images: XiaozhiStagedImages = XiaozhiStagedImages(),
                records: XiaozhiDeviceRecords = XiaozhiDeviceRecords(),
                upstream: XiaozhiUpstream = XiaozhiURLSessionUpstream(),
                now: @escaping @Sendable () -> Date = { Date() },
                wifiIPv4: @escaping @Sendable () -> String? = { TonoLinkNetworkInfo.wifiIPv4() }) {
        self.images = images; self.records = records; self.upstream = upstream
        self.now = now; self.wifiIPv4 = wifiIPv4
    }

    /// `http://<Wi-Fi IPv4>:8781/xiaozhi/ota/`, or nil without a Wi-Fi IPv4 (§2.1).
    public var otaURL: String? { wifiIPv4().map { "http://\($0):\(Self.port)/xiaozhi/ota/" } }

    /// §2.1 peer check first (a non-private peer is not recorded), then §2.2 routing.
    public func handle(peerHost: String, _ request: XiaozhiHTTPRequest) async -> XiaozhiHTTPResponse {
        guard DebugChannelCodec.isPrivate(host: peerHost) else { return XiaozhiHTTPResponse(status: 403) }
        served += 1
        switch (request.method, request.path) {
        case ("GET", "/xiaozhi/ota/"), ("POST", "/xiaozhi/ota/"):
            return await versionCheck(request)
        case ("GET", _):
            if let sha = Self.firmwareDigest(path: request.path) { return firmware(sha256: sha) }
            return XiaozhiHTTPResponse(status: 404)
        default:
            return XiaozhiHTTPResponse(status: 404)
        }
    }

    /// `<sha>` of `/xiaozhi/firmware/<sha>.bin` when it is 64 lowercase hex.
    public static func firmwareDigest(path: String) -> String? {
        let prefix = "/xiaozhi/firmware/", suffix = ".bin"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix), path.count == prefix.count + 64 + suffix.count else { return nil }
        let digest = String(path.dropFirst(prefix.count).dropLast(suffix.count))
        return XiaozhiDeviceReport.isLowerHex64(digest) ? digest : nil
    }

    private func firmware(sha256: String) -> XiaozhiHTTPResponse {
        guard let image = images.image(sha256: sha256) else { return XiaozhiHTTPResponse(status: 404) }
        return XiaozhiHTTPResponse(status: 200, contentType: "application/octet-stream", body: image.imageData)
    }

    private func versionCheck(_ request: XiaozhiHTTPRequest) async -> XiaozhiHTTPResponse {
        let body: Data? = request.body.isEmpty ? nil : request.body
        guard case .report(let report) = XiaozhiDeviceReport.parse(headers: request.headers, body: body) else {
            return XiaozhiHTTPResponse(status: 400)
        }
        var forwarded: [String: String] = [:]
        for name in Self.forwardedHeaders {
            if let value = request.headers[name.lowercased()] { forwarded[name] = value }
        }
        let reply: (status: Int, contentType: String?, body: Data)
        do {
            reply = try await upstream.send(method: request.method, headers: forwarded, body: body)
        } catch {
            records.record(report: report, at: now(), decision: .upstreamFailed)
            return XiaozhiHTTPResponse(status: 502)
        }
        var decision = XiaozhiOTADecision.passthrough
        var out = reply.body
        // Without a Wi-Fi IPv4 there is no URL to offer, so the answer is left as the upstream sent it.
        if let mac = report.mac, let staged = images.staged(forMAC: mac), let host = wifiIPv4() {
            let rewritten = XiaozhiOTARewrite.apply(status: reply.status, body: reply.body, report: report,
                                                    staged: staged.rewriteInput, base: "http://\(host):\(Self.port)")
            decision = rewritten.decision; out = rewritten.body
        }
        records.record(report: report, at: now(), decision: XiaozhiRelayDecision(rawValue: decision.rawValue) ?? .passthrough)
        return XiaozhiHTTPResponse(status: reply.status, contentType: reply.contentType ?? "application/json", body: out)
    }
}
#endif
