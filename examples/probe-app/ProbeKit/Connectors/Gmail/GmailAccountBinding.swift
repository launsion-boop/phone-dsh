// SPDX-License-Identifier: MIT

import Foundation

public protocol GmailAccountBindingProviding: Sendable {
    func isBound(principal: String, account: String) -> Bool
}

public final class GmailAccountBindingStore: GmailAccountBindingProviding, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, key: String = "personalAgent.gmailAccountBindings.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func bind(principal: String, account: String) throws {
        let owner = principal.trimmingCharacters(in: .whitespacesAndNewlines)
        let providerAccount = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !owner.isEmpty, !providerAccount.isEmpty else { throw GmailError.invalidArguments("账号绑定为空") }
        lock.lock()
        defer { lock.unlock() }
        var bindings = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        if let existing = bindings[providerAccount], existing != owner {
            throw GmailError.permissionDenied("Gmail 账号已绑定到其他本地用户")
        }
        bindings[providerAccount] = owner
        defaults.set(bindings, forKey: key)
        guard defaults.synchronize() else { throw GmailError.invalidState }
    }

    public func isBound(principal: String, account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let bindings = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        return bindings[account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] == principal
    }
}
