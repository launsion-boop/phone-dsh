// SPDX-License-Identifier: MIT
// The TonoLink phone-control panel (device-panel.md §4.3, tonolink-board.md §4.4): hardware
// readiness, and the one input the owner gives, the lock-screen passcode. Saving it is the
// consent to type it when the mirrored screen shows the passcode page.
import PhoneDSHBLE
import SwiftUI

struct TonoLinkPhoneControlSection: View {
    @State private var problems: [String]?
    @ObservedObject private var store = TonoLinkUnlockStore.shared
    @State private var draft = ""
    @State private var message = ""

    /// A TonoLink board advertises itself as PhoneAgent-xxxx.
    static func applies(to deviceName: String?) -> Bool { deviceName?.hasPrefix("PhoneAgent") == true }

    var body: some View {
        Section {
            if let problems {
                if problems.isEmpty {
                    Label("手机控制：就绪", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                ForEach(problems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            } else {
                Label("检查中…", systemImage: "hourglass")
            }
            if store.hasPasscode {
                HStack {
                    Label("锁屏自动解锁：已开启", systemImage: "lock.open")
                    Spacer()
                    Button("清除密码", role: .destructive) { store.clear(); message = "已清除，自动解锁已关闭" }
                        .buttonStyle(.borderless)
                }
            } else {
                SecureField("锁屏密码（4–10 位数字），保存后自动解锁", text: $draft)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("tonolinkUnlock.passcode")
                Button("保存密码") {
                    message = store.save(draft) ? "已保存，屏幕上出现密码页时会自动输入" : "没有保存：只支持 4–10 位数字密码"
                    draft = ""
                }
                .disabled(!TonoLinkUnlock.isValidPasscode(draft))
            }
            if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
        } header: {
            Text("手机控制")
        } footer: {
            Text(store.hasPasscode
                 ? "手机任务开始时，如果镜像画面上是锁屏密码页，会通过板子的键盘输入密码。密码只存在这台手机的钥匙串里，不会显示；一天失败 \(TonoLinkUnlockStore.maxFailuresPerDay) 次后暂停。"
                 : "没有保存密码时，运行手机任务前请先解锁手机。")
        }
        .task { await check() }
    }

    /// What stops the agent from controlling the phone right now, in the owner's words.
    private func check() async {
        var found: [String] = []
        let hands = IPhoneAgentHost.shared.hands
        if let status = try? await hands.phoneStatus() {
            let hid = status["hid"] as? [String: Any]
            if hid?["keyboard"] as? Bool != true || hid?["absolute"] as? Bool != true {
                found.append("板子的键盘鼠标还没接上：在 设置 → 蓝牙 里连接 PhoneAgent")
            }
            if (status["airplay"] as? [String: Any])?["mirror_active"] as? Bool != true,
               hands.layout.mirrorRouteLearned != true {
                found.append("还没有投屏过：在控制中心 → 屏幕镜像里选一次 TonoLink USB，之后会自动投屏")
            }
        } else {
            found.append("连不上板子的 USB：确认板子插在手机上，并在 设置 → 触控 ID 与密码 → 锁定时允许访问 里打开「配件」")
        }
        problems = found
    }
}
