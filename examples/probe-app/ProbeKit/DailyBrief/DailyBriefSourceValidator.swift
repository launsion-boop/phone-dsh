// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — ProbeKit: feed and content URL policy.

import Foundation

public enum DailyBriefSourceValidator {
    public static func validate(_ url: URL?) throws -> URL {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty else {
            throw DailyBriefError.invalidSource("只支持带主机名的 HTTPS 地址")
        }
        guard components.user == nil, components.password == nil else {
            throw DailyBriefError.invalidSource("地址中不能包含用户名或密码")
        }
        let normalizedHost = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard !Self.isLocalOrPrivateHost(normalizedHost) else {
            throw DailyBriefError.invalidSource("不允许访问本机或私网地址")
        }
        return url
    }

    public static func contentURL(from rawValue: String?) -> URL? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty,
              let url = URL(string: rawValue),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil, components.password == nil else {
            return nil
        }
        return url
    }

    private static func isLocalOrPrivateHost(_ host: String) -> Bool {
        if host == "localhost" || host == "local" || host == "0.0.0.0" || host == "::" || host == "::1" {
            return true
        }
        let localSuffixes = [".localhost", ".local", ".internal", ".lan", ".intranet", ".corp", ".home"]
        if localSuffixes.contains(where: { host.hasSuffix($0) }) { return true }
        if host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        let (a, b) = (parts[0], parts[1])
        if a == 0 || a == 10 || a == 127 || a >= 224 { return true }
        if a == 169 && b == 254 { return true }
        if a == 192 && b == 168 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        if a == 100 && (64...127).contains(b) { return true }
        if a == 192 && b == 0 { return true }
        if a == 192 && b == 0 && parts[2] == 2 { return true }
        if a == 198 && (b == 18 || b == 19) { return true }
        if a == 198 && b == 51 && parts[2] == 100 { return true }
        if a == 203 && b == 0 && parts[2] == 113 { return true }
        return false
    }
}
