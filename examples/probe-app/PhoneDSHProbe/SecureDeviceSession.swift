// SPDX-License-Identifier: MIT
// secure-session-v2 phone UI (spec §1, §3.4, §8.2; status `target`). Compiled
// only where PDSH_ENABLE_DEVICE_TASKS is defined (the identity UI harness);
// the shipping app target does not define it, and the iOS page extractor
// ignores these regions by design. Every grant goes through
// BLEDeviceStore.grantDeviceTasks, which refuses in every package build until
// the spec's §14 acceptance is recorded (GAP-16).
#if PDSH_ENABLE_DEVICE_TASKS
import SwiftUI
import UIKit
import PhoneDSHBLE

enum SecureSessionText {
    /// §1: required on the enrollment screen.
    static let usbWarning = "安全提示：把电路板连接到电脑，会让这台电脑完全控制电路板的任务配对和密钥（可读取设备私钥、改写配对记录或刷写任意固件）。只把电路板连接到你信任的电脑。参考电路板不防篡改。"
    /// §3.1/§3.3: arm hold, indicator, confirm hold.
    static let ceremonySteps = [
        "1. 在电路板上按住配对按钮 5 秒，直到专用指示灯每秒闪烁 1 次：电路板进入配对模式，300 秒内有效。普通短按不会进入配对模式。",
        "2. 在可信电脑上运行 pdsh-enroll begin，再运行 pdsh-enroll phone eid=… phone=<下方本机指纹>。",
        "3. 把电脑显示的 pdsh-board-v1:… 令牌粘贴或输入到下方。只能来自可信电脑，不能来自蓝牙、广播、电路板标签或以前的连接。",
        "4. 在电脑上运行 pdsh-enroll commit …；指示灯变为每秒 4 次快闪后，松开按钮，在 30 秒内重新按住 3 秒确认。短按会取消本次配对。",
        "5. 电脑显示 committed，且 eid、设备指纹、手机指纹与本机显示一致后，再在本机确认。",
    ]

    static func grouped(_ hex: String) -> String {
        stride(from: 0, to: hex.count, by: 4).map { offset -> String in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: min(4, hex.count - offset))
            return String(hex[start..<end])
        }.joined(separator: " ")
    }

    static func result(_ value: BLESecureEnrollmentResult) -> String {
        switch value {
        case .ok: return "完成"
        case .syntax: return "格式无效"
        case .noPhoneKey: return "尚未生成本机密钥"
        case .phoneKeyLost: return "本机密钥丢失：只能重置本机密钥后重新配对"
        case .sameKey: return "设备指纹与本机指纹相同，已拒绝"
        case .occupied: return "该设备已有完成的配对，请先忘记"
        case .busy: return "该设备有另一个待确认的配对"
        case .state: return "当前状态不允许此操作"
        case .valueMismatch: return "eid 或指纹不一致"
        case .recordCorrupt: return "配对记录损坏"
        case .storage: return "保存失败，请重试"
        }
    }
}

/// Enrollment ceremony, phone key and record management (§3.4, §4).
@MainActor
struct SecureEnrollmentSection: View {
    @State private var coordinator = BLESecureSessionCoordinator.shared
    @State private var phoneToken = ""
    @State private var boardToken = ""
    @State private var labels: [String: String] = [:]
    @State private var result = ""
    @State private var confirmReset = false

    var body: some View {
        Section("安全任务配对（实验）") {
            Text(SecureSessionText.usbWarning)
                .font(.footnote).foregroundStyle(.red)
                .accessibilityIdentifier("secure-usb-warning")
            ForEach(SecureSessionText.ceremonySteps, id: \.self) { step in
                Text(step).font(.footnote)
            }
            keyRows
            TextField("pdsh-board-v1:<设备指纹>:<eid>", text: $boardToken, axis: .vertical)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(.caption.monospaced())
                .accessibilityIdentifier("secure-board-token")
            Button("录入电路板令牌") {
                result = SecureSessionText.result(coordinator.enterBoardToken(boardToken))
                if result == "完成" { boardToken = "" }
            }
            .disabled(boardToken.isEmpty)
            ForEach(coordinator.records()) { row in recordRows(row) }
            if !result.isEmpty { Text(result).font(.footnote) }
            Button("重置本机密钥", role: .destructive) { confirmReset = true }
                .confirmationDialog("重置后所有配对记录都会撤销，需要重新配对每块电路板。", isPresented: $confirmReset) {
                    Button("撤销全部配对并重置", role: .destructive) {
                        result = SecureSessionText.result(coordinator.resetPhoneKey())
                        phoneToken = ""
                    }
                }
        }
    }

    @ViewBuilder private var keyRows: some View {
        let info = coordinator.keyInfo()
        switch info.state {
        case .lost:
            Text("本机密钥丢失：已有配对不可用，只能重置本机密钥。").foregroundStyle(.red)
        case .unavailable:
            Text("钥匙串暂不可用（设备可能已锁定），稍后重试。").foregroundStyle(.secondary)
        case .absent, .present:
            if info.state == .present, !info.hardwareBacked {
                Text("软件密钥：此设备没有 Secure Enclave，本机密钥保存在钥匙串中且不可导出。").font(.footnote)
            }
            if phoneToken.isEmpty {
                Button(info.state == .absent ? "生成并显示本机指纹" : "显示本机指纹") {
                    switch coordinator.showPhoneToken() {
                    case .success(let token): phoneToken = token
                    case .failure(let error): result = SecureSessionText.result(error)
                    }
                }
            } else {
                let hex = String(phoneToken.dropFirst(BLESecureIdentifiers.phoneTokenPrefix.count))
                Text("本机令牌（在可信电脑的 phone= 中输入指纹）").font(.footnote)
                Text(BLESecureIdentifiers.phoneTokenPrefix + SecureSessionText.grouped(hex))
                    .font(.caption.monospaced()).textSelection(.enabled)
                    .accessibilityIdentifier("secure-phone-token")
                Button("复制本机令牌") { UIPasteboard.general.string = phoneToken }
            }
        }
    }

    @ViewBuilder private func recordRows(_ row: BLESecureSessionCoordinator.RecordRow) -> some View {
        if let record = row.record {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(row.label ?? "未命名设备") · \(stateText(record.state)) · rev \(record.rev)").font(.subheadline)
                Text(record.deviceID).font(.caption2.monospaced()).textSelection(.enabled)
                if record.state == .staged {
                    Text("确认前请核对：电路板必须已对下列完全相同的值打印 committed。").font(.footnote).foregroundStyle(.orange)
                    Text("设备指纹 \(SecureSessionText.grouped(record.device))").font(.caption2.monospaced()).textSelection(.enabled)
                    Text("手机指纹 \(SecureSessionText.grouped(record.phone))").font(.caption2.monospaced()).textSelection(.enabled)
                    Text("eid \(record.eid)").font(.caption2.monospaced()).textSelection(.enabled)
                }
                if record.state != .revoked {
                    TextField("设备名称（只用于显示）", text: Binding(get: { labels[row.device] ?? row.label ?? "" },
                                                            set: { labels[row.device] = $0 }))
                }
                HStack {
                    if record.state == .staged {
                        Button("确认配对") {
                            result = SecureSessionText.result(coordinator.confirm(device: record.device, eid: record.eid,
                                                                                    label: labels[row.device] ?? row.label ?? ""))
                        }.disabled((labels[row.device] ?? row.label ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("放弃", role: .destructive) { result = SecureSessionText.result(coordinator.abort(device: record.device)) }
                    }
                    if record.state == .committed {
                        Button("保存名称") {
                            result = SecureSessionText.result(coordinator.setLabel(device: record.device, label: labels[row.device] ?? ""))
                        }
                        Button("忘记此设备", role: .destructive) { result = SecureSessionText.result(coordinator.forget(device: record.device)) }
                    }
                }.buttonStyle(.borderless)
            }
        } else {
            VStack(alignment: .leading) {
                Text("配对记录损坏，不会被使用").foregroundStyle(.red)
                Text(row.device).font(.caption2.monospaced())
                Button("移到一旁以便重新配对") { result = SecureSessionText.result(coordinator.moveCorruptAside(device: row.device)) }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func stateText(_ state: BLESecureEnrollmentState) -> String {
        switch state { case .staged: return "待确认"; case .committed: return "已配对"; case .revoked: return "已撤销" }
    }
}

/// Per-device selection, session and grant (§8.2). Shows nothing unless a
/// committed record exists or this device is the current selection.
@MainActor
struct SecureDeviceControls: View {
    let device: BLEDeviceStore.Device
    @State private var coordinator = BLESecureSessionCoordinator.shared
    @State private var taskManager = DeviceTaskManager.shared

    var body: some View {
        let committed = coordinator.records().compactMap { row -> (String, BLESecureEnrollmentRecord)? in
            guard let r = row.record, r.state == .committed else { return nil }
            return (row.label ?? "未命名设备", r)
        }
        let selected = coordinator.selection?.peripheral == device.id ? coordinator.selection : nil
        if let selected {
            Text("安全任务设备：\(selected.label) · \(selected.deviceID)").font(.footnote)
            if !device.secureState.isEmpty { Text(device.secureState).font(.footnote) }
            if !coordinator.message.isEmpty { Text(coordinator.message).font(.footnote) }
            if device.state == "未连接" {
                Button("取消选择") { coordinator.clearSelection() }
            } else if coordinator.phase == .granted {
                Button("撤销 \(selected.label) 的派任务授权", role: .destructive) { taskManager.stopSecureBLE() }
            } else if coordinator.phase == .ready {
                // §8.2: the grant names the record label and device ID, never the peripheral name.
                Button("允许「\(selected.label)」（\(selected.deviceID)）在本次连接中向手机派任务") {
                    Task { await taskManager.startSecureBLE() }
                }
                Text("仅本次连接和前台有效；1800 秒后不再领取新任务，再过 600 秒停止回报。").font(.footnote).foregroundStyle(.secondary)
            } else if device.secureState == "安全会话服务可用" || device.secureState == "安全通道已关闭" {
                Button("建立安全会话") { Task { await coordinator.openSession() } }
            }
        } else if device.state == "未连接", !committed.isEmpty {
            Text("连接前选择这块电路板对应的配对记录（一次只连接一块）：").font(.footnote)
            ForEach(committed, id: \.1.device) { label, record in
                Button("选择「\(label)」\(record.deviceID.prefix(16))…") {
                    coordinator.select(peripheral: device.id, device: record.device)
                }
            }
        }
    }
}
#endif
