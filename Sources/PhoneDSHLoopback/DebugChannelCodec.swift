// SPDX-License-Identifier: MIT
// DEBUG-only: the pure request decoder, token check and address check of the developer debug
// channel (spec/dev/debug-channel.md, ID DEV-01). Not a product protocol. The whole file is compiled
// out of Release builds; the listener that uses it lives in the probe app, also under `#if DEBUG`.
#if DEBUG
import Foundation

public struct DebugChannelRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Header names are lower-cased.
    public var headers: [String: String]
    public var body: Data
}

public enum DebugChannelParse: Equatable, Sendable {
    case needMore
    case request(DebugChannelRequest)
    case invalid(String)
}

public enum DebugChannelCodec {
    public static let tokenHeader = "x-pdsh-debug-token"
    public static let maxHeaderBytes = 16 * 1024
    public static let maxBodyBytes = 1024 * 1024

    /// Parses one HTTP/1.1 request from the bytes read so far.
    public static func parse(_ data: Data) -> DebugChannelParse {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHeaderBytes ? .invalid("headers too large") : .needMore
        }
        guard split.lowerBound <= maxHeaderBytes else { return .invalid("headers too large") }
        guard let head = String(data: data[..<split.lowerBound], encoding: .utf8) else { return .invalid("headers are not UTF-8") }
        let lines = head.components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard start.count == 3, start[2].hasPrefix("HTTP/1."), start[1].hasPrefix("/") else { return .invalid("bad request line") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .invalid("bad header") }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0, length <= maxBodyBytes else { return .invalid("bad content-length") }
        let bodyStart = split.upperBound
        guard data.count - bodyStart >= length else { return .needMore }
        let body = data.subdata(in: bodyStart..<(bodyStart + length))
        var path = start[1]
        var query: [String: String] = [:]
        if let mark = path.firstIndex(of: "?") {
            let raw = String(path[path.index(after: mark)...])
            path = String(path[..<mark])
            for pair in raw.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if let key = kv.first?.removingPercentEncoding {
                    query[key] = (kv.count > 1 ? kv[1] : "").removingPercentEncoding ?? ""
                }
            }
        }
        return .request(DebugChannelRequest(method: start[0].uppercased(), path: path, query: query, headers: headers, body: body))
    }

    /// 200 when the request may proceed, 403 for a non-private peer, 401 for a missing or wrong token.
    /// The address is checked first so a public peer learns nothing about the token.
    public static func authorize(headers: [String: String], token: String, remoteHost: String) -> Int {
        guard isPrivate(host: remoteHost) else { return 403 }
        guard !token.isEmpty, let given = headers[tokenHeader], constantTimeEqual(given, token) else { return 401 }
        return 200
    }

    public static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = x.count ^ y.count
        for i in 0..<max(x.count, y.count) { diff |= Int(i < x.count ? x[i] : 0) ^ Int(i < y.count ? y[i] : 0) }
        return diff == 0
    }

    /// Loopback, link-local and RFC 1918 IPv4; ::1, fe80::/10 and fc00::/7 (ULA, including the
    /// CoreDevice tunnel) IPv6; IPv4-mapped IPv6 follows its IPv4. Anything else, including a name, is public.
    public static func isPrivate(host raw: String) -> Bool {
        var host = raw
        if let pct = host.firstIndex(of: "%") { host = String(host[..<pct]) }       // scope id
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.contains(":") {
            let lower = host.lowercased()
            if lower == "::1" { return true }
            if lower.hasPrefix("::ffff:") { return isPrivate(host: String(lower.dropFirst(7))) }
            guard let first = lower.split(separator: ":", omittingEmptySubsequences: false).first,
                  let word = UInt16(first.isEmpty ? "0" : String(first), radix: 16) else { return false }
            return (word & 0xfe00) == 0xfc00 || (word & 0xffc0) == 0xfe80
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false).map { UInt8($0) }
        guard parts.count == 4, !parts.contains(where: { $0 == nil }) else { return false }
        let o = parts.compactMap { $0 }
        if o[0] == 127 || o[0] == 10 { return true }
        if o[0] == 192 && o[1] == 168 { return true }
        if o[0] == 172 && (16...31).contains(o[1]) { return true }
        if o[0] == 169 && o[1] == 254 { return true }
        return false
    }

    public static func response(status: Int, json: Data) -> Data {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 500: "Internal Server Error"][status] ?? "Error"
        var out = Data("HTTP/1.1 \(status) \(reason)\r\ncontent-type: application/json; charset=utf-8\r\ncontent-length: \(json.count)\r\nconnection: close\r\n\r\n".utf8)
        out.append(json)
        return out
    }
}
#endif
