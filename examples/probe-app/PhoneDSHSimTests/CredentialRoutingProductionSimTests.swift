// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — production credential routing across model, search and
// MCP on the iOS Simulator.
//
// This suite builds the real `PhoneModelProviderSettings`,
// `PhoneWebSearchSettings` and `PhoneMCPAccessSettings` stores over isolated
// UserDefaults and in-memory dummy secrets, then runs the same
// `WebSearchHostConfiguration.apply` / `MCPHostConfiguration.apply` launch
// composition the App uses. It never creates a hand-written credential
// provider, and the three keys are deliberately different.

import Foundation
import XCTest
import PhoneDSH
import PhoneDSHAgentCore
import ProbeKit

final class CredentialRoutingProductionSimTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var secrets: SimProductionSecretStore!
    private var modelSettings: PhoneModelProviderSettings!
    private var searchSettings: PhoneWebSearchSettings!
    private var mcpSettings: PhoneMCPAccessSettings!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "CredentialRoutingProductionSimTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        secrets = SimProductionSecretStore()
        modelSettings = PhoneModelProviderSettings(defaults: defaults,
                                                   secretStore: secrets,
                                                   environment: [:])
        searchSettings = PhoneWebSearchSettings(defaults: defaults,
                                                secretStore: secrets)
        mcpSettings = PhoneMCPAccessSettings(defaults: defaults,
                                             secretStore: secrets)
    }

    override func tearDown() {
        if let defaults, !suiteName.isEmpty {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        secrets = nil
        modelSettings = nil
        searchSettings = nil
        mcpSettings = nil
        suiteName = ""
        super.tearDown()
    }

    func testProductionLaunchRoutesEachURLToItsOwnDummyKey() async throws {
        let modelKey = "dummy-model-key"
        let searchKey = "dummy-search-key"
        let mcpKey = "dummy-mcp-key"
        let profile = ProviderProfile(id: "sim-model",
                                      displayName: "Simulation model",
                                      baseURL: "https://model.example/v1",
                                      model: "deepseek-flash",
                                      credentialRef: "provider.sim-model")
        try modelSettings.upsert(profile, apiKey: modelKey)
        _ = try searchSettings.save(mode: .searchAPI,
                                    baseURL: "https://search.example:8443/v1/tools",
                                    apiKey: searchKey)
        let mcpURL = URL(string: "https://mcp.example/mcp")!
        _ = try mcpSettings.grant(serverName: "sim-mcp",
                                  url: mcpURL.absoluteString,
                                  headers: ["Authorization"],
                                  values: ["Authorization": "Bearer \(mcpKey)"])

        var plan = ModelProviderLaunchPlan()
        try modelSettings.apply(to: &plan, egressAllowHosts: [])
        let searchPlan = WebSearchHostConfiguration.apply(to: &plan,
                                                          modelProfile: profile,
                                                          settings: searchSettings)
        XCTAssertEqual(searchPlan.mode, PhoneWebSearchMode.searchAPI)
        let policy = MCPHostConfiguration.apply(to: &plan, settings: mcpSettings)
        XCTAssertTrue(policy.allowsEgressHost(mcpURL))
        let provider = plan.credentialProvider

        let model = try await provider.credential(
            for: CredentialScope(service: "model.example",
                                 audience: "/v1/messages",
                                 scheme: "https",
                                 port: nil))
        XCTAssertEqual(model.kind, .apiKey(header: "x-api-key"))
        XCTAssertEqual(model.value, modelKey)

        for path in ["/v1/tools/search", "/v1/tools/fetch"] {
            let search = try await provider.credential(
                for: CredentialScope(service: "search.example",
                                     audience: path,
                                     scheme: "https",
                                     port: 8443))
            XCTAssertEqual(search.kind, .bearer, path)
            XCTAssertEqual(search.value, searchKey, path)
        }

        let mcp = try await provider.credential(
            for: CredentialScope(service: "mcp.example",
                                 audience: "/mcp",
                                 scheme: "https",
                                 port: nil))
        XCTAssertEqual(mcp.kind, .headers(["Authorization": "Bearer \(mcpKey)"]))

        // A different path on the model host is not a model operation and must
        // not receive the model key.
        let modelSibling = try await provider.credential(
            for: CredentialScope(service: "model.example",
                                 audience: "/v1/other",
                                 scheme: "https",
                                 port: nil))
        XCTAssertEqual(modelSibling.kind, .none)

        // A different port on the model host is another origin and must not
        // receive the model key.
        let modelOtherPort = try await provider.credential(
            for: CredentialScope(service: "model.example",
                                 audience: "/v1/messages",
                                 scheme: "https",
                                 port: 8443))
        XCTAssertEqual(modelOtherPort.kind, .none)

        // A different port on the search host must not borrow the search key;
        // the fallback model provider refuses the unrelated host.
        await assertUnauthorized {
            _ = try await provider.credential(
                for: CredentialScope(service: "search.example",
                                     audience: "/v1/tools/search",
                                     scheme: "https",
                                     port: 8444))
        }

        // A different path on the search host is delegated, not given the
        // search key.
        await assertUnauthorized {
            _ = try await provider.credential(
                for: CredentialScope(service: "search.example",
                                     audience: "/v1/tools/other",
                                     scheme: "https",
                                     port: 8443))
        }

        // An unregistered MCP sibling path and an unknown host both fail
        // closed instead of reaching any of the three keys.
        await assertUnauthorized {
            _ = try await provider.credential(
                for: CredentialScope(service: "mcp.example",
                                     audience: "/other",
                                     scheme: "https",
                                     port: nil))
        }
        await assertUnauthorized {
            _ = try await provider.credential(
                for: CredentialScope(service: "unknown.example",
                                     audience: "/v1/messages",
                                     scheme: "https",
                                     port: nil))
        }
    }

    private func assertUnauthorized(_ operation: () async throws -> Void,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) async {
        do {
            try await operation()
            XCTFail("expected the production provider to refuse this origin/path",
                    file: file, line: line)
        } catch let error as ProviderError {
            guard case .unauthorized = error else {
                return XCTFail("expected unauthorized, got \(error)", file: file, line: line)
            }
        } catch {
            XCTFail("expected ProviderError.unauthorized, got \(error)", file: file, line: line)
        }
    }
}

private final class SimProductionSecretStore: PhoneWebSearchSecretStore, @unchecked Sendable {
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
        if secret.isEmpty {
            values.removeValue(forKey: reference)
        } else {
            values[reference] = secret
        }
    }

    func deleteSecret(for reference: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: reference)
    }

    func allReferences() throws -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(values.keys)
    }
}
