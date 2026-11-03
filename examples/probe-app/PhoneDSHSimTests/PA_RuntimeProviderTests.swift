// SPDX-License-Identifier: MIT

import XCTest
import ProbeKit
import PhoneDSH

final class PA_RuntimeProviderTests: XCTestCase {
    func testOpenAICompatibleProviderReturnsUnsupportedProtocol() async throws {
        let settings = try makeSettings()
        let profile = ProviderProfile(id: "openai", displayName: "OpenAI",
                                      baseURL: "https://api.openai.com/v1", model: "gpt-test")
        try settings.settings.upsert(profile, apiKey: "mock-test-key")
        let resolver = NativeMainGatewayClientProvider(settings: settings.settings, responseLogRoot: nil)
        let adapter = try NativeMainAgentAdapter(clientResolver: resolver)
        let events = try await pa_runtimeCollect(adapter.run(turn: pa_runtimeTurn(mandate: nil)))
        guard case .unsupportedProtocol(let message)? = pa_runtimeFailure(events) else {
            return XCTFail("expected unsupportedProtocol, got \(String(describing: pa_runtimeFailure(events)))")
        }
        XCTAssertTrue(message.contains("DSH"))
    }

    func testAnthropicProviderWithoutKeyReturnsNotConfigured() async throws {
        let settings = try makeSettings()
        let profile = ProviderProfile(id: "deepseek", displayName: "DeepSeek",
                                      baseURL: "https://api.deepseek.com/anthropic", model: "deepseek-flash")
        try settings.settings.upsert(profile)
        let resolver = NativeMainGatewayClientProvider(settings: settings.settings, responseLogRoot: nil)
        let adapter = try NativeMainAgentAdapter(clientResolver: resolver)
        let events = try await pa_runtimeCollect(adapter.run(turn: pa_runtimeTurn(mandate: nil)))
        XCTAssertEqual(pa_runtimeFailure(events), .notConfigured)
    }

    func testNoSelectedProviderReturnsNotConfigured() async throws {
        let settings = try makeSettings()
        let resolver = NativeMainGatewayClientProvider(settings: settings.settings, responseLogRoot: nil)
        let adapter = try NativeMainAgentAdapter(clientResolver: resolver)
        let events = try await pa_runtimeCollect(adapter.run(turn: pa_runtimeTurn(mandate: nil)))
        XCTAssertEqual(pa_runtimeFailure(events), .notConfigured)
    }

    private func makeSettings() throws -> (settings: PhoneModelProviderSettings, suite: String) {
        let suite = "PA_RuntimeProviderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let settings = PhoneModelProviderSettings(defaults: defaults,
                                                  secretStore: PA_RuntimeSecretStore(), environment: [:])
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (settings, suite)
    }
}
