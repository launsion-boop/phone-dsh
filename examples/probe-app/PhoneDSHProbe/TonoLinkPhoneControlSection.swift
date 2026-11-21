// SPDX-License-Identifier: MIT
// Hardware readiness for the TonoLink phone-control panel (device-panel.md §4.3).
import SwiftUI

struct TonoLinkPhoneControlSection: View {
    @State private var problems: [String]?

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
        } header: {
            Text("手机控制")
        } footer: {
            Text("运行手机任务前，请先解锁手机。")
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
