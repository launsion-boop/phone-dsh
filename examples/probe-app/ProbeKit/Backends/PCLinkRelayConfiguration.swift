// SPDX-License-Identifier: MIT
// The one place that owns the default relay origin and the DEBUG-only
// loopback override (P28). The stored/QR value is an http(s) origin; the
// PCLink layer derives the ws(s) URL (§3.1).

import Foundation

public enum PCLinkRelayConfiguration {
    private static let productionOrigin = "https://pclink.tonoai.cn"

    /// Manual-code pairing has no relay in the code, so it defaults to the
    /// production origin. A QR/manual URI that carries its own `r=` field wins
    /// over this value.
    public static var manualPairingOrigin: String {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["PDSH_PCLINK_RELAY"],
           let origin = normalizedLoopbackOrigin(raw) {
            return origin
        }
        #endif
        return productionOrigin
    }

    /// Only a loopback http(s) value is accepted from the DEBUG environment.
    /// A `ws` URL is normalized to its http origin so validation and
    /// `websocketURL(for:)` remain the single derivation point.
    public static func normalizedLoopbackOrigin(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss" || scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(),
              host == "127.0.0.1" || host == "localhost" else { return nil }
        let originScheme = (scheme == "ws" || scheme == "http") ? "http" : "https"
        guard let port = url.port else { return "\(originScheme)://\(host)" }
        return "\(originScheme)://\(host):\(port)"
    }

    /// True only for a loopback relay URL (used by tests and the DEBUG env).
    public static func isLoopbackRelay(_ raw: String) -> Bool {
        normalizedLoopbackOrigin(raw) != nil
    }
}
