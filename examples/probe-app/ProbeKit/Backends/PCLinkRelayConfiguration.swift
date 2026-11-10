// SPDX-License-Identifier: MIT
// The one place that owns the default relay origin and the DEBUG-only
// loopback override (P28). The stored/QR value is an http(s) origin; the
// PCLink layer derives the ws(s) URL (§3.1).

import Foundation

public enum PCLinkRelayConfiguration {
    /// Placeholder only: replace this with the assigned production relay origin
    /// before shipping. It is deliberately an `https` origin, not a `wss` URL,
    /// because every PCLink origin field is http(s) and the client derives the
    /// WebSocket scheme.
    public static let placeholderOrigin = "https://relay.example.invalid"

    /// Manual-code pairing has no relay in the code, so it uses this origin.
    /// A QR/manual URI that carries its own `r=` field wins over this value.
    public static var manualPairingOrigin: String {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["PDSH_PCLINK_RELAY"],
           let origin = normalizedLoopbackOrigin(raw) {
            return origin
        }
        #endif
        return placeholderOrigin
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

// MARK: - Install / pairing command (pclink-pacing)

// MARK: - Install guide (pclink-pacing)

/// The one copy-paste install/pairing guide. It lives next to the relay origin
/// (`PCLinkRelayConfiguration`) so the command text has a single owner; the
/// drawer empty state, the pairing page and `pclink/README.md` carry the same
/// string. `#main` only resolves after the PR that adds `pclink/` is merged;
/// the install was verified against the PR head commit in a throwaway
/// `DSH_HOME` (see the PC-20261109-pclink-v1 change record §4.17).
public enum PCLinkInstallGuide {
    public static let requirement = "电脑上需要已安装 DSH 0.2.2 及以上版本。"
    public static let restartHint = "安装后重启 dsh web，再在电脑上运行配对命令。"
    /// Shortest form: `dsh plugin` forwards to pnpm, whose git subdirectory
    /// syntax is `github:<owner>/<repo>#<ref>&path:/<dir>`.
    public static let installCommand =
        "dsh plugin --profile web add 'github:launsion-boop/phone-dsh#main&path:/pclink'"
    /// The installed package exposes `bin.pclink`; the profile installs it
    /// under its own node_modules/.bin. This avoids needing a global pclink.
    public static let pairingCommand =
        "~/.dsh/profiles/web/node_modules/.bin/pclink pair"
    public static let title = "先在电脑上安装 DSH 插件"
}
