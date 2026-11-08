// SPDX-License-Identifier: MIT
import SwiftUI
import PhoneDSHDeviceTasks

/// The data displayed here are escaped claims from local files, not facts
/// established about the device or a remote execution.
struct LegacyTaskInspectionSection: View {
    @Bindable var model: LegacyTaskInspectionModel
    let language: NativeLocalePreference

    func localized(_ chinese: String, _ english: String) -> String {
        switch language {
        case .zh: return chinese
        case .en: return english
        case .system: return Locale.preferredLanguages.first?.hasPrefix("zh") == true ? chinese : english
        }
    }

    var body: some View {
        Section(localized("历史设备任务检查", "Inspect previous device tasks")) {
            Text(localized("仅本机观察，一致性未验证；设备身份和远端结果未知。这里可能同时包含蓝牙和局域网记录。", "Local observation only; consistency is unverified, and device identity and remote outcomes are unknown. Bluetooth and LAN records may both appear."))
                .font(.footnote).foregroundStyle(.secondary)
            Button(model.isInspecting ? localized("正在检查…", "Inspecting…") : localized("检查历史记录", "Inspect history")) { model.start() }
                .disabled(model.isInspecting)
                .accessibilityIdentifier("legacy-task-inspection-start")
            if model.isInspecting {
                Button(localized("取消检查", "Cancel inspection")) { model.cancel() }
                    .disabled(model.cancellationRequested)
                if model.cancellationRequested { Text(localized("正在停止检查；文件关闭后才能重试。", "Stopping; retry after the files are closed.")) }
            }
            if let result = model.result {
                if result.status == .busy {
                    Text(localized("日志正在使用，或另一次检查尚未结束；检查不完整。请稍后重试。停止任务后日志也可能继续占用到应用退出。", "The journal is in use or another inspection is still finishing. Inspection is incomplete; try again later. The journal may remain in use until the app exits, even after tasks stop."))
                        .accessibilityIdentifier("legacy-task-inspection-busy")
                } else {
                    Text(localized("本次仅为不完整的本机观察，不能证明历史来源或远端是否收到结果。", "This incomplete local observation cannot establish historical origin or whether the remote device received a result."))
                        .accessibilityIdentifier("legacy-task-inspection-incomplete")
                }
                if result.cancelled { Text(localized("检查已取消，结果不完整。", "Inspection was cancelled and is incomplete.")) }
                ForEach(Array(result.reasons.enumerated()), id: \.offset) { _, reason in
                    Text(verbatim: reasonText(reason)).font(.footnote)
                }
                ForEach(result.entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: entry.label)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: kindText(entry.kind)).font(.footnote)
                        if let claims = entry.claims {
                            Text(localized("文件自称（未经验证）", "File claims (unverified)")).font(.footnote).foregroundStyle(.secondary)
                            claim(localized("设备 ID", "Device ID"), claims.deviceID)
                            claim(localized("任务 ID", "Task ID"), claims.taskID)
                            claim(localized("阶段", "Phase"), claims.phase)
                            claim(localized("结果类型", "Outcome type"), claims.outcomeKind)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func claim(_ title: String, _ value: String?) -> some View {
        if let value {
            Text(verbatim: "\(title)：\(value)")
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func reasonText(_ reason: DeviceTaskLegacyInspection.Reason) -> String {
        switch reason {
        case .rootMissing: return localized("没有找到记录目录；这不能证明不存在旧记录。", "The record directory was not found; this does not prove there are no old records.")
        case .rootUnreadable: return localized("记录目录不可读取；检查不完整。", "The record directory is unreadable; inspection is incomplete.")
        case .rootUnsupported: return localized("记录目录不受支持；未读取该记录目录。", "The record directory is unsupported and was not read.")
        case .entryBudget: return localized("已达到条目检查预算；其余记录未检查。", "The entry budget was reached; remaining records were not inspected.")
        case .byteBudget: return localized("已达到读取预算；部分记录未检查。", "The read budget was reached; some records were not inspected.")
        case .ioError: return localized("部分条目读取失败或发生变化；检查不完整。", "Some entries could not be read or changed during inspection.")
        case .cancelled: return localized("检查已取消，尚未完成的内容未检查。", "Inspection was cancelled; unfinished entries were not inspected.")
        }
    }

    private func kindText(_ kind: DeviceTaskLegacyInspection.Entry.Kind) -> String {
        switch kind {
        case .observed: return localized("已读取并识别为 JSON；内容未验证。", "Read as JSON; contents are unverified.")
        case .unparsed: return localized("无法解析；不能据此判断记录是否损坏。", "Could not parse; this does not establish corruption.")
        case .unreadable: return localized("无法读取；原记录未修改。", "Could not read; the original record was not changed.")
        case .symlink: return localized("符号链接；未跟随。", "Symbolic link; not followed.")
        case .nonRegular: return localized("非普通文件；未作为记录读取。", "Non-regular file; not read as a record.")
        case .unexamined: return localized("未检查；原记录未修改。", "Not inspected; the original record was not changed.")
        }
    }
}
