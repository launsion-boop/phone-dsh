// SPDX-License-Identifier: MIT

import SwiftUI

struct NativeSettingsDocumentPage: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model = NativeConfigurationModel.shared
    @State private var document = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NativeText("仅显示 DSH 已脱敏的设置描述与 revision；密钥和本机路径不会出现在这里。", "Redacted DSH settings and revisions only. Secrets and local paths are excluded."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
            TextEditor(text: .constant(document))
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 8)
                .disabled(true)
        }
        .navigationTitle(NativeText("配置文件", "Configuration"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ShareLink(item: document) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel(NativeText("导出脱敏配置", "Export redacted configuration"))
                    .disabled(document.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(NativeText("完成", "Done")) { dismiss() }
            }
        }
        .task {
            await model.refresh()
            document = model.settingsDocument()
        }
    }
}
