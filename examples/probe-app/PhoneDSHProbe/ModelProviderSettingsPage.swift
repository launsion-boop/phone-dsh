// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — native model/API provider configuration.
//
// The profile list and every edit are backed by PhoneModelProviderSettings:
// non-secret fields live in one UserDefaults JSON document and each API key is
// written to the device Keychain only. No key is rendered, logged, or sent to
// the Worker; the Worker receives the non-secret PDSH_MODEL_PROVIDER_JSON
// projection through the host bridge.

import PhoneDSH
import SwiftUI
import UIKit

/// Which one host this configuration sheet may restart. The native recovery
/// page and the complete Web page share the same provider document and
/// Keychain, but only one PhoneDSHHost exists at a time.
enum ModelProviderSettingsHost {
    case native
    case web
}

/// 强度的四档中文说法;认不出的那档不显示。
enum ProviderWording {
    static func effortTitle(_ raw: String) -> String {
        switch raw.lowercased() {
        case "off", "none", "minimal": return "关"
        case "low": return "低"
        case "medium", "mid": return "中"
        case "high": return "高"
        case "max", "maximum": return "最高"
        case "default", "auto": return "按模型默认"
        default: return ""
        }
    }
}

struct ModelProviderSettingsPage: View {
    var host: ModelProviderSettingsHost = .native

    @State private var model = ChatModel.shared
    @State private var web = WebHostModel.shared
    @State private var snapshot = ModelProviderSettingsSnapshot()
    @State private var keyStatuses: [String: ModelProviderAPIKeyStatus] = [:]
    @State private var errorText: String?
    @State private var notice: String?
    @State private var editingProfile: ProviderProfile?
    @State private var editingIsNew = false
    @State private var pendingDelete: ProviderProfile?

    private let settings = PhoneModelProviderSettings.shared

    var body: some View {
        List {
            profilesSection
            actionsSection
            restartSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.white)
        .navigationTitle("模型服务")
        .navigationBarTitleDisplayMode(.large)
        .task { reload() }
        .onChange(of: hostRunning) { _, _ in reload() }
        .sheet(item: $editingProfile, onDismiss: {
            reload()
        }) { profile in
            NavigationStack {
                ModelProviderEditorPage(profile: profile, isNew: editingIsNew) { saved in
                    reload()
                    notice = "已保存“\(saved.displayName)”。\(restartHint)"
                }
            }
        }
        .confirmationDialog("删除模型服务？",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { profile in
            Button("删除 \(profile.displayName)", role: .destructive) { delete(profile) }
            Button("取消", role: .cancel) {}
        } message: { profile in
            Text("会删掉这个服务的配置,以及存在这台手机上的密钥。")
        }
    }

    private var profilesSection: some View {
        Section {
            if snapshot.profiles.isEmpty {
                ContentUnavailableView("尚未配置模型服务",
                                       systemImage: "server.rack",
                                       description: Text("添加一个模型服务并填入密钥;密钥只存在这台手机上。"))
            } else {
                ForEach(snapshot.profiles) { profile in
                    profileRow(profile)
                }
            }
        } header: {
            Text("服务")
        } footer: {
            if let errorText {
                Text(errorText).foregroundStyle(.red)
            } else {
                Text("这个选择从下一次启动本地引擎起生效。密钥不会写进配置、日志或网页。")
            }
        }
    }

    private func profileRow(_ profile: ProviderProfile) -> some View {
        Button {
            select(profile)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(profile.displayName.isEmpty ? "模型服务" : profile.displayName)
                            .font(.headline)
                        if snapshot.selected?.id == profile.id {
                            Text("默认")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.14), in: Capsule())
                        }
                    }
                    Text(profile.baseURL)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 8) {
                        Text(profile.model)
                        if let effort = profile.reasoningEffort, !effort.isEmpty {
                            Text("· \(ProviderWording.effortTitle(effort))")
                        }
                        keyBadge(for: profile)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if snapshot.selected?.id == profile.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if storedStatus(for: profile) != .unreadable {
                Button(role: .destructive) { pendingDelete = profile } label: {
                    Label("删除", systemImage: "trash")
                }
            }
            Button { edit(profile) } label: {
                Label("编辑", systemImage: "pencil")
            }
            .tint(.blue)
        }
    }

    private func storedStatus(for profile: ProviderProfile) -> ModelProviderAPIKeyStatus {
        keyStatuses[profile.id] ?? .unreadable
    }

    /// A Keychain read failure is shown as its own state, not as "no key":
    /// the user must know the page cannot tell whether a credential exists.
    private func keyBadge(for profile: ProviderProfile) -> some View {
        let status = storedStatus(for: profile)
        let text: String
        let color: Color
        switch status {
        case .present:
            text = "密钥已保存"
            color = .green
        case .missing:
            text = "未保存密钥"
            color = .orange
        case .unreadable:
            text = "读不到密钥"
            color = .orange
        }
        return HStack(spacing: 4) {
            Text("·")
            Text(text)
        }
        .foregroundStyle(color)
    }

    private var actionsSection: some View {
        Section {
            Button {
                editingIsNew = true
                editingProfile = ProviderProfile(id: "", displayName: "", baseURL: "https://api.deepseek.com/anthropic", model: "deepseek-flash")
            } label: {
                Label("添加模型服务", systemImage: "plus.circle")
            }
            if let selected = snapshot.selected {
                Button {
                    edit(selected)
                } label: {
                    Label("编辑默认服务", systemImage: "slider.horizontal.3")
                }
            }
        } footer: {
            if let notice {
                Text(notice).foregroundStyle(.green)
            }
        }
    }

    private var hostRunning: Bool {
        switch host {
        case .native: return model.isStarted
        case .web: return web.isStarted
        }
    }

    private var restartSection: some View {
        Section("生效方式") {
            Label(restartHint, systemImage: "arrow.clockwise")
                .font(.footnote)
                .foregroundStyle(hostRunning ? Color.orange : Color.secondary)
            switch host {
            case .native:
                if !model.isStarted {
                    Button("启动本地引擎") { Task { await model.start() } }
                }
            case .web:
                if web.isStarted {
                    Button("重启 Web 主机以应用配置") {
                        Task {
                            if web.state == .failed {
                                await web.start()   // serialized userReset path
                            } else {
                                await web.restartForConfigurationChange()
                            }
                        }
                    }
                } else {
                    Button("启动 Web 主机") { Task { await web.start() } }
                }
            }
        }
    }

    private var restartHint: String {
        guard hostRunning else { return "配置会在下次启动主机时生效。" }
        switch host {
        case .native:
            return "保存后需要停止并重新启动主机，新的服务和模型才会用于后续请求。"
        case .web:
            return "保存后重启本地引擎就生效;工作文件夹、会话记录都不受影响。"
        }
    }

    private func reload() {
        do {
            let loaded = try settings.load()
            snapshot = loaded
            var statuses: [String: ModelProviderAPIKeyStatus] = [:]
            for profile in loaded.profiles {
                do {
                    statuses[profile.id] = try settings.apiKeyStatus(for: profile.id)
                } catch {
                    statuses[profile.id] = .unreadable
                }
            }
            keyStatuses = statuses
            errorText = nil
        } catch {
            snapshot = ModelProviderSettingsSnapshot()
            keyStatuses = [:]
            errorText = error.localizedDescription
        }
    }

    private func edit(_ profile: ProviderProfile) {
        editingIsNew = false
        editingProfile = profile
    }

    private func select(_ profile: ProviderProfile) {
        do {
            try settings.select(id: profile.id)
            reload()
            notice = "已选择“\(profile.displayName)”。\(restartHint)"
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func delete(_ profile: ProviderProfile) {
        guard storedStatus(for: profile) != .unreadable else {
            errorText = "无法读取此设备的密钥，不能删除服务或密钥。请解锁设备后重新载入页面再试。"
            pendingDelete = nil
            return
        }
        do {
            try settings.remove(id: profile.id)
            reload()
            notice = "已删除“\(profile.displayName)”。\(restartHint)"
        } catch {
            errorText = error.localizedDescription
        }
        pendingDelete = nil
    }
}

private struct ModelProviderEditorPage: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ProviderProfile
    @State private var apiKey = ""
    @State private var removeStoredKey = false
    @State private var errorText: String?
    @State private var keyStatus: ModelProviderAPIKeyStatus
    @State private var testing = false
    @State private var testResult: String?

    let isNew: Bool
    let onSaved: (ProviderProfile) -> Void

    private let settings = PhoneModelProviderSettings.shared

    init(profile: ProviderProfile, isNew: Bool, onSaved: @escaping (ProviderProfile) -> Void) {
        _draft = State(initialValue: profile)
        // An existing profile starts as "unreadable" until the Keychain read
        // succeeds, so an early save cannot replace a key we have not seen.
        _keyStatus = State(initialValue: isNew ? .missing : .unreadable)
        self.isNew = isNew
        self.onSaved = onSaved
    }

    private var hasStoredKey: Bool { keyStatus == .present }
    private var keyIsUnreadable: Bool { keyStatus == .unreadable }

    private var keyStatusText: String {
        switch keyStatus {
        case .present: return "此设备已保存密钥"
        case .missing: return "尚未保存密钥"
        case .unreadable: return "无法读取此设备的密钥"
        }
    }

    private var keyStatusSymbol: String {
        switch keyStatus {
        case .present: return "key.fill"
        case .missing: return "key.slash"
        case .unreadable: return "exclamationmark.triangle.fill"
        }
    }

    private var keyStatusColor: Color {
        switch keyStatus {
        case .present: return .green
        case .missing: return .orange
        case .unreadable: return .red
        }
    }

    /// Tool-call reasoning levels the hosted DeepSeek adapter advertises.
    /// The empty tag keeps the provider default.
    private var efforts: [String] { ["off", "low", "high", "max"] }



    var body: some View {
        Form {
            Section {
                TextField("显示名称", text: $draft.displayName)
                    .textInputAutocapitalization(.words)
                TextField(isNew ? "标识（留空自动生成）" : "标识", text: $draft.id)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(!isNew)
                TextField("服务 URL", text: $draft.baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textContentType(.URL)
                TextField("模型名称", text: $draft.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker("推理强度", selection: Binding(
                    get: { draft.reasoningEffort ?? "" },
                    set: { draft.reasoningEffort = $0.isEmpty ? nil : $0 }
                )) {
                    Text("默认").tag("")
                    ForEach(efforts, id: \.self) { effort in
                        Text(ProviderWording.effortTitle(effort)).tag(effort)
                    }
                }
            } footer: {
                // The address selects the protocol; say which one so nobody has
                // to guess between /v1/messages and /chat/completions.
                Text(draft.baseURL.lowercased().contains("/anthropic")
                     ? "地址以 /anthropic 结尾：使用 Anthropic Messages（请求 /v1/messages，密钥走 x-api-key）。"
                     : "按 OpenAI 兼容协议请求 /chat/completions（密钥走 Authorization: Bearer）。")
            }

            Section {
                SecureField(hasStoredKey ? "输入新密钥以替换" : "API 密钥", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.password)
                HStack {
                    Label(keyStatusText, systemImage: keyStatusSymbol)
                        .font(.footnote)
                        .foregroundStyle(keyStatusColor)
                    Spacer()
                    Button("从剪贴板导入") {
                        if let value = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !value.isEmpty {
                            apiKey = value
                            removeStoredKey = false
                        }
                    }
                    .font(.footnote)
                }
                if hasStoredKey {
                    Toggle("删除已保存的密钥", isOn: $removeStoredKey)
                        .onChange(of: removeStoredKey) { _, remove in
                            if remove { apiKey = "" }
                        }
                }
                if keyIsUnreadable {
                    Label("读不到已有密钥：可直接输入新密钥覆盖。", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("密钥")
            } footer: {
                Text("密钥只存在这台手机上,手机解锁过一次之后才读得到。配置、日志、网页里都没有它。")
            }
            .onChange(of: apiKey) { _, entered in
                // A typed/imported replacement cancels a stale delete toggle.
                if !entered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    removeStoredKey = false
                }
            }

            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let testResult {
                Text(testResult)
                    .font(.footnote)
                    .foregroundStyle(testResult.contains("正常") ? Color.secondary : ChatPage.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.bar)
            }
        }
        .navigationTitle(isNew ? "添加模型服务" : "编辑模型服务")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }.leadingBarText()
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .trailingBarText()
                    .disabled(!canSave)
            }
            ToolbarItem(placement: .topBarLeading) {
                if testing {
                    ProgressView().controlSize(.small)
                } else {
                    Button("测试") { Task { await runConnectionTest() } }
                        .disabled(!canSave)
                }
            }
        }
        .task {
            guard !isNew else { return }
            do {
                keyStatus = try settings.apiKeyStatus(for: draft.id)
            } catch {
                keyStatus = .unreadable
                errorText = "无法读取此设备的密钥：\(error.localizedDescription)"
            }
        }
    }

    private var canSave: Bool {
        !draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Sends one minimal request with the key that would be saved and reports
    /// the provider's own status.
    ///
    /// The base URL decides the protocol, exactly like the host gateway: a
    /// `/anthropic` base speaks Anthropic Messages (`{base}[/v1]/messages`,
    /// `x-api-key`), anything else speaks OpenAI-compatible chat
    /// (`{base}/chat/completions`, `Bearer`). Testing `/chat/completions`
    /// against the default DeepSeek Anthropic endpoint would 404 even with a
    /// perfectly good key.
    private func runConnectionTest() async {
        testing = true
        testResult = nil
        defer { testing = false }
        let key: String
        do {
            if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let stored = try settings.apiKey(for: draft.id), !stored.isEmpty {
                key = stored
            } else {
                testResult = "还没有保存密钥。"
                return
            }
        } catch {
            testResult = "读不到已保存的密钥：\(error.localizedDescription)"
            return
        }
        var base = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.contains("://") { base = "https://" + base }
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else {
            testResult = "接口地址是空的。"
            return
        }
        let model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        // The profile's own hint first, the other protocol second: a 404 means
        // "wrong path", not "wrong key", and must not be reported as such.
        let anthropic = base.lowercased().contains("/anthropic")
        let attempts: [ProviderProtocol] = anthropic ? [.anthropic, .openAI] : [.openAI, .anthropic]
        var lastFailure: String?
        for proto in attempts {
            switch await probe(proto, base: base, model: model, key: key) {
            case .success(let status, let path):
                testResult = "连接正常（HTTP \(status)，\(proto.title)，\(path)）。密钥可用。"
                return
            case .authRejected(let status, _):
                // A credential answer is final for this key: try nothing else.
                testResult = "密钥被拒绝（HTTP \(status)，\(proto.title)）。确认密钥与“\(draft.baseURL)”属于同一个平台。"
                return
            case .rateLimited(let status, _):
                testResult = "请求太频繁（HTTP \(status)），密钥本身是有效的。"
                return
            case .notFound:
                lastFailure = "\(proto.title) 路径不存在（HTTP 404）"
            case .other(let status, let body, _):
                lastFailure = "HTTP \(status)：\(body)"
            case .unreachable(let message):
                testResult = "连不上：\(message)"
                return
            }
        }
        testResult = "测试失败：\(lastFailure ?? "没有可用协议")。检查接口地址与模型名“\(model)”。"
    }

    private enum ProviderProtocol {
        case anthropic
        case openAI

        var title: String { self == .anthropic ? "Anthropic Messages" : "OpenAI 兼容" }
    }

    private enum ProbeOutcome {
        case success(Int, String)
        case authRejected(Int, String)
        case rateLimited(Int, String)
        case notFound
        case other(Int, String, String)
        case unreachable(String)
    }

    private func probe(_ proto: ProviderProtocol, base: String, model: String, key: String) async -> ProbeOutcome {
        let path: String
        switch proto {
        case .anthropic:
            // Anthropic places resources below base[/v1]; the version segment
            // is not duplicated when the base already ends with it.
            let root = base.hasSuffix("/v1") ? base : base + "/v1"
            path = root + "/messages"
        case .openAI:
            path = base + "/chat/completions"
        }
        guard let url = URL(string: path) else { return .unreachable("接口地址填得不对") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch proto {
        case .anthropic:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": model,
                "max_tokens": 1,
                "messages": [["role": "user", "content": "ping"]],
            ])
        case .openAI:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": model,
                "messages": [["role": "user", "content": "ping"]],
                "max_tokens": 1,
                "stream": false,
            ])
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data.prefix(400), encoding: .utf8) ?? ""
            switch status {
            case 200...299: return .success(status, path)
            case 401: return .authRejected(status, body)
            case 403: return .authRejected(status, body)
            case 404: return .notFound
            case 429: return .rateLimited(status, body)
            default: return .other(status, body, path)
            }
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    private func save() {
        var candidate = draft
        candidate.id = candidate.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.id.isEmpty { candidate.id = UUID().uuidString.lowercased() }
        candidate.displayName = candidate.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.baseURL = candidate.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.model = candidate.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if isNew { candidate.credentialRef = "provider.\(candidate.id)" }

        // When the current key cannot be read, save only the non-secret fields:
        // sending a replacement or a delete would be a blind overwrite of a
        // credential that may still exist.
        // An explicitly typed replacement is a deliberate overwrite, so it is
        // allowed even when the stored key cannot be read (the entitlement or
        // an unlock change can make it unreadable). A bare save keeps the
        // unreadable item untouched; deletion stays blocked.
        let intent: ModelProviderSecretIntent = keyIsUnreadable
            ? PhoneModelProviderSettings.secretIntent(enteredKey: apiKey,
                                                       deleteStoredKey: false)
            : PhoneModelProviderSettings.secretIntent(enteredKey: apiKey,
                                                       deleteStoredKey: removeStoredKey)
        let replacement = intent.apiKeyArgument

        do {
            // Adding is not editing: `upsert` replaces by id, which would let a
            // typed duplicate id overwrite another profile's endpoint/model and
            // reuse (or orphan) its stored Keychain account.
            let saved = isNew
                ? try settings.create(candidate, apiKey: replacement)
                : try settings.upsert(candidate, apiKey: replacement)
            if isNew { try settings.select(id: saved.id) }
            onSaved(saved)
            dismiss()
            // The running host captured its credential provider at boot; a key
            // saved now would never reach the gateway until a restart.
            Task { await ChatModel.shared.reloadModelProvider() }
        } catch {
            errorText = error.localizedDescription
        }
    }
}
