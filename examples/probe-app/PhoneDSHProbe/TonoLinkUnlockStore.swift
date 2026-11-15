// SPDX-License-Identifier: MIT
// The owner's choice to let the agent unlock the phone through the TonoLink board, and the
// passcode for it (tonolink-board.md §4.4). The passcode lives only in this device's Keychain,
// readable after the first unlock since boot; it is never logged, shown or sent anywhere but the
// board's keyboard. Attempts are limited: one per locked period, three failures a day.
import Foundation
import PhoneDSHBLE
import Security
import UIKit
import notify

/// Whether the phone is locked, from the two signals measured on the phone: SpringBoard's lock
/// state (1 within 3 s of locking, whatever 需要密码 is) and protected data (unavailable about
/// 10 s after locking with a passcode required).
@MainActor
enum PhoneLockState {
    private static var token: Int32 = {
        var token: Int32 = 0
        return notify_register_check("com.apple.springboard.lockstate", &token) == NOTIFY_STATUS_OK ? token : -1
    }()

    static var isLocked: Bool {
        if !UIApplication.shared.isProtectedDataAvailable { return true }
        guard token >= 0 else { return false }
        var state: UInt64 = 0
        return notify_get_state(token, &state) == NOTIFY_STATUS_OK && state != 0
    }
}

@MainActor
final class TonoLinkUnlockStore: ObservableObject {
    static let shared = TonoLinkUnlockStore()
    static let maxFailuresPerDay = 3

    /// Saving the passcode is the owner's consent; clearing it turns automatic unlock off.
    var enabled: Bool { hasPasscode }
    @Published private(set) var hasPasscode: Bool
    @Published private(set) var failuresToday: Int = 0
    /// Set when an attempt starts; cleared when iOS reports the phone unlocked again.
    private(set) var attemptedThisLock = false

    private let defaults: UserDefaults
    private let service: String
    private static let account = "passcode"
    private static let failuresKey = "tonolink.unlock.failures"   // "yyyy-MM-dd count"
    private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard, service: String = "com.tono.phonedsh.tonolink-unlock") {
        self.defaults = defaults
        self.service = service
        hasPasscode = false
        hasPasscode = readPasscode() != nil
        failuresToday = Self.count(defaults.string(forKey: Self.failuresKey), on: Self.today())
        observer = NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.attemptedThisLock = false }
        }
    }

    /// Saves a 4–10 digit passcode; anything else is refused.
    func save(_ passcode: String) -> Bool {
        guard TonoLinkUnlock.isValidPasscode(passcode) else { return false }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: Self.account]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(passcode.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let ok = SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        hasPasscode = readPasscode() != nil
        if ok {   // saving again is a new consent: the day's failures start over
            defaults.removeObject(forKey: Self.failuresKey)
            failuresToday = 0
            attemptedThisLock = false
        }
        return ok
    }

    func clear() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: Self.account]
        SecItemDelete(query as CFDictionary)
        hasPasscode = false
    }

    /// The saved passcode, or nil (none saved, or the Keychain is unreadable before the first unlock).
    func passcode() -> String? { readPasscode() }

    private func readPasscode() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: Self.account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let text = String(data: data, encoding: .utf8), TonoLinkUnlock.isValidPasscode(text) else { return nil }
        return text
    }

    /// Why an attempt may not start now, or nil when it may (and then it is counted as started).
    func beginAttempt() -> String? {
        failuresToday = Self.count(defaults.string(forKey: Self.failuresKey), on: Self.today())
        if failuresToday >= Self.maxFailuresPerDay {
            return "今天自动解锁已失败 \(Self.maxFailuresPerDay) 次，已暂停：请手动解锁一次手机"
        }
        if attemptedThisLock { return "这次锁屏已经自动解锁过一次没有成功：请手动解锁手机" }
        attemptedThisLock = true
        return nil
    }

    func recordFailure() {
        failuresToday = Self.count(defaults.string(forKey: Self.failuresKey), on: Self.today()) + 1
        defaults.set("\(Self.today()) \(failuresToday)", forKey: Self.failuresKey)
    }

    nonisolated static func count(_ stored: String?, on day: String) -> Int {
        guard let parts = stored?.split(separator: " "), parts.count == 2, String(parts[0]) == day else { return 0 }
        return Int(parts[1]) ?? 0
    }

    nonisolated static func today(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
