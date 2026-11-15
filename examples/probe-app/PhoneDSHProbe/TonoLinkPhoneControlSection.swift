// SPDX-License-Identifier: MIT
// The TonoLink mini program's 手机控制 card (device-panel.md §host section, tonolink-board.md §4.4):
// one line when the phone can be controlled, otherwise only what is missing; and the one input the
// owner gives, the lock-screen passcode. Saving it is the consent to unlock automatically.
import PhoneDSHBLE
import SwiftUI

struct TonoLinkPhoneControlSection: View {
    @ObservedObject private var store = TonoLinkUnlockStore.shared
    @State private var draft = ""
    @State private var problems: [String]?
    @State private var message = ""

    /// A TonoLink board advertises itself as PhoneAgent-xxxx.
    static func applies(to deviceName: String?) -> Bool { deviceName?.hasPrefix("PhoneAgent") == true }

    var body: some View {
        Section {
            if let problems {
                if problems.isEmpty && store.hasPasscode {
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
                    message = store.save(draft) ? "已保存，锁屏时会自动解锁" : "没有保存：只支持 4–10 位数字密码"
                    draft = ""
                }
                .disabled(!TonoLinkUnlock.isValidPasscode(draft))
            }
            if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
        } header: {
            Text("手机控制")
        } footer: {
            Text("密码只存在这台手机的钥匙串里，不会显示，也不会离开手机。每次锁屏只试一次，一天失败 \(TonoLinkUnlockStore.maxFailuresPerDay) 次后暂停。")
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
        if !store.hasPasscode { found.append("锁屏时不能自动解锁：在下面存一次锁屏密码") }
        problems = found
    }
}
