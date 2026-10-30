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

enum ProviderWording {
    static func effortTitle(_ raw: String) -> String {
        switch raw.lowercased() {
        case "off", "none", "minimal": return NativeText("关", "Off")
        case "low": return NativeText("低", "Low")
        case "medium", "mid": return NativeText("中", "Medium")
        case "high": return NativeText("高", "High")
        case "max", "maximum": return NativeText("最高", "Max")
        case "default", "auto": return NativeText("按模型默认", "Model default")
        default: return ""
        }
    }
}

struct ModelProviderSettingsPage: View {
    @State private var model = ChatModel.shared
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
        .navigationTitle(NativeText("模型服务", "Model Providers"))
        .navigationBarTitleDisplayMode(.large)
        .task { reload() }
        .onChange(of: hostRunning) { _, _ in reload() }
        .sheet(item: $editingProfile, onDismiss: {
            reload()
        }) { profile in
            NavigationStack {
                ModelProviderEditorPage(profile: profile, isNew: editingIsNew) { saved in
                    reload()
                    notice = String(format: NativeText("已保存“%@”。%@", "Saved “%@”. %@"), saved.displayName, restartHint)
                }
            }
        }
        .confirmationDialog(NativeText("删除模型服务？", "Delete Model Provider?"),
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { profile in
            Button(String(format: NativeText("删除 %@", "Delete %@"), profile.displayName), role: .destructive) { delete(profile) }
            Button(NativeText("取消", "Cancel"), role: .cancel) {}
        } message: { profile in
            Text(NativeText("会删掉这个服务的配置,以及存在这台手机上的密钥。", "This deletes the provider configuration and the key stored on this phone."))
        }
    }

    private var profilesSection: some View {
        Section {
            if snapshot.profiles.isEmpty {
                ContentUnavailableView(NativeText("尚未配置模型服务", "No Model Providers"),
                                       systemImage: "server.rack",
                                       description: Text(NativeText("添加一个模型服务并填入密钥;密钥只存在这台手机上。", "Add a model provider and its key. The key is stored only on this phone.")))
            } else {
                ForEach(snapshot.profiles) { profile in
                    profileRow(profile)
                }
            }
        } header: {
            Text(NativeText("服务", "Providers"))
        } footer: {
            if let errorText {
                Text(errorText).foregroundStyle(.red)
            } else {
                Text(NativeText("这个选择从下一次启动本地引擎起生效。密钥不会写进配置、日志或网页。", "This selection takes effect the next time the local engine starts. Keys are never written to configuration, logs or web pages."))
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
                        Text(profile.displayName.isEmpty ? NativeText("模型服务", "Model Provider") : profile.displayName)
                            .font(.headline)
                        if snapshot.selected?.id == profile.id {
                            Text(NativeText("默认", "Default"))
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
                    Label(NativeText("删除", "Delete"), systemImage: "trash")
                }
            }
            Button { edit(profile) } label: {
                Label(NativeText("编辑", "Edit"), systemImage: "pencil")
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
            text = NativeText("密钥已保存", "Key saved")
            color = .green
        case .missing:
            text = NativeText("未保存密钥", "No key saved")
            color = .orange
        case .unreadable:
            text = NativeText("读不到密钥", "Key unavailable")
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
                Label(NativeText("添加模型服务", "Add Model Provider"), systemImage: "plus.circle")
            }
            if let selected = snapshot.selected {
                Button {
                    edit(selected)
                } label: {
                    Label(NativeText("编辑默认服务", "Edit Default Provider"), systemImage: "slider.horizontal.3")
                }
            }
        } footer: {
            if let notice {
                Text(notice).foregroundStyle(.green)
            }
        }
    }

    private var hostRunning: Bool { model.isStarted }

    private var restartSection: some View {
        Section(NativeText("生效方式", "When Changes Apply")) {
            Label(restartHint, systemImage: "arrow.clockwise")
                .font(.footnote)
                .foregroundStyle(hostRunning ? Color.orange : Color.secondary)
            if !model.isStarted {
                Button(NativeText("启动本地引擎", "Start Local Engine")) { Task { await model.start() } }
            }
        }
    }

    private var restartHint: String {
        guard hostRunning else { return NativeText("配置会在下次启动主机时生效。", "The configuration takes effect the next time the host starts.") }
        return NativeText("保存后需要停止并重新启动主机，新的服务和模型才会用于后续请求。", "After saving, stop and restart the host so subsequent requests use the new provider and model.")
    }

    private func reload() {
        defer { model.refreshModelProviderReadiness() }
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
            notice = String(format: NativeText("已选择“%@”。%@", "Selected “%@”. %@"), profile.displayName, restartHint)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func delete(_ profile: ProviderProfile) {
        guard storedStatus(for: profile) != .unreadable else {
            errorText = NativeText("无法读取此设备的密钥，不能删除服务或密钥。请解锁设备后重新载入页面再试。", "The key on this device could not be read, so the provider and its key cannot be deleted. Unlock the device, reload this page, and try again.")
            pendingDelete = nil
            return
        }
        do {
            try settings.remove(id: profile.id)
            reload()
            notice = String(format: NativeText("已删除“%@”。%@", "Deleted “%@”. %@"), profile.displayName, restartHint)
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
    @State private var modelDrafts: [ProviderModelDefinition]

    let isNew: Bool
    let onSaved: (ProviderProfile) -> Void

    private let settings = PhoneModelProviderSettings.shared

    init(profile: ProviderProfile, isNew: Bool, onSaved: @escaping (ProviderProfile) -> Void) {
        _draft = State(initialValue: profile)
        _modelDrafts = State(initialValue: profile.modelDefinitions)
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
        case .present: return NativeText("此设备已保存密钥", "A key is saved on this device")
        case .missing: return NativeText("尚未保存密钥", "No key has been saved")
        case .unreadable: return NativeText("无法读取此设备的密钥", "The key on this device could not be read")
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
                TextField(NativeText("显示名称", "Display name"), text: $draft.displayName)
                    .textInputAutocapitalization(.words)
                TextField(isNew ? NativeText("标识（留空自动生成）", "Identifier (generated if empty)") : NativeText("标识", "Identifier"), text: $draft.id)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(!isNew)
                TextField(NativeText("服务 URL", "Service URL"), text: $draft.baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textContentType(.URL)
                Picker(NativeText("默认模型", "Default model"), selection: $draft.model) {
                    ForEach(modelDrafts, id: \.id) { model in
                        Text(model.id).tag(model.id)
                    }
                }
                Picker(NativeText("推理强度", "Reasoning effort"), selection: Binding(
                    get: { draft.reasoningEffort ?? "" },
                    set: { draft.reasoningEffort = $0.isEmpty ? nil : $0 }
                )) {
                    Text(NativeText("默认", "Default")).tag("")
                    ForEach(efforts, id: \.self) { effort in
                        Text(ProviderWording.effortTitle(effort)).tag(effort)
                    }
                }
            } footer: {
                // The address selects the protocol; say which one so nobody has
                // to guess between /v1/messages and /chat/completions.
                Text(draft.baseURL.lowercased().contains("/anthropic")
                     ? NativeText("地址以 /anthropic 结尾：使用 Anthropic Messages（请求 /v1/messages，密钥走 x-api-key）。", "The /anthropic suffix selects Anthropic Messages (requests /v1/messages, key sent as x-api-key).")
                     : NativeText("按 OpenAI 兼容协议请求 /chat/completions（密钥走 Authorization: Bearer）。", "Uses the OpenAI-compatible /chat/completions endpoint (key sent as Authorization: Bearer)."))
            }

            Section(NativeText("模型目录", "Model Catalog")) {
                ForEach(modelDrafts.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 8) {
                        TextField(NativeText("模型 ID", "Model ID"), text: $modelDrafts[index].id)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField(NativeText("显示名称（可选）", "Display name (optional)"), text: optionalTextBinding(index, \.name))
                        HStack {
                            TextField(NativeText("上下文窗口", "Context window"), text: optionalIntBinding(index, \.contextWindow))
                                .keyboardType(.numberPad)
                            TextField(NativeText("最大输出 Token", "Maximum output tokens"), text: optionalIntBinding(index, \.maxTokens))
                                .keyboardType(.numberPad)
                        }
                        TextField(NativeText("推理档位（可留空）", "Reasoning effort (optional)"), text: optionalTextBinding(index, \.reasoningEffort))
                        Toggle(NativeText("文本输入", "Text input"), isOn: $modelDrafts[index].textInput)
                        Toggle(NativeText("图片输入", "Image input"), isOn: $modelDrafts[index].imageInput)
                        Button(NativeText("删除此模型", "Delete This Model"), role: .destructive) {
                            modelDrafts.remove(at: index)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Button(NativeText("添加模型", "Add Model")) {
                    modelDrafts.append(ProviderModelDefinition(id: ""))
                }
            }

            Section {
                SecureField(hasStoredKey ? NativeText("输入新密钥以替换", "Enter a new key to replace it") : NativeText("API 密钥", "API key"), text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.password)
                HStack {
                    Label(keyStatusText, systemImage: keyStatusSymbol)
                        .font(.footnote)
                        .foregroundStyle(keyStatusColor)
                    Spacer()
                    Button(NativeText("从剪贴板导入", "Import from Clipboard")) {
                        if let value = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !value.isEmpty {
                            apiKey = value
                            removeStoredKey = false
                        }
                    }
                    .font(.footnote)
                }
                if hasStoredKey {
                    Toggle(NativeText("删除已保存的密钥", "Delete saved key"), isOn: $removeStoredKey)
                        .onChange(of: removeStoredKey) { _, remove in
                            if remove { apiKey = "" }
                        }
                }
                if keyIsUnreadable {
                    Label(NativeText("读不到已有密钥：可直接输入新密钥覆盖。", "The existing key could not be read. Enter a new key to replace it."), systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text(NativeText("密钥", "API Key"))
            } footer: {
                Text(NativeText("密钥只存在这台手机上,手机解锁过一次之后才读得到。配置、日志、网页里都没有它。", "The key is stored only on this phone and can be read after the phone has been unlocked once. It never appears in configuration, logs or web pages."))
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
                    .foregroundStyle(testResult.hasPrefix(NativeText("连接正常", "Connected")) ? Color.secondary : ChatPage.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.bar)
            }
        }
        .navigationTitle(isNew ? NativeText("添加模型服务", "Add Model Provider") : NativeText("编辑模型服务", "Edit Model Provider"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NativeText("取消", "Cancel")) { dismiss() }.leadingBarText()
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(NativeText("保存", "Save")) { save() }
                    .trailingBarText()
                    .disabled(!canSave)
            }
            ToolbarItem(placement: .topBarLeading) {
                if testing {
                    ProgressView().controlSize(.small)
                } else {
                    Button(NativeText("测试", "Test")) { Task { await runConnectionTest() } }
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
                errorText = String(format: NativeText("无法读取此设备的密钥：%@", "Could not read the key on this device: %@"), error.localizedDescription)
            }
        }
    }

    private var modelValidationError: String? {
        if modelDrafts.isEmpty { return NativeText("至少添加一个模型", "Add at least one model") }
        let ids = modelDrafts.map { $0.id.trimmingCharacters(in: .whitespacesAndNewlines) }
        if ids.contains(where: { $0.isEmpty }) { return NativeText("模型 ID 不能为空", "Model IDs cannot be empty") }
        if Set(ids).count != ids.count { return NativeText("模型 ID 不能重复", "Model IDs must be unique") }
        if modelDrafts.contains(where: { !$0.textInput && !$0.imageInput }) {
            return NativeText("每个模型至少保留文本或图片一种输入类型", "Each model must support text or image input")
        }
        if modelDrafts.contains(where: {
            ($0.contextWindow != nil && $0.contextWindow! <= 0)
                || ($0.maxTokens != nil && $0.maxTokens! <= 0)
        }) {
            return NativeText("上下文窗口和最大输出必须是正整数", "Context window and maximum output must be positive integers")
        }
        return nil
    }

    private var canSave: Bool {
        !draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && modelValidationError == nil
    }

    private func optionalIntBinding(_ index: Int,
                                    _ keyPath: WritableKeyPath<ProviderModelDefinition, Int?>) -> Binding<String> {
        Binding(
            get: { modelDrafts[index][keyPath: keyPath].map(String.init) ?? "" },
            set: { modelDrafts[index][keyPath: keyPath] = $0.isEmpty ? nil : Int($0) }
        )
    }

    private func optionalTextBinding(_ index: Int,
                                     _ keyPath: WritableKeyPath<ProviderModelDefinition, String?>) -> Binding<String> {
        Binding(
            get: { modelDrafts[index][keyPath: keyPath] ?? "" },
            set: { modelDrafts[index][keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
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
                testResult = NativeText("还没有保存密钥。", "No API key has been saved.")
                return
            }
        } catch {
            testResult = String(format: NativeText("读不到已保存的密钥：%@", "Could not read the saved key: %@"), error.localizedDescription)
            return
        }
        var base = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.contains("://") { base = "https://" + base }
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else {
            testResult = NativeText("接口地址是空的。", "The service URL is empty.")
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
                testResult = String(format: NativeText("连接正常（HTTP %d，%@，%@）。密钥可用。", "Connected (HTTP %d, %@, %@). The key is valid."), status, proto.title, path)
                return
            case .authRejected(let status, _):
                // A credential answer is final for this key: try nothing else.
                testResult = String(format: NativeText("密钥被拒绝（HTTP %d，%@）。确认密钥与“%@”属于同一个平台。", "The key was rejected (HTTP %d, %@). Make sure the key and “%@” belong to the same platform."), status, proto.title, draft.baseURL)
                return
            case .rateLimited(let status, _):
                testResult = String(format: NativeText("请求太频繁（HTTP %d），密钥本身是有效的。", "Too many requests (HTTP %d). The key itself is valid."), status)
                return
            case .notFound:
                lastFailure = String(format: NativeText("%@ 路径不存在（HTTP 404）", "%@ path not found (HTTP 404)"), proto.title)
            case .other(let status, let body, _):
                lastFailure = String(format: NativeText("HTTP %d：%@", "HTTP %d: %@"), status, body)
            case .unreachable(let message):
                testResult = String(format: NativeText("连不上：%@", "Connection failed: %@"), message)
                return
            }
        }
        testResult = String(format: NativeText("测试失败：%@。检查接口地址与模型名“%@”。", "Test failed: %@. Check the service URL and model name “%@”."), lastFailure ?? NativeText("没有可用协议", "No protocol available"), model)
    }

    private enum ProviderProtocol {
        case anthropic
        case openAI

        var title: String { self == .anthropic ? "Anthropic Messages" : NativeText("OpenAI 兼容", "OpenAI-compatible") }
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
        guard let url = URL(string: path) else { return .unreachable(NativeText("接口地址填得不对", "Invalid service URL")) }
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
        guard modelValidationError == nil else {
            errorText = modelValidationError
            return
        }
        var candidate = draft
        candidate.id = candidate.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.id.isEmpty { candidate.id = UUID().uuidString.lowercased() }
        candidate.displayName = candidate.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.baseURL = candidate.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.model = candidate.model.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.models = modelDrafts.map { model in
            var copy = model
            copy.id = copy.id.trimmingCharacters(in: .whitespacesAndNewlines)
            return copy
        }
        if let models = candidate.models, !models.map(\.id).contains(candidate.model),
           let first = models.first { candidate.model = first.id }
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
