// SPDX-License-Identifier: MIT
// The owner's choice to let the agent unlock the phone through the TonoLink board, and the
// passcode for it (tonolink-board.md §4.4). The passcode lives only in this device's Keychain,
// readable after the first unlock since boot; it is never logged, shown or sent anywhere but the
// board's keyboard. Whether the phone is locked is read from the mirrored screen by the agent
// (IPhoneLockScreen); this file registers no device-lock notification of any kind.
import Foundation
import PhoneDSHBLE
import Security

@MainActor
final class TonoLinkUnlockStore: ObservableObject {
    static let shared = TonoLinkUnlockStore()
    static let maxFailuresPerDay = 3

    /// Saving the passcode is the owner's consent; clearing it turns automatic unlock off.
    @Published private(set) var hasPasscode: Bool
    @Published private(set) var failuresToday: Int = 0

    private let defaults: UserDefaults
    private let service: String
    private static let account = "passcode"
    private static let failuresKey = "tonolink.screen-unlock.failures"   // "yyyy-MM-dd count"

    /// A new Keychain service: a passcode saved by a build before PC-20261117 is not picked up,
    /// so automatic unlock starts only after the owner saves the passcode again.
    init(defaults: UserDefaults = .standard, service: String = "com.tono.phonedsh.tonolink-passcode") {
        self.defaults = defaults
        self.service = service
        hasPasscode = false
        hasPasscode = readPasscode() != nil
        failuresToday = Self.count(defaults.string(forKey: Self.failuresKey), on: Self.today())
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: Self.account]
    }

    /// Saves a 4–10 digit passcode; anything else is refused.
    func save(_ passcode: String) -> Bool {
        guard TonoLinkUnlock.isValidPasscode(passcode) else { return false }
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(passcode.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let ok = SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        hasPasscode = readPasscode() != nil
        if ok {   // saving again is a new consent: the day's failures start over
            defaults.removeObject(forKey: Self.failuresKey)
            failuresToday = 0
        }
        return ok
    }

    func clear() {
        SecItemDelete(query as CFDictionary)
        hasPasscode = false
    }

    /// The saved passcode, or nil (none saved, or the Keychain is unreadable before the first unlock).
    func passcode() -> String? { readPasscode() }

    private func readPasscode() -> String? {
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(read as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let text = String(data: data, encoding: .utf8), TonoLinkUnlock.isValidPasscode(text) else { return nil }
        return text
    }

    /// Why an attempt may not start now, or nil when it may. iOS itself disables the phone after
    /// repeated wrong passcodes, so a wrong saved passcode must stop well before that.
    func refusal() -> String? {
        failuresToday = Self.count(defaults.string(forKey: Self.failuresKey), on: Self.today())
        guard failuresToday >= Self.maxFailuresPerDay else { return nil }
        return "今天自动解锁已失败 \(Self.maxFailuresPerDay) 次，已暂停：请手动解锁手机，并在 TonoLink 面板里重新保存密码"
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
