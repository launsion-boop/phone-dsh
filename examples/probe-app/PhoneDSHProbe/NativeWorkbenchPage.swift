// SPDX-License-Identifier: MIT
import SwiftUI

/// Compact presentation of DSH's right sidebar. This is scoped to the current
/// conversation rather than a top-level navigation destination.
struct NativeWorkbenchPage: View {
    let sessionID: String?
    var initialPath: String? = nil
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var section = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("工作面板", selection: $section) {
                    Text("文件").tag(0)
                    Text("命令").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
                if section == 0 {
                    FilesPage(initialPath: initialPath)
                } else {
                    PDSHShellPage()
                }
            }
            .navigationTitle("工作区")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { onClose?(); dismiss() }.leadingBarText()
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
