// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHGateway: credential scope routing.
//
// One upstream host can carry model requests and an independent web Search /
// Fetch API with different keys. A host-only scope cannot tell those apart, so
// the gateway publishes the lowercased host (`service`), the normalized request
// path (`audience`), and the URL's lowercased scheme and explicit port.
// `PhoneWebSearchCredentialRouter` matches the exact `/search` and `/fetch`
// operation paths and delegates every other path to the model credential
// provider; that provider can now require the configured model origin and a
// known protocol path before it releases the model key.

import Foundation
import PhoneDSHAgentCore

/// The host/path values the gateway puts into every credential lookup.
public enum ModelGatewayCredentialRouting {
    /// Build the scope for one upstream request.
    ///
    /// `service` is the lowercased URL host (empty when the URL has none),
    /// `audience` is the normalized request path, `scheme` is the lowercased
    /// URL scheme and `port` is the explicit URL port (`nil` when the URL uses
    /// the scheme default). The gateway always supplies a path, so a provider
    /// can route a same-host Search/Fetch API to its own credential and can
    /// separate a same-host model origin from other ports.
    public static func scope(for url: URL) -> CredentialScope {
        CredentialScope(service: url.host?.lowercased() ?? "",
                        audience: normalizedPath(url),
                        scheme: url.scheme?.lowercased(),
                        port: url.port)
    }

    /// The normalized request path of a URL.
    public static func normalizedPath(_ url: URL) -> String {
        normalizedPath(url.path)
    }

    /// The effective port for a URL: the explicit port or the scheme default.
    public static func effectivePort(_ url: URL, scheme: String? = nil) -> Int? {
        if let port = url.port { return port }
        switch (scheme ?? url.scheme?.lowercased()) {
        case "http", "ws": return 80
        case "https", "wss": return 443
        default: return nil
        }
    }

    /// Normalize a request path for credential routing.
    ///
    /// The result always starts with `/`; an empty path becomes `/`, repeated
    /// separators and `.`/`..` segments are resolved, and a trailing separator
    /// is removed (except for the root path). Queries and fragments never take
    /// part in the credential scope.
    public static func normalizedPath(_ rawPath: String) -> String {
        guard !rawPath.isEmpty else { return "/" }
        var path = rawPath.hasPrefix("/") ? rawPath : "/" + rawPath
        while path.contains("//") {
            path = path.replacingOccurrences(of: "//", with: "/")
        }
        var segments: [Substring] = []
        for segment in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch segment {
            case ".":
                continue
            case "..":
                if !segments.isEmpty { segments.removeLast() }
            default:
                segments.append(segment)
            }
        }
        guard !segments.isEmpty else { return "/" }
        return "/" + segments.joined(separator: "/")
    }
}
