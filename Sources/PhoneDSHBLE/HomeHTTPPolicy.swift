// SPDX-License-Identifier: MIT
import Foundation
import PhoneDSHAgentCore
import PDSHHomePolicy

public enum HomeHTTPPolicy {
    /// Uses the very same pure C policy as the reference firmware. First release
    /// narrows upstream hostnames to literal private IPv4, avoiding DNS/rebinding.
    public static func validate(_ arguments: JSONValue, allowedOrigins: Set<String>) throws -> String {
        guard case .object(let args) = arguments, Set(args.keys).isSubset(of: ["method", "url", "headers", "body", "timeout_ms"]),
              case .string(let method) = args["method"], case .string(let url) = args["url"],
              !method.contains("\0"), !url.contains("\0") else { throw BLEFailure("Invalid home.http arguments") }
        var request = xl_home_request_t()
        guard method.withCString({ xl_home_policy_method($0) }),
              url.withCString({ xl_home_policy_parse_url($0, &request, nil) }), request.host_is_ipv4 else { throw BLEFailure("home.http requires plain HTTP to a private IPv4 literal") }
        let host = withUnsafeBytes(of: request.host) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
        let origin = "http://\(host):\(request.port)"
        guard allowedOrigins.contains(origin) else { throw BLEFailure("Home origin is not authorized for this device: \(origin)") }
        if let headers = args["headers"] {
            guard case .object(let values) = headers else { throw BLEFailure("Headers must be an object") }
            for (name, value) in values.sorted(by: { $0.key < $1.key }) {
                guard case .string(let text) = value, !name.contains("\0"), !text.contains("\0"),
                      name.withCString({ n in text.withCString { xl_home_policy_header(n, $0, &request, nil) } }) else { throw BLEFailure("Invalid home.http header") }
            }
        }
        let body: String
        if let value = args["body"] { guard case .string(let text) = value else { throw BLEFailure("Body must be a string") }; body = text }
        else { body = "" }
        guard !body.contains("\0"), body.withCString({ b in method.withCString { xl_home_policy_body(b, body.utf8.count, $0, &request, nil) } }) else { throw BLEFailure("Invalid or oversized home.http body") }
        if let timeout = args["timeout_ms"] {
            guard case .number(let n) = timeout, n.isFinite, n.rounded() == n, (1000...10000).contains(n) else { throw BLEFailure("HTTP timeout must be 1000–10000 ms") }
        }
        return origin
    }
    public static func origins(_ text: String) throws -> Set<String> {
        var result = Set<String>()
        for token in text.split(whereSeparator: { $0.isWhitespace || $0 == "," }) {
            let value = String(token); var request = xl_home_request_t()
            guard !value.contains("\0") else { throw BLEFailure("Origin contains NUL") }
            let parsed = value.withCString { xl_home_policy_parse_url($0, &request, nil) }
            guard parsed else { throw BLEFailure("Origin rejected by device URL policy") }
            guard request.host_is_ipv4 else { throw BLEFailure("Origin must use a private IPv4 literal") }
            let path = withUnsafeBytes(of: request.path) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
            guard path == "/" else { throw BLEFailure("Home origins cannot include paths, queries or fragments") }
            let host = withUnsafeBytes(of: request.host) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
            result.insert("http://\(host):\(request.port)")
        }
        return result
    }
}
