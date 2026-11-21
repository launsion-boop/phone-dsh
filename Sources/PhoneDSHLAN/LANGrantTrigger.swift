// SPDX-License-Identifier: MIT
import Foundation

/// A LAN MCP endpoint as lan-mcp.md builds it: `https://H[:port]/mcp` with `H` in canonical form.
public struct LANEndpoint: Equatable, Sendable {
    public let host: String
    public let port: Int
}

/// Decision logic for the device-bot LAN trigger (device-bot.md §4: "the user saved the exact-URL
/// grant and the credential for that endpoint"). Pure: the caller supplies the saved state and
/// fires the Bot creation only when this returns an endpoint.
public enum LANGrantTrigger {
    /// The LAN endpoint named by a saved URL, or `nil` when the URL is not one lan-mcp.md describes:
    /// HTTPS, no userinfo/query/fragment, path exactly `/mcp`, and a host that already equals
    /// `canon(host)` (a non-canonical host is rejected, never repaired: no case folding, no root
    /// dot removal, no IP literal). The port defaults to 443.
    public static func endpoint(forURL url: String) -> LANEndpoint? {
        guard let parts = URLComponents(string: url),
              parts.scheme == "https",
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path == "/mcp",
              let host = parts.host,
              LANDeviceCandidate.hostname(host) == host else { return nil }
        let port = parts.port ?? 443
        guard (1...65535).contains(port) else { return nil }
        return LANEndpoint(host: host, port: port)
    }

    /// The endpoint to create a Bot for after a save, or `nil`. Fires only when the saved URL is a
    /// LAN endpoint, the grant and the credential are both present afterwards, and the previous
    /// saved state was not already the same endpoint with a credential (re-saving an unchanged
    /// endpoint, or loading, is not a trigger).
    public static func newlySaved(beforeURL: String?, beforeHasCredential: Bool,
                                  afterURL: String, afterHasCredential: Bool) -> LANEndpoint? {
        guard afterHasCredential, let after = endpoint(forURL: afterURL) else { return nil }
        if beforeHasCredential, let beforeURL, endpoint(forURL: beforeURL) == after { return nil }
        return after
    }
}
