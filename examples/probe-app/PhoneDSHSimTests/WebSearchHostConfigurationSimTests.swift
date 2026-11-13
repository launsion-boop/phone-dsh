// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — iOS Simulator coverage for the ProbeKit search launch
// contract. The stores are isolated UserDefaults and in-memory dummy
// credentials, so this suite never reads a real Keychain or a real key.

import Foundation
import XCTest
import PhoneDSH
import PhoneDSHAgentCore
import ProbeKit

final class WebSearchHostConfigurationSimTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var secrets: SimSearchSecretStore!
    private var settings: PhoneWebSearchSettings!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "WebSearchHostConfigurationSimTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        secrets = SimSearchSecretStore()
        settings = PhoneWebSearchSettings(defaults: defaults, secretStore: secrets)
    }

    override func tearDown() {
        if let defaults, !suiteName.isEmpty {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        secrets = nil
        settings = nil
        suiteName = ""
        super.tearDown()
    }

    // MARK: - Follow-model selection

    func testFollowModelRequiresAnOfficialDeepSeekBase() {
        let accepted = [
            "https://api.deepseek.com",
            "https://api.deepseek.com/v1",
            "https://api.deepseek.com/anthropic",
            "https://api.deepseek.com/anthropic/",
            "https://api.deepseek.com/anthropic/v1",
            "https://api.deepseek.com/anthropic/v1/",
            "https://API.DEEPSEEK.COM/anthropic",
            "https://api.deepseek.com:443/anthropic",
        ]
        for baseURL in accepted {
            XCTAssertTrue(
                PhoneModelProviderSettings.supportsOfficialDeepSeekWebTools(profile(baseURL)),
                "expected official DeepSeek endpoint: \(baseURL)")
        }

        let rejected = [
            "https://api.deepseek.com/v2",
            "https://api.deepseek.com/v1?query=1",
            "https://api.deepseek.com/v1/../v1",
            "https://api.deepseek.com/anthropic/v1/messages",
            "https://chat.deepseek.com/anthropic",
            "https://search.deepseek.com/anthropic",
            "https://api.deepseek.com.evil.example/anthropic",
            "https://api.deepseek.com:8443/anthropic",
            "http://api.deepseek.com/anthropic",
            "https://api.example.com/anthropic",
        ]
        for baseURL in rejected {
            XCTAssertFalse(
                PhoneModelProviderSettings.supportsOfficialDeepSeekWebTools(profile(baseURL)),
                "unofficial or unsupported endpoint must not follow: \(baseURL)")
        }
        XCTAssertFalse(PhoneModelProviderSettings.supportsOfficialDeepSeekWebTools(nil))
    }

    func testFollowModelSharesTheStoredKeyForBothOfficialTools() async throws {
        let selected = profile("https://api.deepseek.com/v1")
        let modelSettings = PhoneModelProviderSettings(defaults: defaults, secretStore: secrets, environment: [:])
        let key = "fixture-model-key"
        try secrets.setSecret(key, for: selected.credentialRef)
        var plan = ModelProviderLaunchPlan(
            allowedModelHosts: ["https://api.deepseek.com"],
            credentialProvider: modelProvider(modelValue: key),
            environment: [WebSearchHostConfiguration.modelSearchBaseEnvironmentKey:
                            "https://api.deepseek.com/anthropic/v1"])

        let resolved = WebSearchHostConfiguration.apply(
            to: &plan, modelProfile: selected, settings: settings, modelSettings: modelSettings)

        XCTAssertEqual(resolved.mode, .followModel)
        XCTAssertTrue(resolved.followsModelSearch)
        XCTAssertNil(resolved.warning)
        XCTAssertEqual(plan.allowedModelHosts, ["https://api.deepseek.com"])
        XCTAssertEqual(plan.environment[PhoneWebSearchSettings.workerProviderKey], "deepseek-search-api")
        XCTAssertEqual(plan.environment[PhoneWebSearchSettings.workerFetchProviderKey], "phone-host-fetch")
        XCTAssertEqual(plan.environment[PhoneWebSearchSettings.workerBaseURLKey], "https://api.deepseek.com/v1/tools")
        XCTAssertNil(plan.environment[WebSearchHostConfiguration.modelSearchBaseEnvironmentKey])
        XCTAssertFalse(plan.environment.values.contains(key))

        let web = try XCTUnwrap(resolved.officialDeepSeekWebCredentialProvider)
        for path in ["/v1/tools/search", "/v1/tools/fetch"] {
            let credential = try await web.credential(
                for: CredentialScope(service: "api.deepseek.com", audience: path, scheme: "https"))
            XCTAssertEqual(credential.kind, .bearer)
            XCTAssertEqual(credential.value, key)
        }
        let model = try await plan.credentialProvider.credential(
            for: CredentialScope(service: "api.deepseek.com", audience: "/v1/chat/completions", scheme: "https"))
        XCTAssertEqual(model.kind, .apiKey(header: "x-api-key"))
        XCTAssertEqual(model.value, key)
    }

    func testOfficialFollowModelWithoutReadableKeyPublishesNeitherTool() {
        let selected = profile("https://api.deepseek.com/anthropic")
        let modelSettings = PhoneModelProviderSettings(defaults: defaults, secretStore: secrets, environment: [:])
        var plan = ModelProviderLaunchPlan(credentialProvider: modelProvider())
        let resolved = WebSearchHostConfiguration.apply(
            to: &plan, modelProfile: selected, settings: settings, modelSettings: modelSettings)
        XCTAssertEqual(resolved.mode, .followModel)
        XCTAssertFalse(resolved.followsModelSearch)
        XCTAssertNil(resolved.officialDeepSeekWebCredentialProvider)
        XCTAssertNil(plan.environment[PhoneWebSearchSettings.workerProviderKey])
        XCTAssertNil(plan.environment[PhoneWebSearchSettings.workerFetchProviderKey])
    }

    func testUnsupportedFollowModelPublishesNoProviderAndExplainsTheFix() throws {
        for baseURL in ["https://api.deepseek.com/v2",
                        "https://chat.deepseek.com/anthropic"] {
            var plan = ModelProviderLaunchPlan(
                allowedModelHosts: ["https://api.deepseek.com"],
                credentialProvider: modelProvider(),
                environment: [WebSearchHostConfiguration.modelSearchBaseEnvironmentKey:
                                "https://stale.example/anthropic/v1",
                              PhoneWebSearchSettings.workerProviderKey: "stale-search-provider",
                              PhoneWebSearchSettings.workerFetchProviderKey: "stale-fetch-provider"])

            let resolved = WebSearchHostConfiguration.apply(
                to: &plan,
                modelProfile: profile(baseURL),
                settings: settings)

            XCTAssertEqual(resolved.mode, PhoneWebSearchMode.followModel)
            XCTAssertFalse(resolved.followsModelSearch, baseURL)
            XCTAssertEqual(plan.allowedModelHosts, Set(["https://api.deepseek.com"]), baseURL)
            XCTAssertNil(plan.environment[PhoneWebSearchSettings.workerProviderKey], baseURL)
            XCTAssertNil(plan.environment[PhoneWebSearchSettings.workerFetchProviderKey], baseURL)
            XCTAssertNil(plan.environment[WebSearchHostConfiguration.modelSearchBaseEnvironmentKey],
                         baseURL)
            let warning = try XCTUnwrap(resolved.warning, baseURL)
            XCTAssertTrue(warning.contains("独立 DeepSeek 搜索 API"), warning)
        }
    }

    func testFirstLaunchWithoutAModelServiceHasNoSearchProviderAndNoAlarm() throws {
        var plan = ModelProviderLaunchPlan(
            credentialProvider: modelProvider(),
            environment: [WebSearchHostConfiguration.modelSearchBaseEnvironmentKey:
                            "https://stale.example/anthropic/v1",
                          PhoneWebSearchSettings.workerProviderKey: "stale-search-provider",
                          PhoneWebSearchSettings.workerFetchProviderKey: "stale-fetch-provider"])

        let resolved = WebSearchHostConfiguration.apply(
            to: &plan,
            modelProfile: nil,
            settings: settings)

        XCTAssertEqual(resolved.mode, PhoneWebSearchMode.followModel)
        XCTAssertFalse(resolved.followsModelSearch)
        XCTAssertNil(resolved.warning)
        XCTAssertNil(plan.environment[PhoneWebSearchSettings.workerProviderKey])
        XCTAssertNil(plan.environment[PhoneWebSearchSettings.workerFetchProviderKey])
        XCTAssertNil(plan.environment[WebSearchHostConfiguration.modelSearchBaseEnvironmentKey])
    }

    // MARK: - Independent Search/Fetch plan

    func testIndependentPlanMergesTheSearchHostAndPublishesDummyEnvironmentOnly() async throws {
        let searchKey = "dummy-independent-search-key"
        let modelKey = "dummy-model-key"
        _ = try settings.save(mode: .searchAPI,
                              baseURL: "https://search.example:8443/v1/tools",
                              apiKey: searchKey)
        let model = modelProvider(modelHost: "search.example",
                                  modelValue: modelKey,
                                  allowedAudience: "/v1/messages")
        var plan = ModelProviderLaunchPlan(allowedModelHosts: ["https://model.example"],
                                           credentialProvider: model)
        let resolved = WebSearchHostConfiguration.apply(
            to: &plan,
            modelProfile: profile("https://model.example/anthropic"),
            settings: settings)

        XCTAssertEqual(resolved.mode, PhoneWebSearchMode.searchAPI)
        XCTAssertFalse(resolved.followsModelSearch)
        XCTAssertNil(resolved.warning)
        XCTAssertEqual(plan.allowedModelHosts,
                       Set(["https://model.example", "https://search.example:8443"]))
        XCTAssertEqual(plan.environment[PhoneWebSearchSettings.workerProviderKey],
                       "deepseek-search-api")
        XCTAssertEqual(plan.environment[PhoneWebSearchSettings.workerFetchProviderKey],
                       "phone-host-fetch")
        XCTAssertEqual(plan.environment[PhoneWebSearchSettings.workerBaseURLKey],
                       "https://search.example:8443/v1/tools")
        XCTAssertEqual(plan.environment[PhoneWebSearchSettings.workerAPIKeyEnv],
                       PhoneWebSearchSettings.placeholderAPIKey)
        XCTAssertFalse(plan.environment.values.contains(searchKey))
        XCTAssertFalse(plan.environment.values.contains(modelKey))

        // Same host: the operation paths use the dedicated dummy search key;
        // /v1/messages and every other path go through the model provider and
        // keep its validation instead of receiving the search key.
        let search = try await plan.credentialProvider.credential(
            for: CredentialScope(service: "search.example", audience: "/v1/tools/search"))
        XCTAssertEqual(search.kind, .bearer)
        XCTAssertEqual(search.value, searchKey)

        let modelCredential = try await plan.credentialProvider.credential(
            for: CredentialScope(service: "search.example", audience: "/v1/messages"))
        XCTAssertEqual(modelCredential.kind, .apiKey(header: "x-api-key"))
        XCTAssertEqual(modelCredential.value, modelKey)

        do {
            _ = try await plan.credentialProvider.credential(
                for: CredentialScope(service: "search.example", audience: "/v1/tools/unknown"))
            XCTFail("an unknown same-host path must be delegated to the model provider, not the search key")
        } catch let error as ProviderError {
            guard case .unauthorized = error else {
                return XCTFail("expected the model provider's unauthorized error, got \(error)")
            }
        }
    }

    func testClearingIndependentKeyStopsAdvertisingSearchAndFetchAtNextStart() async throws {
        let searchBase = "https://search.example/v1/tools"
        _ = try settings.save(mode: .searchAPI, baseURL: searchBase, apiKey: "fixture-search-key")
        let model = modelProvider(modelHost: "api.deepseek.com", modelValue: "fixture-model-key",
                                  allowedAudience: "/anthropic/v1/messages")
        let modelProfile = profile("https://api.deepseek.com/anthropic")
        var configured = ModelProviderLaunchPlan(credentialProvider: model)
        WebSearchHostConfiguration.apply(to: &configured, modelProfile: modelProfile, settings: settings)
        XCTAssertEqual(configured.environment[PhoneWebSearchSettings.workerProviderKey], "deepseek-search-api")
        XCTAssertEqual(configured.environment[PhoneWebSearchSettings.workerFetchProviderKey], "phone-host-fetch")

        _ = try settings.clearAPIKey()
        XCTAssertEqual(try settings.load().configuration.baseURL, searchBase)
        var restarted = ModelProviderLaunchPlan(
            allowedModelHosts: ["https://api.deepseek.com"],
            credentialProvider: model,
            environment: configured.environment
        )
        let resolved = WebSearchHostConfiguration.apply(
            to: &restarted, modelProfile: modelProfile, settings: settings)

        XCTAssertEqual(resolved.mode, .searchAPI)
        XCTAssertEqual(restarted.allowedModelHosts, ["https://api.deepseek.com"])
        XCTAssertNil(restarted.environment[PhoneWebSearchSettings.workerProviderKey])
        XCTAssertNil(restarted.environment[PhoneWebSearchSettings.workerFetchProviderKey])
        XCTAssertNil(restarted.environment[PhoneWebSearchSettings.workerBaseURLKey])
        XCTAssertNil(restarted.environment[PhoneWebSearchSettings.workerAPIKeyEnv])
        let modelCredential = try await restarted.credentialProvider.credential(
            for: CredentialScope(service: "api.deepseek.com", audience: "/anthropic/v1/messages"))
        XCTAssertEqual(modelCredential.value, "fixture-model-key")
    }

    // MARK: - Corrupt document

    func testCorruptDocumentFailsClosedWithActionableCopyAndNoProviderSelection() async throws {
        defaults.set(Data("{not-json".utf8), forKey: PhoneWebSearchSettings.defaultsKey)
        let model = modelProvider()
        var plan = ModelProviderLaunchPlan(credentialProvider: model)
        let resolved = WebSearchHostConfiguration.apply(
            to: &plan,
            modelProfile: profile("https://api.deepseek.com/anthropic"),
            settings: settings)

        XCTAssertNil(resolved.mode)
        XCTAssertFalse(resolved.followsModelSearch)
        XCTAssertNil(plan.environment[PhoneWebSearchSettings.workerProviderKey])
        XCTAssertNil(plan.environment[PhoneWebSearchSettings.workerFetchProviderKey])
        let warning = try XCTUnwrap(resolved.warning)
        XCTAssertTrue(warning.contains("网页搜索配置已损坏"), warning)
        XCTAssertFalse(warning.contains("{not-json"), warning)

        do {
            _ = try await plan.credentialProvider.credential(
                for: CredentialScope(service: "api.deepseek.com", audience: "/v1/messages"))
            XCTFail("a corrupt search document must fail closed instead of using the model key")
        } catch let error as ProviderError {
            guard case .unauthorized = error else {
                return XCTFail("expected unauthorized, got \(error)")
            }
        }
        XCTAssertTrue(model.scopes.isEmpty,
                      "the fail-closed search provider must not consult the model provider")
    }

    // MARK: - Helpers

    private func profile(_ baseURL: String) -> ProviderProfile {
        ProviderProfile(id: "sim-profile",
                        displayName: "Simulation profile",
                        baseURL: baseURL,
                        model: "deepseek-flash")
    }

    private func modelProvider(modelHost: String = "api.deepseek.com",
                               modelValue: String = "dummy-model-key",
                               allowedAudience: String? = nil) -> SimModelCredentialProvider {
        SimModelCredentialProvider(modelHost: modelHost,
                                   modelValue: modelValue,
                                   allowedAudience: allowedAudience)
    }
}

private final class SimSearchSecretStore: ModelProviderSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func secret(for reference: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[reference]
    }

    func setSecret(_ secret: String, for reference: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if secret.isEmpty { values.removeValue(forKey: reference) }
        else { values[reference] = secret }
    }

    func deleteSecret(for reference: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: reference)
    }
}

private final class SimModelCredentialProvider: CredentialProvider, @unchecked Sendable {
    let modelHost: String
    let modelValue: String
    let allowedAudience: String?

    private let lock = NSLock()
    private var storedScopes: [CredentialScope] = []

    init(modelHost: String, modelValue: String, allowedAudience: String?) {
        self.modelHost = modelHost.lowercased()
        self.modelValue = modelValue
        self.allowedAudience = allowedAudience
    }

    var scopes: [CredentialScope] {
        lock.lock()
        defer { lock.unlock() }
        return storedScopes
    }

    func credential(for scope: CredentialScope) async throws -> Credential {
        lock.lock()
        storedScopes.append(scope)
        lock.unlock()
        guard scope.service.lowercased() == modelHost else {
            throw ProviderError.unauthorized("not the configured model host")
        }
        if let allowedAudience, scope.audience != allowedAudience {
            throw ProviderError.unauthorized("path is not allowed by the model provider")
        }
        return Credential(kind: .apiKey(header: "x-api-key"), value: modelValue)
    }

    func invalidate(_ credential: Credential, for scope: CredentialScope) async {}
}
