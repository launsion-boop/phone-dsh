// SPDX-License-Identifier: MIT

import SwiftUI

struct NativeShortcutsPage: View {
    @State private var preferences = NativeChatPreferences.shared

    var body: some View {
        List {
            Section(NativeText("应用命令", "Application commands")) {
                ForEach(NativeShortcutAction.allCases, id: \.self) { action in
                    NavigationLink { NativeShortcutEditor(action: action) } label: {
                        LabeledContent(nativeShortcutTitle(action), value: preferences.shortcut(for: action).display)
                    }
                }
            }
            Section(NativeText("固定输入操作（只读）", "Fixed input operations (read only)")) {
                LabeledContent(NativeText("换行", "New line"), value: "⇧↩")
                LabeledContent(NativeText("发送", "Send"), value: "↩")
                LabeledContent(NativeText("另一种发送行为", "Alternate send"), value: "⌘↩")
            }
            Section {
                Button(NativeText("恢复全部默认", "Reset all"), role: .destructive) {
                    preferences.resetAllShortcuts()
                }
                .disabled(preferences.shortcutOverrides.isEmpty)
            }
        }
        .navigationTitle(NativeText("快捷键", "Shortcuts"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct NativeShortcutEditor: View {
    let action: NativeShortcutAction
    @Environment(\.dismiss) private var dismiss
    @State private var draft: NativeShortcut
    @State private var conflict: NativeShortcutAction?
    private let preferences = NativeChatPreferences.shared

    init(action: NativeShortcutAction) {
        self.action = action
        _draft = State(initialValue: NativeChatPreferences.shared.shortcut(for: action))
    }

    var body: some View {
        Form {
            Section(nativeShortcutTitle(action)) {
                Picker(NativeText("按键", "Key"), selection: $draft.key) {
                    Text("return").tag("return")
                    Text("escape").tag("escape")
                    Text("downArrow").tag("downArrow")
                    Text("/").tag("/")
                    Text(",").tag(",")
                    ForEach(["a", "b", "c", "j", "k", "n"], id: \.self) { Text($0.uppercased()).tag($0) }
                }
                Toggle("⌘ Command", isOn: $draft.command)
                Toggle("⌥ Option", isOn: $draft.option)
                Toggle("⇧ Shift", isOn: $draft.shift)
                Toggle("⌃ Control", isOn: $draft.control)
            }
            Section {
                Button(NativeText("保存快捷键", "Save shortcut")) {
                    if preferences.setShortcut(draft, for: action) { dismiss() }
                    else { conflict = preferences.shortcutConflict(draft, for: action) }
                }
                Button(NativeText("恢复默认", "Reset"), role: .destructive) {
                    preferences.resetShortcut(for: action)
                    dismiss()
                }
            }
            if let conflict {
                Section {
                    Text(NativeText("与“\(nativeShortcutTitle(conflict))”冲突，请换一组按键。", "This shortcut is already used by \(nativeShortcutTitle(conflict)). Choose another one."))
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(nativeShortcutTitle(action))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private func nativeShortcutTitle(_ action: NativeShortcutAction) -> String {
    switch action {
    case .send: NativeText("发送消息", "Send message")
    case .alternate: NativeText("另一种发送行为", "Alternate send")
    case .stop: NativeText("停止当前回复", "Stop response")
    case .settings: NativeText("打开设置", "Open settings")
    case .shortcuts: NativeText("打开快捷键速查", "Show shortcuts")
    case .latest: NativeText("回到最新", "Jump to latest")
    }
}
