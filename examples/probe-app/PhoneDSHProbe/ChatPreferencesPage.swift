// SPDX-License-Identifier: MIT
// Native chat appearance preferences: the phone-sized typography and
// collapse controls the PR9 baseline exposed in Settings.

import SwiftUI

struct ChatPreferencesPage: View {
    @State private var preferences = NativeChatPreferences.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Picker("外观", selection: Binding(
                    get: { preferences.appearance },
                    set: { preferences.setAppearance($0) }
                )) {
                    Text("跟随系统").tag(NativeAppearance.system)
                    Text("浅色").tag(NativeAppearance.light)
                    Text("深色").tag(NativeAppearance.dark)
                }
            } header: {
                Text("外观")
            } footer: {
                Text("深色仍在适配中；默认浅色与官方 402pt 基线一致。")
            }

            Section {
                Stepper(value: Binding(
                    get: { preferences.textFontSize },
                    set: { preferences.setFontSize(.text, $0) }
                ), in: NativeFontRole.text.sizeRange) {
                    LabeledContent("正文", value: "\(preferences.textFontSize)pt")
                }
                Stepper(value: Binding(
                    get: { preferences.codeFontSize },
                    set: { preferences.setFontSize(.code, $0) }
                ), in: NativeFontRole.code.sizeRange) {
                    LabeledContent("代码", value: "\(preferences.codeFontSize)pt")
                }
            } header: {
                Text("字号")
            } footer: {
                Text("正文字号作用于消息正文；代码字号作用于代码块与工具详情。")
            }

            Section {
                Picker("折叠时机", selection: Binding(
                    get: { preferences.collapseTiming },
                    set: { preferences.setCollapseTiming($0) }
                )) {
                    Text("完成时").tag(NativeCollapseTiming.completion)
                    Text("下一条消息").tag(NativeCollapseTiming.nextInput)
                }
            } header: {
                Text("过程折叠")
            } footer: {
                Text("与页头 more 菜单中的选择同步。")
            }

            Section {
                Picker("转录密度", selection: Binding(
                    get: { preferences.transcriptView },
                    set: { preferences.setTranscriptView($0) }
                )) {
                    Text("紧凑").tag(NativeTranscriptViewMode.compact)
                    Text("标准").tag(NativeTranscriptViewMode.standard)
                    Text("详细").tag(NativeTranscriptViewMode.detailed)
                    Text("完整").tag(NativeTranscriptViewMode.verbose)
                }
            } header: {
                Text("转录")
            }
        }
        .homeGroupedList()
        .navigationTitle("聊天外观")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }.fontWeight(.semibold)
            }
        }
    }
}
