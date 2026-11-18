// SPDX-License-Identifier: MIT
import Foundation
import XCTest
import PhoneDSH

final class WebSearchAddressFixtureTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Case: Decodable {
            let id: String
            let storedBase: String
            let credential: String
            let submitted: String
            let result: String
            let finalBase: String
            let platform: String
            let operation: String
        }
        let cases: [Case]
    }

    func testSharedAddressCasesUseTheRealSettingsStore() throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "web-search-address-lifecycle.json", withExtension: nil))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))
        for item in fixture.cases where item.platform == "both" {
            let name = "WebSearchAddressFixture." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            let secrets = AddressFixtureSecrets()
            let store = PhoneWebSearchSettings(defaults: defaults, secretStore: secrets)
            var priorReference: String?
            if !item.storedBase.isEmpty {
                let saved = try store.save(mode: .searchAPI, baseURL: item.storedBase,
                                           apiKey: item.credential == "absent" ? nil : "fixture-key")
                priorReference = saved.configuration.credentialRef
            }
            if item.credential == "unreadable" { secrets.failNextRead = true }
            let newKey: String? = item.operation == "key-save" ? "fixture-new-key" : nil
            if item.result == "rejected" {
                XCTAssertThrowsError(try store.save(mode: .searchAPI, baseURL: item.submitted, apiKey: newKey), item.id)
            } else {
                XCTAssertNoThrow(try store.save(mode: .searchAPI, baseURL: item.submitted, apiKey: newKey), item.id)
            }
            XCTAssertEqual(try store.load().configuration.baseURL, item.finalBase, item.id)
            if item.credential != "absent", let reference = priorReference {
                XCTAssertEqual(try secrets.secret(for: reference), "fixture-key", item.id)
            }
        }
    }
}

private final class AddressFixtureSecrets: ModelProviderSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    var failNextRead = false
    func secret(for reference: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        if failNextRead { failNextRead = false; throw AddressFixtureError.unreadable }
        return values[reference]
    }
    func setSecret(_ secret: String, for reference: String) throws {
        lock.lock(); defer { lock.unlock() }; values[reference] = secret
    }
    func deleteSecret(for reference: String) throws {
        lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: reference)
    }
}
private enum AddressFixtureError: Error { case unreadable }
