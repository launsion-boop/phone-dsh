// SPDX-License-Identifier: MIT

import Foundation
import Observation
import SwiftUI
import UIKit

enum NativeAppearance: String, CaseIterable {
    case light, dark, system

    var colorScheme: ColorScheme? {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: nil
        }
    }
}

enum NativeLocalePreference: String, CaseIterable {
    case system, zh, en
}

enum NativeTranscriptViewMode: String, CaseIterable {
    case compact, standard, detailed, verbose
}

enum NativeCollapseTiming: String, CaseIterable {
    case completion, nextInput
}

enum NativePerformanceUsage: String, CaseIterable {
    case compact, detailed
}

enum NativeFontRole {
    case text, code, terminal

    var sizeRange: ClosedRange<Int> {
        switch self {
        case .text: 10...22
        case .code: 10...16
        case .terminal: 10...20
        }
    }

    var defaultSize: Int {
        switch self {
        case .text: 17
        case .code: 14
        case .terminal: 13
        }
    }
}

struct NativeShortcut: Codable, Equatable {
    var key: String
    var command = false
    var option = false
    var shift = false
    var control = false

    var identity: String {
        "\(command ? "command+" : "")\(option ? "option+" : "")\(shift ? "shift+" : "")\(control ? "control+" : "")\(key)"
    }

    var keyEquivalent: KeyEquivalent {
        switch key {
        case "return": .return
        case "escape": .escape
        case "downArrow": .downArrow
        default: KeyEquivalent(Character(key))
        }
    }

    var modifiers: EventModifiers {
        var modifiers: EventModifiers = []
        if command { modifiers.insert(.command) }
        if option { modifiers.insert(.option) }
        if shift { modifiers.insert(.shift) }
        if control { modifiers.insert(.control) }
        return modifiers
    }

    var display: String {
        let keyName = switch key {
        case "return": "↩"
        case "escape": "esc"
        case "downArrow": "↓"
        default: key.uppercased()
        }
        return "\(control ? "⌃" : "")\(option ? "⌥" : "")\(shift ? "⇧" : "")\(command ? "⌘" : "")\(keyName)"
    }
}

enum NativeShortcutAction: String, CaseIterable {
    case send, alternate, stop, settings, shortcuts, latest

    var defaultShortcut: NativeShortcut {
        switch self {
        case .send: NativeShortcut(key: "return")
        case .alternate: NativeShortcut(key: "return", command: true)
        case .stop: NativeShortcut(key: "escape")
        case .settings: NativeShortcut(key: ",", command: true)
        case .shortcuts: NativeShortcut(key: "/", command: true)
        case .latest: NativeShortcut(key: "downArrow", command: true)
        }
    }
}

@Observable
final class NativeChatPreferences {
    static let shared = NativeChatPreferences()

    private let defaults: UserDefaults
    private(set) var revision = 0

    private(set) var textFontSize = NativeFontRole.text.defaultSize
    private(set) var codeFontSize = NativeFontRole.code.defaultSize
    private(set) var terminalFontSize = NativeFontRole.terminal.defaultSize
    private(set) var textFontFamily = ""
    private(set) var codeFontFamily = ""
    private(set) var terminalFontFamily = ""
    private(set) var appearance = NativeAppearance.system
    private(set) var language = NativeLocalePreference.system
    private(set) var transcriptView = NativeTranscriptViewMode.detailed
    private(set) var collapseTiming = NativeCollapseTiming.completion
    private(set) var developerTools = true
    private(set) var performanceUsage = NativePerformanceUsage.detailed
    private(set) var busyEnterMode = "queue"
    private(set) var shortcutOverrides: [NativeShortcutAction: NativeShortcut] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        textFontSize = Self.integer(defaults, "textFontSize", fallback: textFontSize)
        codeFontSize = Self.integer(defaults, "codeFontSize", fallback: codeFontSize)
        terminalFontSize = Self.integer(defaults, "terminalFontSize", fallback: terminalFontSize)
        textFontFamily = defaults.string(forKey: "textFontFamily") ?? ""
        codeFontFamily = defaults.string(forKey: "codeFontFamily") ?? ""
        terminalFontFamily = defaults.string(forKey: "terminalFontFamily") ?? ""
        appearance = Self.enumValue(defaults, "appearance", fallback: appearance)
        language = Self.enumValue(defaults, "language", fallback: language)
        transcriptView = Self.enumValue(defaults, "transcriptView", fallback: transcriptView)
        collapseTiming = Self.enumValue(defaults, "collapseTiming", fallback: collapseTiming)
        developerTools = defaults.object(forKey: "developerTools") as? Bool ?? true
        performanceUsage = Self.enumValue(defaults, "performanceUsage", fallback: performanceUsage)
        if let saved = defaults.string(forKey: "busyEnterMode") {
            busyEnterMode = saved
        } else if let legacy = defaults.string(forKey: "phone-dsh.composer.busyEnter") {
            busyEnterMode = legacy
            defaults.set(legacy, forKey: "busyEnterMode")
        }
        if let data = defaults.data(forKey: "shortcutOverrides"),
           let decoded = try? JSONDecoder().decode([String: NativeShortcut].self, from: data) {
            shortcutOverrides = Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in
                NativeShortcutAction(rawValue: key).map { ($0, value) }
            })
        }
        setFontSize(.text, textFontSize)
        setFontSize(.code, codeFontSize)
        setFontSize(.terminal, terminalFontSize)
    }

    func setFontSize(_ role: NativeFontRole, _ value: Int) {
        let size = min(role.sizeRange.upperBound, max(role.sizeRange.lowerBound, value))
        let key = Self.sizeKey(role)
        defaults.set(size, forKey: key)
        switch role {
        case .text: textFontSize = size
        case .code: codeFontSize = size
        case .terminal: terminalFontSize = size
        }
        revision += 1
    }

    func setFontFamily(_ role: NativeFontRole, _ value: String) {
        let family = value.components(separatedBy: ",")
            .map { $0.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: ", ")
        let key = Self.familyKey(role)
        defaults.set(family, forKey: key)
        switch role {
        case .text: textFontFamily = family
        case .code: codeFontFamily = family
        case .terminal: terminalFontFamily = family
        }
        revision += 1
    }

    func setAppearance(_ value: NativeAppearance) {
        appearance = value
        defaults.set(value.rawValue, forKey: "appearance")
        revision += 1
    }

    func setLanguage(_ value: NativeLocalePreference) {
        language = value
        defaults.set(value.rawValue, forKey: "language")
        revision += 1
    }

    func setTranscriptView(_ value: NativeTranscriptViewMode) {
        transcriptView = value
        defaults.set(value.rawValue, forKey: "transcriptView")
        revision += 1
    }

    func setCollapseTiming(_ value: NativeCollapseTiming) {
        collapseTiming = value
        defaults.set(value.rawValue, forKey: "collapseTiming")
        revision += 1
    }

    func setDeveloperTools(_ value: Bool) {
        developerTools = value
        defaults.set(value, forKey: "developerTools")
        revision += 1
    }

    func setPerformanceUsage(_ value: NativePerformanceUsage) {
        performanceUsage = value
        defaults.set(value.rawValue, forKey: "performanceUsage")
        revision += 1
    }

    func setBusyEnterMode(_ value: String) {
        guard value == "queue" || value == "steer" else { return }
        busyEnterMode = value
        defaults.set(value, forKey: "busyEnterMode")
        revision += 1
    }

    func font(for role: NativeFontRole) -> Font {
        let size = CGFloat(fontSize(for: role))
        let family = fontFamily(for: role)
        if !family.isEmpty { return .custom(family, size: size) }
        return .system(size: size, design: role == .text ? .default : .monospaced)
    }

    func fontSize(for role: NativeFontRole) -> Int {
        switch role {
        case .text: textFontSize
        case .code: codeFontSize
        case .terminal: terminalFontSize
        }
    }

    func fontFamily(for role: NativeFontRole) -> String {
        switch role {
        case .text: textFontFamily
        case .code: codeFontFamily
        case .terminal: terminalFontFamily
        }
    }

    func fontFamilyError(for role: NativeFontRole) -> String? {
        let family = fontFamily(for: role)
        guard !family.isEmpty else { return nil }
        let installed = Set(UIFont.familyNames.map { $0.lowercased() })
        let first = family.split(separator: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
        return installed.contains(first.lowercased()) ? nil : first
    }

    func shortcut(for action: NativeShortcutAction) -> NativeShortcut {
        shortcutOverrides[action] ?? action.defaultShortcut
    }

    func shortcutConflict(_ shortcut: NativeShortcut, for action: NativeShortcutAction) -> NativeShortcutAction? {
        NativeShortcutAction.allCases.first { other in
            other != action && self.shortcut(for: other).identity == shortcut.identity
        }
    }

    func setShortcut(_ shortcut: NativeShortcut, for action: NativeShortcutAction) -> Bool {
        guard shortcutConflict(shortcut, for: action) == nil else { return false }
        shortcutOverrides[action] = shortcut
        persistShortcuts()
        return true
    }

    func resetShortcut(for action: NativeShortcutAction) {
        shortcutOverrides.removeValue(forKey: action)
        persistShortcuts()
    }

    func resetAllShortcuts() {
        shortcutOverrides.removeAll()
        persistShortcuts()
    }

    private func persistShortcuts() {
        let values = Dictionary(uniqueKeysWithValues: shortcutOverrides.map { ($0.key.rawValue, $0.value) })
        defaults.set(try? JSONEncoder().encode(values), forKey: "shortcutOverrides")
        revision += 1
    }

    private static func sizeKey(_ role: NativeFontRole) -> String {
        switch role {
        case .text: "textFontSize"
        case .code: "codeFontSize"
        case .terminal: "terminalFontSize"
        }
    }

    private static func familyKey(_ role: NativeFontRole) -> String {
        switch role {
        case .text: "textFontFamily"
        case .code: "codeFontFamily"
        case .terminal: "terminalFontFamily"
        }
    }

    private static func integer(_ defaults: UserDefaults, _ key: String, fallback: Int) -> Int {
        defaults.object(forKey: key) as? Int ?? fallback
    }

    private static func enumValue<T: RawRepresentable>(_ defaults: UserDefaults, _ key: String, fallback: T) -> T where T.RawValue == String {
        defaults.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
    }
}

func NativeText(_ chinese: String, _ english: String) -> String {
    switch NativeChatPreferences.shared.language {
    case .zh: return chinese
    case .en: return english
    case .system:
        if Locale.preferredLanguages.first?.hasPrefix("zh") == true { return chinese }
        return english
    }
}

extension Notification.Name {
    static let nativeChatNewInput = Notification.Name("nativeChatNewInput")
}

func nativePluginManagementMessage(_ english: String) -> String {
    NativeText("此 iPhone Worker 没有 pnpm、execa 或子进程安装环境。插件与组合包可查看，安装、启用和停用需在桌面 DSH 管理。", english)
}
