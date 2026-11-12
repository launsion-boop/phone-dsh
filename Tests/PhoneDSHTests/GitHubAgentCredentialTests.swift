// SPDX-License-Identifier: MIT
import XCTest
import PhoneDSHAgentCore
@testable import PhoneDSH

final class GitHubAgentCredentialTests: XCTestCase {
    private final class MemoryStore: ModelProviderSecretStore, @unchecked Sendable {
        var values: [String: String]
        init(values: [String: String] = [:]) { self.values = values }
        func secret(for reference: String) throws -> String? { values[reference] }
        func setSecret(_ secret: String, for reference: String) throws { values[reference] = secret }
        func deleteSecret(for reference: String) throws { values.removeValue(forKey: reference) }
    }

    func testGitHubScopeReceivesTheKeychainToken() async throws {
        let store = MemoryStore(values: [GitHubAgentSettings.account: "ghp_test"])
        let provider = GitHubAgentCredentialProvider(
            base: StaticCredentialProvider([:]),
            store: store)
        let credential = try await provider.credential(for: CredentialScope(
            service: "api.github.com", audience: "/repos/octo/example", scheme: "https", port: 443))
        XCTAssertEqual(credential.kind, .bearer)
        XCTAssertEqual(credential.value, "ghp_test")
    }

    func testOtherScopesDelegateToTheBaseProvider() async throws {
        let modelScope = CredentialScope(service: "model.example", audience: "/v1/chat/completions")
        let base = StaticCredentialProvider([
            modelScope: Credential(kind: .apiKey(header: "x-api-key"), value: "model-key"),
        ])
        let provider = GitHubAgentCredentialProvider(
            base: base,
            store: MemoryStore(values: [GitHubAgentSettings.account: "ghp_test"]))
        let credential = try await provider.credential(for: modelScope)
        XCTAssertEqual(credential.kind, .apiKey(header: "x-api-key"))
        XCTAssertEqual(credential.value, "model-key")
    }

    func testGitHubScopeWithoutATokenStaysAnonymous() async throws {
        let provider = GitHubAgentCredentialProvider(
            base: StaticCredentialProvider([:]),
            store: MemoryStore())
        let credential = try await provider.credential(for: CredentialScope(
            service: "api.github.com", audience: "/repos/octo/example", scheme: "https", port: 443))
        XCTAssertEqual(credential.kind, .none)
    }

    func testTheTokenNeverCrossesAnInsecureOrNonDefaultScope() async throws {
        let provider = GitHubAgentCredentialProvider(
            base: StaticCredentialProvider([:]),
            store: MemoryStore(values: [GitHubAgentSettings.account: "ghp_test"]))
        for scope in [
            CredentialScope(service: "api.github.com", audience: "/x", scheme: "http", port: 80),
            CredentialScope(service: "api.github.com", audience: "/x", scheme: "https", port: 8443),
        ] {
            let credential = try await provider.credential(for: scope)
            XCTAssertEqual(credential.kind, .none, scope.service)
        }
    }

    func testWritesNeedBothATokenAndTheExplicitOptIn() {
        let store = MemoryStore(values: [GitHubAgentSettings.account: "ghp_test"])
        XCTAssertTrue(GitHubAgentConfiguration(allowWrites: true)
            .writeCredentialAvailable(store: store))
        XCTAssertFalse(GitHubAgentConfiguration(allowWrites: false)
            .writeCredentialAvailable(store: store))
        XCTAssertFalse(GitHubAgentConfiguration(allowWrites: true)
            .writeCredentialAvailable(store: MemoryStore()))
        XCTAssertFalse(GitHubAgentConfiguration.disabled
            .writeCredentialAvailable(store: store))
    }

    func testTheWorkerEnvStatesTheHostDecision() {
        XCTAssertEqual(PhoneDSHWorkerEnvironment.githubAuth, "PDSH_GITHUB_AUTH")
        XCTAssertEqual(PhoneDSHWorkerEnvironment.githubWrite, "PDSH_GITHUB_WRITE")
        XCTAssertEqual(PhoneDSHHost.githubAuthEnvironmentValue(.disabled), "0")
        XCTAssertEqual(PhoneDSHHost.githubWriteEnvironmentValue(.disabled), "0")

        let store = MemoryStore(values: [GitHubAgentSettings.account: "ghp_test"])
        XCTAssertEqual(PhoneDSHHost.githubAuthEnvironmentValue(
            GitHubAgentConfiguration(allowWrites: true), store: store), "1")
        XCTAssertEqual(PhoneDSHHost.githubAuthEnvironmentValue(
            GitHubAgentConfiguration(allowWrites: false), store: store), "1")
        XCTAssertEqual(PhoneDSHHost.githubAuthEnvironmentValue(
            GitHubAgentConfiguration(allowWrites: true), store: MemoryStore()), "0")
        XCTAssertEqual(PhoneDSHHost.githubWriteEnvironmentValue(
            GitHubAgentConfiguration(allowWrites: true), store: store), "1")
        XCTAssertEqual(PhoneDSHHost.githubWriteEnvironmentValue(
            GitHubAgentConfiguration(allowWrites: false), store: store), "0")
    }
}
