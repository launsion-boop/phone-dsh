// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — ProbeKit: independent web Search/Fetch host wiring.
//
// `PhoneWebSearchSettings` owns the non-secret document, the dedicated search
// Keychain and the host/path credential router. This file is the one place the
// App, the recovery surface and the simulator suites apply that module
// to the model launch plan:
//
//   * independent Search/Fetch mode selects the official
//     `deepseek-search-api` / `deepseek-fetch-api` providers and adds only the
//     configured route's allowed host rule;
//   * follow-model mode is an explicit fallback and is offered only for the
//     official DeepSeek Messages endpoint the shipped `deepseek-official`
//     provider actually supports. An arbitrary OpenAI-compatible endpoint does
//     not inherit web search;
//   * the Worker receives the provider ids, endpoint and a non-secret
//     placeholder only. The real key stays in the host credential router;
//   * a corrupt/invalid document yields the settings module's fail-closed
//     provider and no provider selection, never a silent model-key fallback.

import Foundation
import PhoneDSH
import PhoneDSHAgentCore

/// One launch decision for the Worker's web search/fetch rows.
public struct WebSearchHostLaunchPlan {
    /// Host-side credential provider: model provider, independent router or
    /// the settings module's fail-closed provider.
    public var credentialProvider: any CredentialProvider
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
                warning: String? = nil) {
        self.credentialProvider = credentialProvider
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

    /// Whether the shipped `deepseek-official` Messages-search adapter can
    /// serve this model service.
    ///
    /// The adapter calls the Anthropic-compatible Messages endpoint with the
    /// native `web_search_20250305` server tool. The model service must
    /// therefore be the official DeepSeek Messages endpoint, not merely a
    /// hostname under `deepseek.com` and not an OpenAI-compatible base URL
    /// that happens to share the host. `PhoneModelProviderSettings` publishes
    /// `/anthropic/v1` as the Messages-search base for `/anthropic` and
    /// `/anthropic/v1`, so only those two paths can supply the protocol the
    /// adapter actually implements.
    public static func modelServiceSupportsMessagesSearch(_ profile: ProviderProfile?) -> Bool {
        guard let url = profile?.endpointURL,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "api.deepseek.com",
              url.port == nil || url.port == 443 else {
            return false
        }
        var path = url.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path.isEmpty { path = "/" }
        return path == "/anthropic" || path == "/anthropic/v1"
    }

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

    private static func followModelUnsupportedWarning(_ profile: ProviderProfile) -> String {
        let name = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = name.isEmpty ? profile.id : name
        return "当前模型服务“\(label)”不是官方 DeepSeek Messages 端点，无法沿用其网页搜索。请改用独立 DeepSeek 搜索 API，或把模型服务地址改为 https://api.deepseek.com/anthropic。"
    }

    /// Apply the stored search setting to a model launch plan and report what
    /// was selected.
    ///
    /// The model provider is wrapped only when independent mode is stored;
    /// follow-model keeps the model provider unchanged. The base URL the
    /// Messages-search provider derives from the model service is removed when
    /// that fallback is not supported, so no stale endpoint advertises search.
    @discardableResult
    public static func apply(to plan: inout ModelProviderLaunchPlan,
                             modelProfile: ProviderProfile?,
                             settings: PhoneWebSearchSettings = .shared)
        -> WebSearchHostLaunchPlan {
        let resolved = makeLaunchPlan(modelProvider: plan.credentialProvider,
                                      modelProfile: modelProfile,
                                      settings: settings)
        plan.credentialProvider = resolved.credentialProvider
        plan.allowedModelHosts.formUnion(resolved.allowedHostRules)
        if !resolved.followsModelSearch {
            plan.environment.removeValue(forKey: modelSearchBaseEnvironmentKey)
        }
        // A caller may reuse a launch plan. Publishing no provider (empty,
        // unsupported follow-model or a corrupt document) must also remove a
        // stale provider id, otherwise the Worker could expose a tool with no
        // provider behind it.
        if resolved.environment[PhoneWebSearchSettings.workerProviderKey] == nil {
            plan.environment.removeValue(forKey: PhoneWebSearchSettings.workerProviderKey)
        }
        if resolved.environment[PhoneWebSearchSettings.workerFetchProviderKey] == nil {
            plan.environment.removeValue(forKey: PhoneWebSearchSettings.workerFetchProviderKey)
        }
        plan.environment.merge(resolved.environment) { _, new in new }
        return resolved
    }

    /// Resolve one launch decision without mutating the caller's plan.
    public static func makeLaunchPlan(modelProvider: any CredentialProvider,
                                      modelProfile: ProviderProfile?,
                                      settings: PhoneWebSearchSettings = .shared)
        -> WebSearchHostLaunchPlan {
        do {
            let snapshot = try settings.load()
            let credentialProvider = settings.makeCredentialProvider(modelProvider: modelProvider)
            let hostRules = try settings.allowedHostRules()
            let environment = try settings.environmentEntries()
            switch snapshot.configuration.mode {
            case .followModel:
                // No model service yet is the normal first-launch state, not a
                // broken search configuration: boot the page without a search
                // provider and without a warning that blocks or alarms.
                guard let modelProfile else {
                    return WebSearchHostLaunchPlan(
                        credentialProvider: modelProvider,
                        mode: .followModel,
                        followsModelSearch: false)
                }
                guard modelServiceSupportsMessagesSearch(modelProfile) else {
                    return WebSearchHostLaunchPlan(
                        credentialProvider: modelProvider,
                        mode: .followModel,
                        followsModelSearch: false,
                        warning: followModelUnsupportedWarning(modelProfile))
                }
                return WebSearchHostLaunchPlan(credentialProvider: credentialProvider,
                                               allowedHostRules: hostRules,
                                               environment: environment,
                                               mode: .followModel,
                                               followsModelSearch: true)
            case .searchAPI:
                return WebSearchHostLaunchPlan(credentialProvider: credentialProvider,
                                               allowedHostRules: hostRules,
                                               environment: environment,
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
