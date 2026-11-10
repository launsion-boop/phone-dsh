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

// MARK: - Install / pairing command (pclink-pacing)

// MARK: - Install guide (pclink-pacing)

/// The single copy-paste install guide. It lives next to the relay origin
/// (`PCLinkRelayConfiguration`) so the command text has a single owner; the
/// pairing page (`PCInstallCommandCard`) and `pclink/README.md` carry the
/// same string. The drawer no longer repeats it. The script checks the
/// environment, installs/upgrades the plugin, loads it and shows the pairing
/// QR; scanning is the approval (see `pclink/install.sh` and `pclink/README.md`).
public enum PCLinkInstallGuide {
    public static let requirement = "电脑上需要已安装 DSH 0.2.2 及以上版本和 Node.js 22 及以上版本。"
    public static let hint = "在电脑终端运行上面的命令，按提示用手机扫码；脚本会安装插件、加载 dsh web 并显示配对二维码。"
    public static let installCommand =
        "curl -fsSL https://raw.githubusercontent.com/launsion-boop/phone-dsh/main/pclink/install.sh | bash"
    public static let title = "先在电脑上安装 DSH 插件"
}
