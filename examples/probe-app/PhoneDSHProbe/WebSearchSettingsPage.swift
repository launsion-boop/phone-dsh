// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — native independent web-search configuration.
//
// 这一页没有「保存」按钮:改完就算。提交只发生在三处——敲回车、失焦(点别处)、
// 离开这一页。提交时不禁用输入框(禁用会吞掉正在打的字),只在行尾转一个 14 的圈;
// 失焦和离开成功时,在那一行下面停两秒「已保存」;失败只写一句红字,字一改就没。
// 页面永远不显示地址原文、密钥本身和任何内部名词。

import PhoneDSH
import ProbeKit
import SwiftUI

struct WebSearchSettingsPage: View {
    @State private var model = ChatModel.shared
    @State private var snapshot = PhoneWebSearchSnapshot()
    @State private var selectedProfile: ProviderProfile?
    @State private var mode = PhoneWebSearchMode.followModel
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var errorText: String?
    @State private var feedbackRow: FeedbackRow = .address
    @State private var saving = false
    @State private var savedFlash = false
    @State private var confirmClearKey = false
    @State private var confirmRemove = false
    /// 存好之后给人看的尾巴四位(不是密钥本身,只为认出「是这一把」)。
    @State private var keyTail = ""
    @FocusState private var focus: Field?

    private enum Field { case address, key }
    private enum FeedbackRow { case address, key }
    private enum Commit { case enter, blur, leave, instant }

    private let settings = PhoneWebSearchSettings.shared

    /// 三处提交:回车、失焦、离开。enter 成功不闪「已保存」——人还在打字。
    private enum SubmitReason { case enter, blur, leave, instant }

    var body: some View {
        List {
            modeSection
            if let launchWarning {
                launchWarningSection(launchWarning)
            }
            if mode == .searchAPI {
                addressSection
                keyValueSection
                deleteSection
            }
            restartSection
            footerSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.white)
        .navigationTitle("网页搜索")
        .navigationBarTitleDisplayMode(.large)
        .task { _ = reload() }
        // 离开这一页也提交:打完字直接返回是最常见的动作,不能把字丢了。
        // 提交失败不拦返回、不弹窗,内容留在编辑器里,下次进来还是那句红字。
        .onDisappear {
            // 没按「保存」的密钥离开就丢掉——不偷偷存。
            apiKey = ""
            commit(.leave)
        }
        .alert("清除密钥?", isPresented: $confirmClearKey) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) { clearAPIKey() }
        } message: {
            Text("清除之后这台手机就用不了模型,得重新粘一遍。")
        }
        .alert("删除这个搜索服务?", isPresented: $confirmRemove) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { removeConfiguration() }
        } message: {
            Text("地址和密钥都会删掉,搜索回到用模型服务自带的那份。")
        }
    }

    // MARK: - 用哪一份搜索

    private var modeSection: some View {
        Section {
            ForEach(PhoneWebSearchMode.allCases, id: \.self) { value in
                Button {
                    guard mode != value else { return }
                    mode = value
                    // 开关和选项都是改完就算;粘了没按保存的密钥跟着丢。
                    apiKey = ""
                    commit(.instant)
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(modeTitle(value))
                                .foregroundStyle(Color(red: 0x11 / 255, green: 0x11 / 255, blue: 0x14 / 255))
                            // 每个选项自己一句,只让选中那项看得见;两句都留位置,切换时下面的地址和密钥不跳。
                            Text(modeSubtitle(value))
                                .font(.system(size: 13))
                                .foregroundStyle(Color(red: 0x66 / 255, green: 0x66 / 255, blue: 0x6B / 255))
                                .opacity(mode == value ? 1 : 0)
                        }
                        Spacer(minLength: 8)
                        if mode == value {
                            Image(systemName: "checkmark")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Color(red: 0x2F / 255, green: 0x5B / 255, blue: 0xFF / 255))
                        }
                    }
                    .frame(height: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("用哪一份搜索")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if mode == .followModel {
                    Label(followModelSupportText,
                          systemImage: followsModelSearch ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(followsModelSearch ? Color.secondary : ChatPage.warning)
                }
            }
        }
    }

    private func modeTitle(_ value: PhoneWebSearchMode) -> String {
        switch value {
        case .followModel: return "用模型服务自带的"
        case .searchAPI: return "自己填一个"
        }
    }

    // 一句一行,两句同长;切换时不改变这一栏的高度。
    private func modeSubtitle(_ value: PhoneWebSearchMode) -> String {
        switch value {
        case .followModel: return "不填地址,用那边配好的搜索。"
        case .searchAPI: return "填地址和密钥,单独连一个搜索服务。"
        }
    }

    // MARK: - 搜索服务

    private var addressSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    TextField("api.deepseek.com", text: $baseURL)
                        .keyboardType(.URL)
                        .lineLimit(1)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .address)
                        .submitLabel(.done)
                        .onSubmit { commit(.enter, row: .address) }
                        .onChange(of: focus) { previous, _ in
                            if previous == .address { commit(.blur, row: .address) }
                        }
                        .onChange(of: baseURL) { _, _ in clearProblem() }
                    if saving {
                        ProgressView().controlSize(.small)
                    }
                }
                if feedbackRow == .address, let line = feedbackLine {
                    Text(line.text)
                        .font(.system(size: 13))
                        .foregroundStyle(line.isProblem ? ChatPage.danger : SessionsPage.ink)
                }
            }
        } header: {
            Text("地址")
        } footer: {
            Text("照服务商给的那段整段粘过来就行。")
                .foregroundStyle(SessionsPage.ink)
        }
    }

    private var trimmedKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var keyValueSection: some View {
        Section {
            HStack(spacing: 8) {
                Text("密钥")
                Spacer(minLength: 8)
                Text(snapshot.hasCredential ? "存好了" : "还没存")
                    .font(.system(size: 13))
                    .foregroundStyle(snapshot.hasCredential ? SessionsPage.ink : ChatPage.warning)
                if snapshot.hasCredential, !keyTail.isEmpty {
                    Text("尾号 \(keyTail)")
                        .font(.system(size: 13))
                        .foregroundStyle(SessionsPage.ink)
                }
            }
            // 框和它的红字自成一行:红字紧贴框下 8。
            VStack(alignment: .leading, spacing: 8) {
                // 密钥是秘密:粘进来先不存,存这一步由人按下「保存」。
                SecureField("粘贴密钥", text: $apiKey)
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .key)
                    .submitLabel(.done)
                    .onChange(of: apiKey) { _, _ in clearProblem() }
                    .frame(minHeight: 44)
                if feedbackRow == .key, let line = feedbackLine {
                    Text(line.text)
                        .font(.system(size: 13))
                        .foregroundStyle(line.isProblem ? ChatPage.danger : SessionsPage.ink)
                }
            }
            // 这一页唯一要按下的动作。空着就是灰底灰字、按不动;
            // 蓝底不调淡——淡蓝和可点的蓝在同一屏里分不出来。
            Button {
                focus = nil
                commit(.instant, row: .key, key: trimmedKey)
            } label: {
                ZStack {
                    if saving, feedbackRow == .key {
                        ProgressView().controlSize(.small)
                            .tint(trimmedKey.isEmpty ? SessionsPage.ink : .white)
                    } else {
                        Text("保存")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(SaveKeyButtonStyle(enabled: !trimmedKey.isEmpty && !saving))
            .disabled(trimmedKey.isEmpty || saving)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .listRowBackground(Color.clear)
            if snapshot.hasCredential {
                Button {
                    confirmClearKey = true
                } label: {
                    Text("清除密钥")
                        .foregroundStyle(ChatPage.accent)
                        .frame(minHeight: 44, alignment: .leading)
                }
            }
        } header: {
            Text("密钥状态")
        } footer: {
            Text("这里只看得到尾巴四位,看不到密钥本身。密钥只存在这台手机上,不进配置、日志和报错。")
        }
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                confirmRemove = true
            } label: {
                Text("删除这个搜索服务")
            }
        } footer: {
            Text("只改这台手机上的设置,不会立刻联网。")
        }
    }

    // MARK: - 生效方式

    private var restartSection: some View {
        Section("什么时候生效") {
            Label(restartHint, systemImage: "arrow.clockwise")
                .font(.system(size: 13))
                .foregroundStyle(hostRunning ? ChatPage.warning : Color.secondary)
            if model.isStarted {
                Button("停止本地引擎") { Task { await model.stop() } }
                    .foregroundStyle(ChatPage.danger)
            } else {
                Button("启动本地引擎") { Task { await model.start() } }
            }
        }
    }

    private var hostRunning: Bool { model.isStarted }

    private var launchWarning: String? { model.searchLaunchWarning }

    private func launchWarningSection(_ warning: String) -> some View {
        Section {
            Label(warning, systemImage: "exclamationmark.triangle")
                .font(.system(size: 13))
                .foregroundStyle(ChatPage.warning)
            Text("重启本地引擎之后这行提示会自己消失。")
                .font(.system(size: 13))
                .foregroundStyle(SessionsPage.ink)
        } header: {
            Text("需要处理")
        }
    }

    private var followsModelSearch: Bool {
        WebSearchHostConfiguration.modelServiceSupportsMessagesSearch(selectedProfile)
    }

    private var followModelSupportText: String {
        guard let selectedProfile else {
            return "还没有设置模型服务。要么先去「模型服务」配一个,要么在这一页自己填。"
        }
        if followsModelSearch {
            return "现在这个模型服务自带搜索,可以直接用它。"
        }
        return "现在这个模型服务不带搜索。要么换一个,要么在这一页自己填。"
    }

    private var restartHint: String {
        guard hostRunning else { return "下次启动本地引擎时才生效。" }
        return "重启本地引擎之后生效;工作文件夹和会话都不变。"
    }

    private var footerSection: some View {
        Section {
            Text("用模型服务自带的搜索时,抓网页这件事也归它管,这里不再单独设。")
            Text("密钥只存在这台手机上,本地引擎拿到的只是一个占位。")
            Text("存好或删掉之后要重启本地引擎才生效;重启不会动你的文件夹和会话。")
        } header: {
            Text("还要知道")
        }
    }

    // MARK: - 提交

    /// 行下面那一句:失败是红字、不自己消失(改字才消失);「已保存」是灰字、两秒淡出。
    private var feedbackLine: (text: String, isProblem: Bool)? {
        if let errorText { return (errorText, true) }
        if savedFlash { return ("存好了", false) }
        return nil
    }

    private func clearProblem() {
        errorText = nil
        savedFlash = false
    }

    /// 两件事分开提交:地址改完就走(回车/失焦/离开),密钥只有按下「保存」才算。
    /// `key` 传进来就存它(按下去那一刻的内容),不传就只动地址,粘了一半的密钥不会被顺手存下。
    private func commit(_ reason: SubmitReason, row: FeedbackRow = .address, key explicitKey: String? = nil) {
        guard mode == .searchAPI else {
            // 跟随模型不保存地址和密钥,但模式本身必须落盘:早退会让
            // 「用模型服务自带」看起来选中了,离开页面又弹回原来的模式。
            do {
                try settings.save(mode: mode,
                                  baseURL: snapshot.configuration.baseURL,
                                  apiKey: nil)
                _ = reload()
                flashSaved()
            } catch {
                errorText = error.localizedDescription
            }
            return
        }
        var address = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // 能自动补的就不报错:粘来的常常没有开头那截。
        if !address.isEmpty, !address.contains("://") {
            address = "https://" + address
        }
        // 补上的那截要看得见:不管后面存没存上,框里立刻显示将要用到的完整地址。
        if !address.isEmpty, baseURL != address { baseURL = address }
        let key = explicitKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if explicitKey == nil, row != .key {
            // 地址这条:地址没改就什么都不做。
            guard address != snapshot.configuration.baseURL else { return }
        }
        guard !key.isEmpty || row != .key else { return }

        feedbackRow = row
        errorText = nil
        savedFlash = false
        // 静态说明只写形状,所以这三种形状在这里各给一句——一句话只说这一次的错。
        let lower = address.lowercased()
        if lower.contains("?") || lower.contains("#") || lower.contains("@") {
            errorText = "问号后面的部分不要,删掉再存。"
            return
        }
        let pathPart = lower.split(separator: "/", omittingEmptySubsequences: false).dropFirst(3).joined(separator: "/")
        if pathPart.hasSuffix("search") || pathPart.hasSuffix("fetch") {
            errorText = "地址填到域名就行,后面那段不用。"
            return
        }
        saving = true
        defer { saving = false }
        do {
            try settings.save(mode: mode,
                              baseURL: address,
                              apiKey: key.isEmpty ? nil : key)
            if !key.isEmpty { keyTail = String(key.suffix(4)) }
            apiKey = ""
            _ = reload()
            // 回车也算存上了:不闪的话,按回车的人屏幕上什么都没发生。
            // 灰字一打字就消失(clearProblem),所以不会一直挂着。
            flashSaved()
        } catch {
            // 一个字都不改:文本留着,红字只写这一句,离开也不拦。
            errorText = plainFailure(error)
        }
    }

    /// 引擎那句是给开发者看的(endpoint、query、fragment 这些词都在里面),换成人话。
    /// 一句一件事,别的错一律「再试一次」。
    private func plainFailure(_ error: Error) -> String {
        switch error {
        case PhoneWebSearchSettingsError.operationInBaseURL:
            return "地址填到域名就行,后面那段不用。"
        case PhoneWebSearchSettingsError.apiKeyRequiredForNewEndpoint:
            return "换了地址,密钥要重新粘一次。"
        case PhoneWebSearchSettingsError.invalidBaseURL:
            return "问号后面的部分不要,删掉再存。"
        default:
            return "没存上,再试一次。"
        }
    }

    private func flashSaved() {
        savedFlash = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            savedFlash = false
        }
    }

    /// Reload what is actually stored. Returns false after clearing the stale
    /// snapshot when the store itself cannot be read; a saved notice is never
    /// shown on top of an unknown/old key state.
    @discardableResult
    private func reload() -> Bool {
        do {
            let loaded = try settings.load()
            snapshot = loaded
            mode = loaded.configuration.mode
            baseURL = loaded.configuration.baseURL
            selectedProfile = (try? PhoneModelProviderSettings.shared.load().selected)
            errorText = nil
            return true
        } catch {
            snapshot = PhoneWebSearchSnapshot()
            mode = .followModel
            baseURL = ""
            errorText = WebSearchHostConfiguration.userFacingMessage(for: error)
            return false
        }
    }

    /// 清除/删除失败时:重新读存储,但把那句失败保留下来,不拿读错误顶掉。
    private func reloadAfterFailure(_ failure: Error) {
        let message = WebSearchHostConfiguration.userFacingMessage(for: failure)
        do {
            let loaded = try settings.load()
            snapshot = loaded
            mode = loaded.configuration.mode
            baseURL = loaded.configuration.baseURL
            selectedProfile = (try? PhoneModelProviderSettings.shared.load().selected)
        } catch {
            snapshot = PhoneWebSearchSnapshot()
            selectedProfile = (try? PhoneModelProviderSettings.shared.load().selected)
        }
        errorText = message
        feedbackRow = .key
    }

    private func clearAPIKey() {
        do {
            try settings.clearAPIKey()
            keyTail = ""
            guard reload() else { return }
            flashSaved()
        } catch {
            reloadAfterFailure(error)
        }
    }

    private func removeConfiguration() {
        do {
            try settings.remove()
            apiKey = ""
            keyTail = ""
            guard reload() else { return }
            flashSaved()
        } catch {
            reloadAfterFailure(error)
        }
    }
}

/// 这一页唯一的主按钮:蓝底白字可按,灰底灰字按不动。圆角 12、高 50。
private struct SaveKeyButtonStyle: ButtonStyle {
    var enabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(enabled
                             ? Color.white
                             : Color(red: 0x8A / 255, green: 0x8A / 255, blue: 0x90 / 255))
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(enabled
                          ? Color(red: 0x2F / 255, green: 0x5B / 255, blue: 0xFF / 255)
                          : Color(red: 0xE5 / 255, green: 0xE5 / 255, blue: 0xEA / 255))
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}
