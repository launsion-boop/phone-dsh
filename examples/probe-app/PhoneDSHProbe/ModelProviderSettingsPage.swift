// SPDX-License-Identifier: MIT
// PHONE-ONLY: model-provider settings belong to the phone backend in v1
// (plan v2 §6.1); they are not a PC workspace setting.
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
    /// The sheet's item carries its mode so SwiftUI cannot present a new profile
    /// using an independently captured, stale edit flag.
    private enum EditorSheet: Identifiable {
        case add
        case edit(ProviderProfile)

        var id: String {
            switch self {
            case .add: "add"
            case .edit(let profile): "edit:\(profile.id)"
            }
        }

        var profile: ProviderProfile {
            switch self {
            case .add:
                ProviderProfile(id: "", displayName: "", baseURL: "https://api.deepseek.com/anthropic", model: "deepseek-flash")
            case .edit(let profile): profile
            }
        }

        var isNew: Bool {
            if case .add = self { return true }
            return false
        }
    }

    @State private var model = ChatModel.shared
    @State private var snapshot = ModelProviderSettingsSnapshot()
    @State private var keyStatuses: [String: ModelProviderAPIKeyStatus] = [:]
    @State private var errorText: String?
    @State private var notice: String?
    @State private var editorSheet: EditorSheet?
    @State private var pendingDelete: ProviderProfile?

    private let settings = PhoneModelProviderSettings.shared

    var body: some View {
        List {
            profilesSection
            actionsSection
            restartSection
        }
        .homeGroupedList()
        .navigationTitle(NativeText("模型服务", "Model Providers"))
        .navigationBarTitleDisplayMode(.inline)
        .task { reload() }
        .onChange(of: hostRunning) { _, _ in reload() }
        .sheet(item: $editorSheet, onDismiss: {
            reload()
        }) { editor in
            NavigationStack {
                ModelProviderEditorPage(profile: editor.profile, isNew: editor.isNew) { saved in
                    reload()
                    notice = String(format: NativeText("已保存“%@”。%@", "Saved “%@”. %@"), saved.displayName, restartHint)
                }
            }
            .homeSheetChrome()
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

    /// One provider: 16pt semibold name with a 默认 tag, the URL and the
    /// model / key state in 13pt gray, a check on the default one.
    private func profileRow(_ profile: ProviderProfile) -> some View {
        Button {
            select(profile)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(profile.displayName.isEmpty ? NativeText("模型服务", "Model Provider") : profile.displayName)
                            .font(.system(size: HomeSpec.bodySize, weight: .semibold))
                            .foregroundStyle(HomeSpec.textPrimary)
                            .lineLimit(1)
                        if snapshot.selected?.id == profile.id {
                            HomeTag(text: NativeText("默认", "Default"))
                        }
                    }
                    Text(profile.baseURL)
                        .font(.system(size: 13).monospaced())
                        .foregroundStyle(HomeSpec.textPlaceholder)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text(profile.model)
                        if let effort = profile.reasoningEffort, !effort.isEmpty {
                            Text("· \(ProviderWording.effortTitle(effort))")
                        }
                        keyBadge(for: profile)
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(HomeSpec.textPlaceholder)
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                if snapshot.selected?.id == profile.id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(HomeSpec.textPrimary)
                }
            }
            .padding(.vertical, 6)
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
            .tint(HomeSpec.textSecondary)
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
            color = HomeSpec.success
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
                editorSheet = .add
            } label: {
                SettingsRowLabel(title: NativeText("添加模型服务", "Add Model Provider"), icon: "plus")
            }
            .accessibilityIdentifier("provider.add")
            if let selected = snapshot.selected {
                Button {
                    edit(selected)
                } label: {
                    SettingsRowLabel(title: NativeText("编辑默认服务", "Edit Default Provider"), icon: "slider.horizontal.3")
                }
                .accessibilityIdentifier("provider.edit-default")
            }
        } footer: {
            if let notice {
                Text(notice)
            }
        }
    }

    private var hostRunning: Bool { model.isStarted }

    /// When changes apply: one 13pt note, plus the start button while the
    /// engine is stopped.
    private var restartSection: some View {
        Section {
            if !model.isStarted {
                Button(NativeText("启动本地引擎", "Start Local Engine")) { Task { await model.start() } }
                    .buttonStyle(HomePrimaryButtonStyle())
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        } footer: {
            Text(restartHint)
                .foregroundStyle(hostRunning ? NativeParityTokens.warning : HomeSpec.textPlaceholder)
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
        editorSheet = .edit(profile)
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

struct ModelProviderEditorPage: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ProviderProfile
    @State private var apiKey = ""
    @State private var removeStoredKey = false
    @State private var errorText: String?
    @State private var keyStatus: ModelProviderAPIKeyStatus
    @State private var testing = false
    @State private var testResult: String?
    @State private var modelDrafts: [ProviderModelDefinition]
    @State private var fetchingModels = false
    @State private var catalogStatus: String?

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
        case .present: return HomeSpec.success
        case .missing: return NativeParityTokens.warning
        case .unreadable: return ChatPage.danger
        }
    }

    /// Tool-call reasoning levels the hosted DeepSeek adapter advertises.
    /// The empty tag keeps the provider default.
    private var efforts: [String] { ["off", "low", "high", "max"] }



    var body: some View {
        Form {
            Section {
                HomeFieldRow(title: NativeText("名称", "Name")) {
                    TextField("", text: $draft.displayName, prompt: Text("例如 DeepSeek"))
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("provider.name")
                }
                HomeFieldRow(title: NativeText("密钥", "API key")) {
                    SecureField("", text: $apiKey, prompt: Text(hasStoredKey ? "已保存，输入以替换" : "粘贴或输入 API 密钥"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)
                        .accessibilityIdentifier("provider.key")
                }
                HomeFieldRow(title: NativeText("API 地址", "API URL")) {
                    TextField("", text: $draft.baseURL, prompt: Text("https://api.deepseek.com/v1"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .accessibilityIdentifier("provider.api")
                }
                Button {
                    if let value = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                        apiKey = value; removeStoredKey = false
                    }
                } label: {
                    SettingsRowLabel(title: NativeText("粘贴密钥", "Paste API key"), icon: "doc.on.clipboard")
                }
            } header: {
                Text(NativeText("连接信息", "Connection"))
            } footer: {
                Text(NativeText("填写这三项，然后获取模型。密钥仅保存在这台手机的钥匙串中。", "Enter these three fields, then fetch models. Keys stay in this phone’s Keychain."))
            }
            .onChange(of: apiKey) { _, entered in
                if !entered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { removeStoredKey = false }
            }

            Section {
                Button {
                    Task { await fetchModels() }
                } label: {
                    HStack {
                        SettingsRowLabel(title: fetchingModels ? "正在获取模型…" : "获取模型", icon: "arrow.down.circle")
                        if fetchingModels { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(fetchingModels || testing || draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("provider.fetch-models")
                if !modelDrafts.isEmpty {
                    Picker(NativeText("默认模型", "Default model"), selection: $draft.model) {
                        ForEach(modelDrafts, id: \.id) { model in
                            Text(model.name ?? model.id).tag(model.id)
                        }
                    }
                }
            } header: {
                Text(NativeText("选择模型", "Model"))
            } footer: {
                if let catalogStatus { Text(catalogStatus) }
                else { Text("获取后选择默认模型。接口不支持模型列表时，可在高级设置中手动添加。") }
            }

            Section {
                NavigationLink { advancedSettings } label: {
                    SettingsRowLabel(title: NativeText("高级设置", "Advanced settings"), icon: "slider.horizontal.3")
                }
            } footer: {
                Text("推理强度、上下文和输出长度沿用默认值。")
            }

            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 14))
                        .foregroundStyle(ChatPage.danger)
                }
            }
        }
        .homeGroupedList()
        .navigationTitle(isNew ? NativeText("添加模型服务", "Add Model Provider") : NativeText("编辑模型服务", "Edit Model Provider"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NativeText("取消", "Cancel")) { dismiss() }.leadingBarText()
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(NativeText("保存", "Save")) { save() }
                    .trailingBarText()
                    .fontWeight(.semibold)
                    .disabled(!canSave)
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

    private var advancedSettings: some View {
        Form {
            Section("服务选项") {
                HomeFieldRow(title: NativeText("标识", "Identifier")) {
                    TextField("", text: $draft.id,
                              prompt: Text(isNew ? NativeText("留空自动生成", "Generated if empty") : ""))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(!isNew)
                        .foregroundStyle(isNew ? HomeSpec.textPrimary : HomeSpec.textPlaceholder)
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
            }
            ForEach(modelDrafts.indices, id: \.self) { index in
                Section {
                    HomeFieldRow(title: NativeText("模型 ID", "Model ID")) {
                        TextField("", text: $modelDrafts[index].id, prompt: Text("deepseek-chat"))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    HomeFieldRow(title: NativeText("显示名称", "Name")) {
                        TextField("", text: optionalTextBinding(index, \.name), prompt: Text(NativeText("可选", "Optional")))
                    }
                    HomeFieldRow(title: NativeText("上下文", "Context")) {
                        TextField("", text: optionalIntBinding(index, \.contextWindow), prompt: Text(NativeText("Token 数", "Tokens")))
                            .keyboardType(.numberPad)
                    }
                    HomeFieldRow(title: NativeText("最大输出", "Max output")) {
                        TextField("", text: optionalIntBinding(index, \.maxTokens), prompt: Text(NativeText("Token 数", "Tokens")))
                            .keyboardType(.numberPad)
                    }
                    HomeFieldRow(title: NativeText("推理档位", "Effort")) {
                        TextField("", text: optionalTextBinding(index, \.reasoningEffort), prompt: Text(NativeText("可留空", "Optional")))
                            .textInputAutocapitalization(.never)
                    }
                    Toggle(NativeText("文本输入", "Text input"), isOn: $modelDrafts[index].textInput)
                    Toggle(NativeText("图片输入", "Image input"), isOn: $modelDrafts[index].imageInput)
                    Button(NativeText("删除这个模型", "Delete This Model"), role: .destructive) {
                        modelDrafts.remove(at: index)
                    }
                }
            }
            Section {
                Button {
                    modelDrafts.append(ProviderModelDefinition(id: ""))
                } label: {
                    SettingsRowLabel(title: NativeText("添加模型", "Add Model"), icon: "plus")
                }
            }

            Section {
                Label(keyStatusText, systemImage: keyStatusSymbol)
                    .foregroundStyle(keyStatusColor)
                if hasStoredKey {
                    Toggle("删除已保存的密钥", isOn: $removeStoredKey)
                        .onChange(of: removeStoredKey) { _, remove in if remove { apiKey = "" } }
                }
                Button {
                    Task { await runConnectionTest() }
                } label: {
                    HStack {
                        SettingsRowLabel(title: testing ? "正在测试…" : "测试连接", icon: "bolt.horizontal")
                        if testing { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(!canSave || testing)
            } header: {
                Text("密钥与连接")
            } footer: {
                if let testResult {
                    Text(testResult)
                        .foregroundStyle(testResult.hasPrefix(NativeText("连接正常", "Connected"))
                                         ? HomeSpec.textPlaceholder : ChatPage.danger)
                }
            }
        }
        .homeGroupedList()
        .navigationTitle("高级设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func fetchModels() async {
        guard !fetchingModels else { return }
        fetchingModels = true
        catalogStatus = nil
        defer { fetchingModels = false }
        let base = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            catalogStatus = "请输入有效的 HTTPS API 地址。"; return
        }
        let key: String
        do {
            key = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                : (try settings.apiKey(for: draft.id) ?? "")
        } catch { catalogStatus = "无法读取已保存的密钥，请解锁手机后重试。"; return }
        guard !key.isEmpty else { catalogStatus = "请先填写 API 密钥。"; return }
        do {
            var request = URLRequest(url: url.appendingPathComponent("models"))
            request.timeoutInterval = 20
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            if url.path.lowercased().contains("anthropic") {
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            }
            let session = URLSession(configuration: .ephemeral, delegate: ProviderCatalogRedirectPolicy(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var (data, response) = try await session.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 404,
               url.path.lowercased().contains("anthropic"),
               var origin = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                origin.path = "/models"
                if let catalogURL = origin.url {
                    request.url = catalogURL
                    (data, response) = try await session.data(for: request)
                }
            }
            guard let http = response as? HTTPURLResponse else { catalogStatus = "接口未返回有效响应。"; return }
            guard (200..<300).contains(http.statusCode) else {
                switch http.statusCode {
                case 401, 403: catalogStatus = "密钥未被接受，请检查密钥与 API 地址是否属于同一服务。"
                case 404, 405: catalogStatus = "此地址不支持获取模型，请检查 API 地址或在高级设置中手动添加。"
                case 429: catalogStatus = "请求过于频繁，请稍后再试。"
                default: catalogStatus = "获取模型失败（HTTP \(http.statusCode)），请稍后重试。"
                }
                return
            }
            guard data.count <= 2 * 1024 * 1024 else { catalogStatus = "模型列表过大，请在高级设置中手动添加。"; return }
            let envelope = try JSONDecoder().decode(ProviderCatalogResponse.self, from: data)
            var seen = Set<String>()
            let ids = envelope.data.map(\.id).filter { !$0.isEmpty && seen.insert($0).inserted }.sorted()
            guard !ids.isEmpty, ids.count <= 2000 else { catalogStatus = "服务未返回可用的模型列表。"; return }
            guard base == draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")) else { return }
            // Retain metadata already configured for a returned model.
            modelDrafts = ids.map { id in modelDrafts.first(where: { $0.id == id }) ?? ProviderModelDefinition(id: id) }
            if !ids.contains(draft.model) { draft.model = ids[0] }
            catalogStatus = "已获取 \(ids.count) 个模型，选择后点保存。"
        } catch {
            catalogStatus = "暂时无法获取模型，请检查网络与 API 地址，或在高级设置中手动添加。"
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

private struct ProviderCatalogResponse: Decodable {
    struct Model: Decodable { let id: String }
    let data: [Model]
}

/// Never forward a provider credential to a redirect target.
private final class ProviderCatalogRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
