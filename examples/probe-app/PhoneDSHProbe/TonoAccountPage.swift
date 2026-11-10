// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — tono 账号登录（spec/v1/tono-account.md §3 可见状态）。
//
// 手机号 + 短信验证码登录；登录后云端模型和网页搜索用这个账号的凭据，没登录时
// 继续用粘贴的密钥。页面只显示手机号尾号和需重新验证的日期，从不显示任何令牌。

import PhoneDSH
import SwiftUI

struct TonoAccountPage: View {
    @State private var state: TonoAccountState = .signedOut(notice: nil)
    @State private var phone = ""
    @State private var code = ""
    @State private var challenge: TonoAccountChallenge?
    @State private var busy = false
    @State private var errorText: String?

    private let session = TonoAccountSession.shared

    var body: some View {
        Form {
            if case .signedIn(let summary) = state {
                Section("当前账号") {
                    LabeledContent("手机号", value: summary.phoneHint.map { "尾号 \($0)" } ?? "已登录")
                    LabeledContent("需重新验证", value: summary.reverifyAt.formatted(date: .abbreviated, time: .omitted))
                }
                Section {
                    Button("退出登录", role: .destructive) { signOut() }.disabled(busy)
                } footer: {
                    Text("退出后，云端模型和网页搜索改用你在「模型服务」和「网页搜索」里粘贴的密钥。")
                }
            } else {
                Section {
                    TextField("手机号", text: $phone)
                        .keyboardType(.phonePad).textContentType(.telephoneNumber)
                    Button("获取验证码") { requestCode() }.disabled(busy)
                    if challenge != nil {
                        TextField("验证码", text: $code)
                            .keyboardType(.numberPad).textContentType(.oneTimeCode)
                        Button("登录") { signIn() }.disabled(busy)
                    }
                } header: {
                    Text("手机号登录")
                } footer: {
                    Text(statusText)
                        .foregroundStyle(errorText == nil ? Color.secondary : Color.red)
                }
            }
        }
        .navigationTitle("Tono 账号")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            for await value in await session.states() { state = value }
        }
    }

    private var statusText: String {
        if let errorText { return errorText }
        if case .signedOut(let notice?) = state {
            return notice == .reverifyRequired ? "登录已满 180 天，请重新验证手机号。" : "登录已失效，请重新登录。"
        }
        if let hint = challenge?.phoneHint { return "验证码已发送到尾号 \(hint) 的手机。" }
        return "登录后，云端模型和网页搜索按账号使用；没登录时继续用粘贴的密钥。"
    }

    private func requestCode() {
        busy = true; errorText = nil
        Task {
            defer { busy = false }
            do {
                challenge = try await session.requestCode(phone: phone)
                code = ""
                await session.clearNotice()
            } catch { errorText = error.localizedDescription }
        }
    }

    private func signIn() {
        guard let challenge else { return }
        busy = true; errorText = nil
        Task {
            defer { busy = false }
            do {
                try await session.signIn(challenge, code: code)
                // 号码和验证码只在登录这一步需要，用完就清掉。
                phone = ""; code = ""; self.challenge = nil
            } catch { errorText = error.localizedDescription }
        }
    }

    private func signOut() {
        busy = true; errorText = nil
        Task {
            defer { busy = false }
            await session.signOut()
        }
    }
}
