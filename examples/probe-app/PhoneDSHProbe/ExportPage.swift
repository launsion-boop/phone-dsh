// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — iOS Phase 0 probe app (PLAN W3-APP).
//
// Export page: writes the aggregated probe report JSON and shares it. Entries
// that have not been measured are absent and the section status is
// NOT_VERIFIED; nothing is filled in on the App's behalf.

import ProbeKit
import SwiftUI

struct ExportPage: View {
    @Environment(AppModel.self) private var model
    @State private var exportURL: URL?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    PageSection("报告") {
                        KeyValueLine(key: "状态", value: model.store.status)
                        KeyValueLine(key: "环境", value: model.store.environment)
                        KeyValueLine(key: "设备",
                                     value: DeviceReportStore.device().model)
                        KeyValueLine(key: "格式版本", value: "1")
                        if let exportURL {
                            KeyValueLine(key: "文件",
                                         value: exportURL.lastPathComponent)
                        } else {
                            KeyValueLine(key: "文件", value: "还没写")
                        }
                        Text("写好的文件放进仓库的验收目录,文件名用日期和设备名。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button {
                                write()
                            } label: {
                                Label("写报告", systemImage: "square.and.arrow.down")
                            }
                            .buttonStyle(.borderedProminent)
                            if let exportURL {
                                ShareLink(item: exportURL) {
                                    Label("分享文件", systemImage: "square.and.arrow.up")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        if let errorText {
                            Text(errorText)
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }
                    PageSection("预览") {
                        Text(preview)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
            .navigationTitle("导出诊断")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                model.refreshLockdown()
                write()
            }
        }
    }

    private var preview: String {
        let text = model.exportPreview()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let head = lines.prefix(80).joined(separator: "\n")
        return head + (lines.count > 80 ? "\n… 还有 \(lines.count - 80) 行" : "")
    }

    private func write() {
        exportURL = model.writeExport()
        errorText = nil
    }
}
