// SPDX-License-Identifier: MIT
// phone-dsh — ProbeKit web Search/Fetch host wiring.

import Foundation
import PhoneDSH
import PhoneDSHAgentCore

/// One launch decision for the Worker's web search/fetch rows.
public struct WebSearchHostLaunchPlan {
    /// Host-side credential provider: model provider, independent router or
    /// the settings module's fail-closed provider.
    public var credentialProvider: any CredentialProvider
    public var officialDeepSeekWebCredentialProvider: (any CredentialProvider)?
    /// Exact scheme/host/port rules the independent API needs in the gateway.
    public var allowedHostRules: Set<String>
    /// Non-secret `PDSH_WEB_*` / `DEEPSEEK_SEARCH_*` Worker entries.
    public var environment: [String: String]
    /// The stored mode, or nil when the document could not be read.
    public var mode: PhoneWebSearchMode?
    /// True when follow-model mode is valid for the selected model service.
    public var followsModelSearch: Bool
    /// A local, non-secret explanation for the settings page. It never
    /// contains a key or a credential reference.
    public var warning: String?

    public init(credentialProvider: any CredentialProvider,
                allowedHostRules: Set<String> = [],
                environment: [String: String] = [:],
                mode: PhoneWebSearchMode? = nil,
                followsModelSearch: Bool = false,
                warning: String? = nil,
                officialDeepSeekWebCredentialProvider: (any CredentialProvider)? = nil) {
        self.credentialProvider = credentialProvider
        self.officialDeepSeekWebCredentialProvider = officialDeepSeekWebCredentialProvider
        self.allowedHostRules = allowedHostRules
        self.environment = environment
        self.mode = mode
        self.followsModelSearch = followsModelSearch
        self.warning = warning
    }
}

/// Build and apply the web-search launch plan shared by both host surfaces.
public enum WebSearchHostConfiguration {
    /// Worker environment key the model provider projection owns.
    public static let modelSearchBaseEnvironmentKey = "DEEPSEEK_SEARCH_BASE_URL"

    /// Turn a settings failure into an explanation a phone user can act on.
    /// Raw underlying errors and document text are never part of this copy.
    public static func userFacingMessage(for error: Error) -> String {
        guard let error = error as? PhoneWebSearchSettingsError else {
            return "网页搜索配置不可用。请打开“网页搜索”，检查 endpoint 和独立密钥后重试。"
        }
        switch error {
        case .invalidStoredDocument:
            return "网页搜索配置已损坏，无法读取。请打开“网页搜索”，重新保存独立搜索配置；也可以删除后重新配置。"
        case .invalidBaseURL:
            return "网页搜索 endpoint 无效。请打开“网页搜索”，填写不带用户名、密码、query 或 fragment 的 http(s) 地址。"
        case .operationInBaseURL:
            return "网页搜索 endpoint 不能已经以 /search 或 /fetch 结尾。请修改后重新保存。"
        case .secretStore:
            return "无法读取或清理独立搜索密钥。请解锁设备后打开“网页搜索”重试；需要时重新保存密钥。"
        case .secretEnumerationUnavailable:
            return "无法确认独立搜索密钥是否已全部清理。请打开“网页搜索”再次执行删除。"
        case .documentStore:
            return "网页搜索配置未能保存或清理。请打开“网页搜索”重试；旧配置和密钥会保持原样。"
        case .apiKeyRequiredForNewEndpoint:
            return "搜索 endpoint 已更改，需要重新输入独立搜索密钥，不能沿用旧服务的密钥。"
        }
    }

    @discardableResult
    public static func apply(to plan: inout ModelProviderLaunchPlan,
                             modelProfile: ProviderProfile?,
                             settings: PhoneWebSearchSettings = .shared,
                             modelSettings: PhoneModelProviderSettings = .shared)
        -> WebSearchHostLaunchPlan {
        let resolved = makeLaunchPlan(modelProvider: plan.credentialProvider,
                                      modelProfile: modelProfile,
                                      settings: settings,
                                      modelSettings: modelSettings)
        plan.credentialProvider = resolved.credentialProvider
        plan.allowedModelHosts.formUnion(resolved.allowedHostRules)
        plan.environment.removeValue(forKey: modelSearchBaseEnvironmentKey)
        for key in [PhoneWebSearchSettings.workerProviderKey,
                    PhoneWebSearchSettings.workerFetchProviderKey,
                    PhoneWebSearchSettings.workerBaseURLKey,
                    PhoneWebSearchSettings.workerAPIKeyEnv] {
            plan.environment.removeValue(forKey: key)
        }
        plan.environment.merge(resolved.environment) { _, new in new }
        return resolved
    }

    /// Resolve one launch decision without mutating the caller's plan.
    public static func makeLaunchPlan(modelProvider: any CredentialProvider,
                                      modelProfile: ProviderProfile?,
                                      settings: PhoneWebSearchSettings = .shared,
                                      modelSettings: PhoneModelProviderSettings = .shared)
        -> WebSearchHostLaunchPlan {
        do {
            let snapshot = try settings.load()
            switch snapshot.configuration.mode {
            case .followModel:
                guard let modelProfile else {
                    return WebSearchHostLaunchPlan(credentialProvider: modelProvider, mode: .followModel)
                }
                guard PhoneModelProviderSettings.supportsOfficialDeepSeekWebTools(modelProfile) else {
                    return WebSearchHostLaunchPlan(
                        credentialProvider: modelProvider,
                        mode: .followModel,
                        warning: "当前模型服务不是受支持的官方 DeepSeek 地址。可以改用独立 DeepSeek 搜索 API。")
                }
                guard let webProvider = try? modelSettings.makeOfficialDeepSeekWebCredentialProvider(for: modelProfile) else {
                    return WebSearchHostLaunchPlan(
                        credentialProvider: modelProvider,
                        mode: .followModel,
                        warning: "无法读取模型服务的 DeepSeek 密钥。请在模型服务中检查密钥后重启引擎。")
                }
                return WebSearchHostLaunchPlan(
                    credentialProvider: modelProvider,
                    environment: [
                        PhoneWebSearchSettings.workerProviderKey: PhoneWebSearchMode.searchAPI.providerID,
                        PhoneWebSearchSettings.workerFetchProviderKey: "deepseek-fetch-api",
                        PhoneWebSearchSettings.workerBaseURLKey: PhoneModelProviderSettings.officialDeepSeekWebBaseURL,
                        PhoneWebSearchSettings.workerAPIKeyEnv: PhoneWebSearchSettings.placeholderAPIKey,
                    ],
                    mode: .followModel,
                    followsModelSearch: true,
                    officialDeepSeekWebCredentialProvider: webProvider)
            case .searchAPI:
                // spec/v1/tono-account.md §4: a signed-in account stands in
                // for the stored key when the base is the cloud origin.
                guard snapshot.hasCredential || settings.usesAccountCredential(snapshot) else {
                    return WebSearchHostLaunchPlan(credentialProvider: modelProvider, mode: .searchAPI)
                }
                return WebSearchHostLaunchPlan(
                    credentialProvider: settings.makeCredentialProvider(modelProvider: modelProvider),
                    allowedHostRules: try settings.allowedHostRules(),
                    environment: try settings.environmentEntries(),
                    mode: .searchAPI)
            }
        } catch {
            // The settings module's provider refuses every request in this
            // state. Do not publish a provider id or search endpoint: the
            // profile disables both provider rows, and the user must repair the
            // document on the native page.
            return WebSearchHostLaunchPlan(
                credentialProvider: settings.makeCredentialProvider(modelProvider: modelProvider),
                warning: userFacingMessage(for: error))
        }
    }
}
