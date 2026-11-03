// SPDX-License-Identifier: MIT

import SwiftUI

struct ProfileGeneralSettingsPage: View {
    @State private var preferences = NativeChatPreferences.shared

    var body: some View {
        List {
            Section(NativeText("外观与语言", "Appearance and language")) {
                Picker(selection: Binding(get: { preferences.appearance },
                                          set: { preferences.setAppearance($0) })) {
                    Text(NativeText("跟随系统", "System")).tag(NativeAppearance.system)
                    Text(NativeText("浅色", "Light")).tag(NativeAppearance.light)
                    Text(NativeText("深色", "Dark")).tag(NativeAppearance.dark)
                } label: {
                    SettingsRowLabel(title: NativeText("外观", "Appearance"), icon: "circle.lefthalf.filled")
                }
                Picker(selection: Binding(get: { preferences.language },
                                          set: { preferences.setLanguage($0) })) {
                    Text(NativeText("跟随系统", "System")).tag(NativeLocalePreference.system)
                    Text("中文").tag(NativeLocalePreference.zh)
                    Text("English").tag(NativeLocalePreference.en)
                } label: {
                    SettingsRowLabel(title: NativeText("语言", "Language"), icon: "globe")
                }
                NavigationLink {
                    makeFontSizeSettingsView()
                } label: {
                    SettingsRowLabel(title: NativeText("字号", "Text size"), icon: "textformat.size")
                }
            }
            Section(NativeText("工作过程", "Work details")) {
                NavigationLink {
                    makeConversationSettingsView()
                } label: {
                    SettingsRowLabel(title: NativeText("工作过程", "Work details"), icon: "list.bullet.rectangle")
                }
                NavigationLink {
                    NativeShortcutsPage()
                } label: {
                    SettingsRowLabel(title: NativeText("快捷键", "Shortcuts"), icon: "command")
                }
            }
        }
        .homeGroupedList()
        .navigationTitle(NativeText("通用设置", "General settings"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("profile.general-settings")
    }
}
