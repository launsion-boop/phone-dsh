// SPDX-License-Identifier: MIT
// Independent web-search settings: document/Keychain separation, endpoint
// validation, host+path credential routing and metadata-first deletions with a
// durable keyless marker. The secret store is in-memory, so this suite never
// touches the real Keychain.

import Foundation
import XCTest
import PhoneDSHAgentCore
@testable import PhoneDSH

final class PhoneWebSearchSettingsTests: XCTestCase {
    private static let searchBase = "https://api.deepseek.com/v1/tools"
    private static let searchHost = "api.deepseek.com"
    private static let secret = "sk-search-secret-never-leak"

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var secrets: InMemoryWebSearchSecretStore!
    private var settings: PhoneWebSearchSettings!
    private var model: RecordingModelCredentialProvider!

    override func setUp() {
        super.setUp()
        suiteName = "PhoneWebSearchSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        secrets = InMemoryWebSearchSecretStore()
        settings = PhoneWebSearchSettings(defaults: defaults, secretStore: secrets)
        model = RecordingModelCredentialProvider(modelHost: Self.searchHost,
                                                 modelValue: "model-key",
                                                 anonymousHosts: ["wttr.in"])
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        secrets = nil
        settings = nil
        model = nil
        super.tearDown()
    }

    // MARK: - Defaults and follow-model fallback

    func testMissingDocumentIsExplicitFollowModelAndDoesNotTouchKeychain() async throws {
        let snapshot = try settings.load()
        XCTAssertEqual(snapshot.configuration.mode, .followModel)
        XCTAssertEqual(snapshot.configuration.providerID, "deepseek-official")
        XCTAssertFalse(snapshot.hasCredential)
        XCTAssertNil(snapshot.effectiveBaseURL)
        XCTAssertNil(defaults.data(forKey: PhoneWebSearchSettings.defaultsKey))
        XCTAssertTrue(secrets.allValues().isEmpty)
        XCTAssertEqual(try settings.environmentEntries(),
                       [PhoneWebSearchSettings.workerProviderKey: "deepseek-official"])
        XCTAssertEqual(try settings.allowedHostRules(), Set<String>())

        let provider = settings.makeCredentialProvider(modelProvider: model)
        let credential = try await provider.credential(
            for: CredentialScope(service: Self.searchHost, audience: "/v1/messages"))
        XCTAssertEqual(credential.kind, .apiKey(header: "x-api-key"))
        XCTAssertEqual(credential.value, "model-key")
    }

    func testFollowModelAfterSearchIsFallbackAndKeepsKeyOnlyForSameEndpoint() throws {
        let saved = try saveSearch(apiKey: Self.secret)
        let follow = try settings.save(mode: .followModel,
                                       baseURL: "https://different.example/v1/tools",
                                       apiKey: nil)
        XCTAssertEqual(follow.configuration.mode, .followModel)
        XCTAssertEqual(follow.configuration.baseURL, Self.searchBase,
                       "follow-model must not move the stored search identity")
        XCTAssertFalse(follow.hasCredential)
        XCTAssertEqual(try settings.environmentEntries(),
                       [PhoneWebSearchSettings.workerProviderKey: "deepseek-official"])
        XCTAssertEqual(try settings.allowedHostRules(), Set<String>())

        let back = try settings.save(mode: .searchAPI, baseURL: Self.searchBase, apiKey: nil)
        XCTAssertEqual(back.configuration.credentialRef, saved.configuration.credentialRef)
        XCTAssertTrue(back.hasCredential)
        XCTAssertEqual(secrets.value(saved.configuration.credentialRef), Self.secret)
    }

    // MARK: - Search API document and environment

    func testSearchAPISaveKeepsKeyOutOfDocumentAndWorkerEnvironment() throws {
        let saved = try settings.save(mode: .searchAPI,
                                      baseURL: Self.searchBase,
                                      apiKey: Self.secret)
        XCTAssertEqual(saved.configuration.mode, .searchAPI)
        XCTAssertEqual(saved.configuration.baseURL, Self.searchBase)
        XCTAssertEqual(saved.configuration.credentialRef, PhoneWebSearchSettings.defaultCredentialRef)
        XCTAssertEqual(saved.effectiveBaseURL, Self.searchBase)
        XCTAssertTrue(saved.hasCredential)

        let data = try XCTUnwrap(defaults.data(forKey: PhoneWebSearchSettings.defaultsKey))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains(Self.secret))
        XCTAssertFalse(json.contains("apiKey"))
        XCTAssertFalse(json.contains("secret"))
        XCTAssertEqual(secrets.value(saved.configuration.credentialRef), Self.secret)
        XCTAssertEqual(secrets.allValues().count, 1)

        let environment = try settings.environmentEntries()
        XCTAssertEqual(environment[PhoneWebSearchSettings.workerProviderKey], "deepseek-search-api")
        XCTAssertEqual(environment[PhoneWebSearchSettings.workerBaseURLKey], Self.searchBase)
        XCTAssertEqual(environment[PhoneWebSearchSettings.workerAPIKeyEnv],
                       PhoneWebSearchSettings.placeholderAPIKey)
        XCTAssertEqual(environment[PhoneWebSearchSettings.workerFetchProviderKey], "deepseek-fetch-api")
        XCTAssertFalse(environment.values.joined().contains(Self.secret))
    }

    func testSearchAPIBaseIsNormalizedAndDerivesBothOperationPaths() throws {
        let saved = try settings.save(mode: .searchAPI,
                                      baseURL: " HTTPS://API.Example.COM:8443/v1//tools/ ",
                                      apiKey: Self.secret)
        XCTAssertEqual(saved.configuration.baseURL, "https://api.example.com:8443/v1/tools")
        XCTAssertEqual(saved.configuration.searchPath, "/v1/tools/search")
        XCTAssertEqual(saved.configuration.fetchPath, "/v1/tools/fetch")
        XCTAssertEqual(saved.configuration.operationPaths,
                       Set(["/v1/tools/search", "/v1/tools/fetch"]))
        XCTAssertEqual(saved.configuration.searchEndpointURL?.absoluteString,
                       "https://api.example.com:8443/v1/tools/search")
        XCTAssertEqual(saved.configuration.fetchEndpointURL?.absoluteString,
                       "https://api.example.com:8443/v1/tools/fetch")
        XCTAssertEqual(try settings.allowedHostRules(), Set(["https://api.example.com:8443"]))
    }

    func testValidationRejectsUnsafeSearchBases() {
        let invalid = [
            "ftp://api.example.com/v1/tools",
            "https://user:password@api.example.com/v1/tools",
            "https://api.example.com/v1/tools?query=1",
            "https://api.example.com/v1/tools#fragment",
            "https:///missing-host",
            "not-a-url",
        ]
        for value in invalid {
            XCTAssertThrowsError(try settings.save(mode: .searchAPI,
                                                   baseURL: value,
                                                   apiKey: Self.secret), value) { error in
                guard let settingsError = error as? PhoneWebSearchSettingsError,
                      case .invalidBaseURL = settingsError else {
                    return XCTFail("expected invalidBaseURL for \(value), got \(error)")
                }
            }
        }
        for value in ["https://api.example.com/v1/tools/search",
                      "https://api.example.com/v1/tools/fetch/"] {
            XCTAssertThrowsError(try settings.save(mode: .searchAPI,
                                                   baseURL: value,
                                                   apiKey: Self.secret), value) { error in
                guard let settingsError = error as? PhoneWebSearchSettingsError,
                      case .operationInBaseURL = settingsError else {
                    return XCTFail("expected operationInBaseURL for \(value), got \(error)")
                }
            }
        }
        XCTAssertNil(defaults.data(forKey: PhoneWebSearchSettings.defaultsKey))
        XCTAssertTrue(secrets.allValues().isEmpty)
    }

    func testErrorTextDoesNotEchoAKeyMistakenForABaseURL() {
        let maybeSecret = "sk-error-text-leak"
        XCTAssertThrowsError(try settings.save(mode: .searchAPI,
                                               baseURL: maybeSecret,
                                               apiKey: nil)) { error in
            XCTAssertFalse(error.localizedDescription.contains(maybeSecret))
        }
    }

    // MARK: - Key identity and transaction ordering

    func testSaveWithoutKeyRetainsItOnlyForTheSameServiceIdentity() throws {
        let first = try saveSearch(apiKey: "first-key")
        let same = try settings.save(mode: .searchAPI,
                                     baseURL: Self.searchBase,
                                     apiKey: nil)
        XCTAssertEqual(same.configuration.credentialRef, first.configuration.credentialRef)
        XCTAssertEqual(secrets.value(first.configuration.credentialRef), "first-key")
        XCTAssertTrue(same.hasCredential)

        let other = "https://search.example.com/v1/tools"
        XCTAssertThrowsError(try settings.save(mode: .searchAPI,
                                               baseURL: other,
                                               apiKey: nil)) { error in
            guard let settingsError = error as? PhoneWebSearchSettingsError,
                  case .apiKeyRequiredForNewEndpoint(let value) = settingsError else {
                return XCTFail("expected apiKeyRequiredForNewEndpoint, got \(error)")
            }
            XCTAssertEqual(value, other)
        }
        XCTAssertEqual(try settings.load().configuration.baseURL, Self.searchBase)
        XCTAssertEqual(secrets.value(first.configuration.credentialRef), "first-key")

        let moved = try settings.save(mode: .searchAPI,
                                      baseURL: other,
                                      apiKey: "second-key")
        XCTAssertNotEqual(moved.configuration.credentialRef, first.configuration.credentialRef)
        XCTAssertEqual(secrets.value(moved.configuration.credentialRef), "second-key")
        XCTAssertEqual(secrets.value(first.configuration.credentialRef), "first-key",
                       "save must not delete the old key before the new document has been read back")

        let loaded = try settings.load()
        XCTAssertEqual(loaded.configuration.credentialRef, moved.configuration.credentialRef)
        XCTAssertNil(secrets.value(first.configuration.credentialRef),
                     "the next load reads the committed document and only then retires the old account")
    }

    func testStaleDefaultKeyWithoutDocumentRequiresAKeyForANewEndpoint() throws {
        try secrets.setSecret("stale-default-key",
                              for: PhoneWebSearchSettings.defaultCredentialRef)
        let other = "https://search.example.com/v1/tools"

        XCTAssertThrowsError(try settings.save(mode: .searchAPI,
                                               baseURL: other,
                                               apiKey: nil)) { error in
            guard let settingsError = error as? PhoneWebSearchSettingsError,
                  case .apiKeyRequiredForNewEndpoint(let value) = settingsError else {
                return XCTFail("expected apiKeyRequiredForNewEndpoint, got \(error)")
            }
            XCTAssertEqual(value, other)
        }
        XCTAssertNil(defaults.data(forKey: PhoneWebSearchSettings.defaultsKey),
                     "a rejected save must not create a document")
        XCTAssertEqual(secrets.value(PhoneWebSearchSettings.defaultCredentialRef),
                       "stale-default-key")
    }

    func testStaleDefaultKeyWithoutDocumentMovesANewKeyToAFreshAccount() throws {
        let staleRef = PhoneWebSearchSettings.defaultCredentialRef
        try secrets.setSecret("stale-default-key", for: staleRef)
        let other = "https://search.example.com/v1/tools"

        let saved = try settings.save(mode: .searchAPI,
                                      baseURL: other,
                                      apiKey: "fresh-service-key")
        XCTAssertNotEqual(saved.configuration.credentialRef, staleRef,
                          "a stale default key must not become the new service's key")
        XCTAssertEqual(secrets.value(saved.configuration.credentialRef), "fresh-service-key")
        XCTAssertEqual(secrets.value(staleRef), "stale-default-key",
                       "the old account is retired only after a load reads the committed document")
        XCTAssertTrue(saved.hasCredential)

        let loaded = try settings.load()
        XCTAssertEqual(loaded.configuration.baseURL, other)
        XCTAssertEqual(loaded.configuration.credentialRef, saved.configuration.credentialRef)
        XCTAssertTrue(loaded.hasCredential)
        XCTAssertNil(secrets.value(staleRef),
                     "the load that reads the new document reclaims the stale default account")

        let data = try XCTUnwrap(defaults.data(forKey: PhoneWebSearchSettings.defaultsKey))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("stale-default-key"))
        XCTAssertFalse(json.contains("fresh-service-key"))
    }

    func testStaleDefaultKeyClearCommitsAKeylessIdentityAtomically() async throws {
        let staleRef = PhoneWebSearchSettings.defaultCredentialRef
        try secrets.setSecret("stale-default-key", for: staleRef)
        let other = "https://search.example.com/v1/tools"

        let cleared = try settings.save(mode: .searchAPI,
                                        baseURL: other,
                                        apiKey: "")
        XCTAssertNotEqual(cleared.configuration.credentialRef, staleRef)
        XCTAssertFalse(cleared.hasCredential)
        XCTAssertEqual(secrets.value(staleRef), "stale-default-key",
                       "an explicit clear also waits for the committed document before deleting the old key")

        let loaded = try settings.load()
        XCTAssertEqual(loaded.configuration.baseURL, other)
        XCTAssertFalse(loaded.hasCredential)
        XCTAssertNil(secrets.value(staleRef))

        let provider = settings.makeCredentialProvider(modelProvider: model)
        do {
            _ = try await provider.credential(
                for: CredentialScope(service: "search.example.com",
                                     audience: "/v1/tools/search"))
            XCTFail("a cleared stale key must not be readable after the next load")
        } catch let error as ProviderError {
            guard case .unauthorized = error else {
                return XCTFail("expected unauthorized, got \(error)")
            }
        }
        XCTAssertTrue(model.scopes.isEmpty)
    }

    func testStaleDefaultKeyReadFailureFailsClosedBeforeWriting() throws {
        let staleRef = PhoneWebSearchSettings.defaultCredentialRef
        try secrets.setSecret("stale-default-key", for: staleRef)
        secrets.failReads(for: staleRef)

        XCTAssertThrowsError(try settings.save(mode: .searchAPI,
                                               baseURL: "https://search.example.com/v1/tools",
                                               apiKey: "fresh-service-key")) { error in
            XCTAssertEqual(error as? PhoneWebSearchSettingsError, .secretStore)
        }
        XCTAssertNil(defaults.data(forKey: PhoneWebSearchSettings.defaultsKey))
        XCTAssertEqual(secrets.value(staleRef), "stale-default-key")
        XCTAssertEqual(secrets.allValues().count, 1,
                       "a failed read must not write a new account")
    }

    func testStaleDefaultKeyRetirementFailureStaysTrackedAndReconciles() throws {
        let staleRef = PhoneWebSearchSettings.defaultCredentialRef
        try secrets.setSecret("stale-default-key", for: staleRef)
        secrets.failNextDelete = true

        let saved = try settings.save(mode: .searchAPI,
                                      baseURL: "https://search.example.com/v1/tools",
                                      apiKey: "fresh-service-key")
        XCTAssertEqual(secrets.value(saved.configuration.credentialRef), "fresh-service-key")
        XCTAssertEqual(secrets.value(staleRef), "stale-default-key",
                       "save itself never deletes a retired key")

        let loaded = try settings.load()
        XCTAssertEqual(loaded.configuration.credentialRef, saved.configuration.credentialRef)
        XCTAssertEqual(secrets.value(staleRef), "stale-default-key",
                       "a failed retirement stays tracked in the committed document")
        let documentData = try XCTUnwrap(defaults.data(forKey: PhoneWebSearchSettings.defaultsKey))
        let object = try JSONSerialization.jsonObject(with: documentData) as? [String: Any]
        let document = try XCTUnwrap(object)
        XCTAssertEqual(document["retiredCredentialRefs"] as? [String], [staleRef])

        _ = try settings.load()
        XCTAssertNil(secrets.value(staleRef),
                     "the next load retries the tracked retirement")
    }

    func testPendingAccountDeleteFailureStaysReconcilable() throws {
        let orphan = "\(PhoneWebSearchSettings.defaultCredentialRef).pending-orphan"
        try secrets.setSecret("orphan-key", for: orphan)
        defaults.set([orphan], forKey: PhoneWebSearchSettings.pendingDefaultsKey)
        secrets.failNextDelete = true

        let loaded = try settings.load()
        XCTAssertEqual(loaded.configuration.mode, .followModel)
        XCTAssertEqual(secrets.value(orphan), "orphan-key")
        XCTAssertEqual(defaults.stringArray(forKey: PhoneWebSearchSettings.pendingDefaultsKey) ?? [],
                       [orphan],
                       "a failed pending delete must stay recorded for the next reconcile")

        _ = try settings.load()
        XCTAssertNil(secrets.value(orphan))
        XCTAssertNil(defaults.stringArray(forKey: PhoneWebSearchSettings.pendingDefaultsKey))
    }

    func testAddingAKeyToAKeylessConfigReusesTheDefaultAccount() throws {
        let keyless = try settings.save(mode: .searchAPI, baseURL: Self.searchBase, apiKey: nil)
        XCTAssertEqual(keyless.configuration.credentialRef,
                       PhoneWebSearchSettings.defaultCredentialRef)
        XCTAssertFalse(keyless.hasCredential)

        let withKey = try saveSearch(apiKey: "key")
        XCTAssertEqual(withKey.configuration.credentialRef,
                       PhoneWebSearchSettings.defaultCredentialRef)
        XCTAssertTrue(withKey.hasCredential)
        XCTAssertEqual(secrets.value(withKey.configuration.credentialRef), "key")
    }

    func testChangingEndpointWithAKeyUsesAFreshAccountEvenWithoutAnOldKey() throws {
        let keyless = try settings.save(mode: .searchAPI, baseURL: Self.searchBase, apiKey: nil)
        XCTAssertFalse(keyless.hasCredential)

        let other = "https://search.example.com/v1/tools"
        let moved = try settings.save(mode: .searchAPI, baseURL: other, apiKey: "new-key")
        XCTAssertNotEqual(moved.configuration.credentialRef, keyless.configuration.credentialRef,
                          "the old document must never resolve the new endpoint's key")
        XCTAssertNil(secrets.value(keyless.configuration.credentialRef))
        XCTAssertEqual(secrets.value(moved.configuration.credentialRef), "new-key")
        XCTAssertEqual(try settings.load().configuration.baseURL, other)
    }

    func testSecretWriteFailureLeavesTheOldDocumentAndKeyIntact() throws {
        let first = try saveSearch(apiKey: "old-key")
        secrets.failNextSet = true
        XCTAssertThrowsError(try settings.save(mode: .searchAPI,
                                               baseURL: Self.searchBase,
                                               apiKey: "new-key")) { error in
            XCTAssertEqual(error as? PhoneWebSearchSettingsError, .secretStore)
        }
        let loaded = try settings.load()
        XCTAssertEqual(loaded.configuration.credentialRef, first.configuration.credentialRef)
        XCTAssertEqual(secrets.value(first.configuration.credentialRef), "old-key")
    }

    func testSecretReadFailureFailsClosedAndNeverFallsBackToTheModelKey() async throws {
        let first = try saveSearch(apiKey: "old-key")
        secrets.failReads(for: first.configuration.credentialRef)

        XCTAssertThrowsError(try settings.load()) { error in
            XCTAssertEqual(error as? PhoneWebSearchSettingsError, .secretStore)
        }
        XCTAssertFalse(settings.hasAPIKey())

        let provider = settings.makeCredentialProvider(modelProvider: model)
        do {
            _ = try await provider.credential(
                for: CredentialScope(service: Self.searchHost, audience: "/v1/messages"))
            XCTFail("a corrupt search credential read must not expose the model credential")
        } catch let error as ProviderError {
            guard case .unauthorized = error else {
                return XCTFail("expected unauthorized, got \(error)")
            }
        }
        XCTAssertTrue(model.scopes.isEmpty)
    }

    func testRetiredKeyCleanupFailureKeepsAReconcilableOrphan() throws {
        let first = try saveSearch(apiKey: "old-key")
        secrets.failNextDelete = true
        let rotated = try settings.save(mode: .searchAPI,
                                        baseURL: Self.searchBase,
                                        apiKey: "new-key")
        XCTAssertEqual(secrets.value(rotated.configuration.credentialRef), "new-key")
        XCTAssertEqual(secrets.value(first.configuration.credentialRef), "old-key",
                       "the old key is only retired after a load reads the committed document")

        _ = try settings.load()
        XCTAssertEqual(secrets.value(first.configuration.credentialRef), "old-key",
                       "a failed cleanup keeps the orphan tracked in the document")

        try settings.remove()
        XCTAssertTrue(secrets.allValues().isEmpty,
                      "remove also reconciles the tracked retired account")
    }

    func testLoadReconcilesAnUncommittedFreshAccountAfterACrash() throws {
        let saved = try saveSearch(apiKey: "old-key")
        let orphan = "\(PhoneWebSearchSettings.defaultCredentialRef).crash-uncommitted"
        try secrets.setSecret("new-key", for: orphan)
        defaults.set([orphan], forKey: PhoneWebSearchSettings.pendingDefaultsKey)

        let loaded = try settings.load()
        XCTAssertEqual(loaded.configuration.credentialRef, saved.configuration.credentialRef)
        XCTAssertEqual(secrets.value(saved.configuration.credentialRef), "old-key")
        XCTAssertNil(secrets.value(orphan),
                     "the document never committed, so the fresh account is removed")
        XCTAssertNil(defaults.stringArray(forKey: PhoneWebSearchSettings.pendingDefaultsKey))
    }

    func testLoadDropsThePendingMarkerForTheCommittedAccount() throws {
        let saved = try saveSearch(apiKey: "committed-key")
        defaults.set([saved.configuration.credentialRef],
                     forKey: PhoneWebSearchSettings.pendingDefaultsKey)

        let loaded = try settings.load()
        XCTAssertEqual(loaded.configuration.credentialRef, saved.configuration.credentialRef)
        XCTAssertEqual(secrets.value(saved.configuration.credentialRef), "committed-key")
        XCTAssertNil(defaults.stringArray(forKey: PhoneWebSearchSettings.pendingDefaultsKey))
    }

    func testFailedRemoveKeepsKeylessDocumentAndRetryFinishes() throws {
        let saved = try saveSearch(apiKey: "old-key")
        secrets.failNextDelete = true
        XCTAssertThrowsError(try settings.remove()) { error in
            XCTAssertEqual(error as? PhoneWebSearchSettingsError, .secretStore)
        }
        XCTAssertNotNil(defaults.data(forKey: PhoneWebSearchSettings.defaultsKey))
        XCTAssertNotNil(defaults.data(forKey: PhoneWebSearchSettings.deletionDefaultsKey))
        XCTAssertEqual(secrets.value(saved.configuration.credentialRef), "old-key",
                       "the first delete failed before removing the key")
        XCTAssertFalse(settings.hasAPIKey(),
                       "a deletion-in-progress marker must not expose the old key as usable")

        try settings.remove()
        XCTAssertNil(defaults.data(forKey: PhoneWebSearchSettings.defaultsKey))
        XCTAssertNil(defaults.data(forKey: PhoneWebSearchSettings.deletionDefaultsKey))
        XCTAssertTrue(secrets.allValues().isEmpty)
    }

    func testRemoveDeletesEnumeratedLegacyAccountWithoutDocumentOrLedger() throws {
        // Older builds wrote random accounts such as
        // `search.deepseek.api.<uuid>`. Both the UserDefaults document and the
        // reference ledger may be absent after a reinstall/reset, but the
        // dedicated Keychain service survives; remove() must enumerate it.
        let legacyRef = "\(PhoneWebSearchSettings.defaultCredentialRef).\(UUID().uuidString.lowercased())"
        try secrets.setSecret("legacy-key", for: legacyRef)
        XCTAssertNil(defaults.data(forKey: PhoneWebSearchSettings.defaultsKey))
        XCTAssertNil(defaults.stringArray(forKey: PhoneWebSearchSettings.referencesDefaultsKey))
        XCTAssertNil(defaults.stringArray(forKey: PhoneWebSearchSettings.pendingDefaultsKey))

        try settings.remove()

        XCTAssertNil(secrets.value(legacyRef))
        XCTAssertTrue(secrets.allValues().isEmpty,
                      "the whole dedicated search service must be empty after removal")
        XCTAssertNil(defaults.data(forKey: PhoneWebSearchSettings.defaultsKey))
        XCTAssertNil(defaults.data(forKey: PhoneWebSearchSettings.deletionDefaultsKey),
                     "the temporary tombstone/marker is cleaned up after success")
    }

    func testRemoveDeletesEnumeratedLegacyAccountWhenTheDocumentIsCorrupt() throws {
        let legacyRef = "\(PhoneWebSearchSettings.defaultCredentialRef).\(UUID().uuidString.lowercased())"
        try secrets.setSecret("legacy-key", for: legacyRef)
        defaults.set(Data("{not-json".utf8), forKey: PhoneWebSearchSettings.defaultsKey)

        try settings.remove()

        XCTAssertNil(secrets.value(legacyRef))
        XCTAssertNil(defaults.data(forKey: PhoneWebSearchSettings.defaultsKey))
        XCTAssertNil(defaults.data(forKey: PhoneWebSearchSettings.deletionDefaultsKey))
    }

    func testRemoveWithoutEnumerationFailsBeforeDeletingAnything() throws {
        let store = NonEnumeratingWebSearchSecretStore()
        let injected = PhoneWebSearchSettings(defaults: defaults, secretStore: store)
        _ = try injected.save(mode: .searchAPI,
                              baseURL: Self.searchBase,
                              apiKey: "legacy-key")

        XCTAssertThrowsError(try injected.remove()) { error in
            XCTAssertEqual(error as? PhoneWebSearchSettingsError,
                           .secretEnumerationUnavailable)
        }
        XCTAssertNotNil(defaults.data(forKey: PhoneWebSearchSettings.defaultsKey))
        XCTAssertEqual(store.value(PhoneWebSearchSettings.defaultCredentialRef), "legacy-key")
    }

    func testRemoveEnumerationFailureKeepsKeysAndDocument() throws {
        let saved = try saveSearch(apiKey: "old-key")
        secrets.failNextEnumeration = true

        XCTAssertThrowsError(try settings.remove()) { error in
            XCTAssertEqual(error as? PhoneWebSearchSettingsError, .secretStore)
        }
        XCTAssertNotNil(defaults.data(forKey: PhoneWebSearchSettings.defaultsKey))
        XCTAssertEqual(secrets.value(saved.configuration.credentialRef), "old-key")

        try settings.remove()
        XCTAssertNil(defaults.data(forKey: PhoneWebSearchSettings.defaultsKey))
        XCTAssertTrue(secrets.allValues().isEmpty)
    }

    func testFailedClearKeepsTheKeyButCommitsAKeylessDocument() throws {
        let saved = try saveSearch(apiKey: "old-key")
        secrets.failNextDelete = true
        XCTAssertThrowsError(try settings.clearAPIKey()) { error in
            XCTAssertEqual(error as? PhoneWebSearchSettingsError, .secretStore)
        }
        XCTAssertEqual(secrets.value(saved.configuration.credentialRef), "old-key",
                       "the delete call failed before touching the item")
        XCTAssertNotNil(defaults.data(forKey: PhoneWebSearchSettings.defaultsKey))
        XCTAssertNotNil(defaults.data(forKey: PhoneWebSearchSettings.deletionDefaultsKey))
        XCTAssertFalse(storedDocumentProbe()?.hasActiveReference(saved.configuration.credentialRef) ?? true)

        try settings.clearAPIKey()
        let loaded = try settings.load()
        XCTAssertEqual(loaded.configuration.baseURL, Self.searchBase)
        XCTAssertEqual(loaded.configuration.mode, .searchAPI)
        XCTAssertFalse(loaded.hasCredential)
        XCTAssertNil(secrets.value(saved.configuration.credentialRef),
                     "the retried clear removes the old key")
        XCTAssertNil(defaults.data(forKey: PhoneWebSearchSettings.deletionDefaultsKey))
    }

    func testClearDeleteThatLandsBeforeThrowingKeepsKeylessStateAndRetryClearsMarker() throws {
        let saved = try saveSearch(apiKey: "old-key")
        secrets.deleteThenThrowNext = true

        XCTAssertThrowsError(try settings.clearAPIKey()) { error in
            XCTAssertEqual(error as? PhoneWebSearchSettingsError, .secretStore)
        }
        XCTAssertNil(secrets.value(saved.configuration.credentialRef),
                     "the delete removed the item before throwing; it must not be restored")
        XCTAssertNotNil(defaults.data(forKey: PhoneWebSearchSettings.defaultsKey))
        XCTAssertNotNil(defaults.data(forKey: PhoneWebSearchSettings.deletionDefaultsKey))
        XCTAssertFalse(storedDocumentProbe()?.hasActiveReference(saved.configuration.credentialRef) ?? true)

        let loaded = try settings.load()
        XCTAssertEqual(loaded.configuration.baseURL, Self.searchBase)
        XCTAssertEqual(loaded.configuration.mode, .searchAPI)
        XCTAssertFalse(loaded.hasCredential)
        XCTAssertNil(secrets.value(saved.configuration.credentialRef))
        XCTAssertNil(defaults.data(forKey: PhoneWebSearchSettings.deletionDefaultsKey),
                     "the retry verifies the key is gone and clears the marker")
    }

    func testClearPostDeleteReadFailureKeepsKeylessStateAndRetryClearsMarker() throws {
        let saved = try saveSearch(apiKey: "old-key")
        secrets.failNextReadAfterDelete = true

        XCTAssertThrowsError(try settings.clearAPIKey()) { error in
            XCTAssertEqual(error as? PhoneWebSearchSettingsError, .secretStore)
        }
        XCTAssertNil(secrets.value(saved.configuration.credentialRef),
                     "a failed verification read must not resurrect the old key")
        XCTAssertNotNil(defaults.data(forKey: PhoneWebSearchSettings.deletionDefaultsKey))
        XCTAssertFalse(storedDocumentProbe()?.hasActiveReference(saved.configuration.credentialRef) ?? true)

        let loaded = try settings.load()
        XCTAssertEqual(loaded.configuration.baseURL, Self.searchBase)
        XCTAssertFalse(loaded.hasCredential)
        XCTAssertNil(secrets.value(saved.configuration.credentialRef))
        XCTAssertNil(defaults.data(forKey: PhoneWebSearchSettings.deletionDefaultsKey))
    }

    func testClearCompensationIsNeverAttemptedSoAKeylessDocumentRemains() throws {
        let saved = try saveSearch(apiKey: "old-key")
        secrets.deleteThenThrowNext = true
        secrets.failNextSet = true

        XCTAssertThrowsError(try settings.clearAPIKey()) { error in
            XCTAssertEqual(error as? PhoneWebSearchSettingsError, .secretStore)
        }
        XCTAssertNotNil(defaults.data(forKey: PhoneWebSearchSettings.defaultsKey))
        XCTAssertNotNil(defaults.data(forKey: PhoneWebSearchSettings.deletionDefaultsKey))
        XCTAssertNil(secrets.value(saved.configuration.credentialRef),
                     "no compensation set may restore a key the document no longer owns")
        XCTAssertFalse(storedDocumentProbe()?.hasActiveReference(saved.configuration.credentialRef) ?? true)

        let loaded = try settings.load()
        XCTAssertEqual(loaded.configuration.baseURL, Self.searchBase)
        XCTAssertFalse(loaded.hasCredential)
        XCTAssertNil(defaults.data(forKey: PhoneWebSearchSettings.deletionDefaultsKey))
    }

    func testClearWithNoDocumentDoesNotRestoreADeletedThenThrowingDefaultKey() throws {
        try secrets.setSecret("stale-default-key",
                              for: PhoneWebSearchSettings.defaultCredentialRef)
        secrets.deleteThenThrowNext = true

        XCTAssertThrowsError(try settings.clearAPIKey()) { error in
            XCTAssertEqual(error as? PhoneWebSearchSettingsError, .secretStore)
        }
        XCTAssertNil(secrets.value(PhoneWebSearchSettings.defaultCredentialRef),
                     "the delete landed before throwing; there is no document to restore")
        XCTAssertNotNil(defaults.data(forKey: PhoneWebSearchSettings.deletionDefaultsKey))

        let loaded = try settings.load()
        XCTAssertEqual(loaded.configuration.mode, .followModel)
        XCTAssertNil(defaults.data(forKey: PhoneWebSearchSettings.deletionDefaultsKey))
    }

    func testClearAPIKeyKeepsEndpointAndRemoveDeletesDocumentAndKey() async throws {
        let saved = try saveSearch(apiKey: "old-key")
        try settings.clearAPIKey()
        let cleared = try settings.load()
        XCTAssertEqual(cleared.configuration.baseURL, Self.searchBase)
        XCTAssertEqual(cleared.configuration.mode, .searchAPI)
        XCTAssertFalse(cleared.hasCredential)
        XCTAssertNotNil(defaults.data(forKey: PhoneWebSearchSettings.defaultsKey))

        let provider = settings.makeCredentialProvider(modelProvider: model)
        do {
            _ = try await provider.credential(
                for: CredentialScope(service: Self.searchHost, audience: "/v1/tools/search"))
            XCTFail("a cleared key must fail closed")
        } catch let error as ProviderError {
            guard case .unauthorized = error else {
                return XCTFail("expected unauthorized, got \(error)")
            }
        }
        XCTAssertTrue(model.scopes.isEmpty)

        try settings.remove()
        XCTAssertNil(defaults.data(forKey: PhoneWebSearchSettings.defaultsKey))
        XCTAssertTrue(secrets.allValues().isEmpty)
        XCTAssertEqual(try settings.load().configuration.mode, .followModel)
        XCTAssertFalse(secrets.allValues().keys.contains(saved.configuration.credentialRef))
    }

    // MARK: - Persistence transactions and corrupt-document removal

    func testDocumentWriteFailureKeepsOldDocumentAndKeyAndCleansThePendingAccount() async throws {
        let first = try saveSearch(apiKey: "old-key")
        let store = InjectedWebSearchDocumentStore(
            defaults: defaults,
            key: PhoneWebSearchSettings.defaultsKey)
        let injected = PhoneWebSearchSettings(defaults: defaults,
                                              secretStore: secrets,
                                              documentStore: store)
        store.failNextWriteBefore = true

        XCTAssertThrowsError(try injected.save(mode: .searchAPI,
                                               baseURL: "https://search.example.com/v1/tools",
                                               apiKey: "new-key")) { error in
            XCTAssertEqual(error as? PhoneWebSearchSettingsError, .documentStore)
        }

        let loaded = try injected.load()
        XCTAssertEqual(loaded.configuration.baseURL, Self.searchBase)
        XCTAssertEqual(loaded.configuration.credentialRef, first.configuration.credentialRef)
        XCTAssertEqual(secrets.value(first.configuration.credentialRef), "old-key")
        XCTAssertNil(secrets.value(PhoneWebSearchSettings.alternateCredentialRef),
                     "the replacement key is rolled back when the document never commits")
        XCTAssertNil(defaults.stringArray(forKey: PhoneWebSearchSettings.pendingDefaultsKey))

        let provider = injected.makeCredentialProvider(modelProvider: model)
        let oldSearch = try await provider.credential(
            for: CredentialScope(service: Self.searchHost, audience: "/v1/tools/search"))
        XCTAssertEqual(oldSearch.value, "old-key")

        do {
            _ = try await provider.credential(
                for: CredentialScope(service: "search.example.com",
                                     audience: "/v1/tools/search"))
            XCTFail("the failed new endpoint must not receive the old search key")
        } catch let error as ProviderError {
            guard case .unauthorized = error else {
                return XCTFail("expected unauthorized, got \(error)")
            }
        }
    }

    func testSilentlyDroppedDocumentWriteDoesNotBecomeACommit() throws {
        let first = try saveSearch(apiKey: "old-key")
        let store = InjectedWebSearchDocumentStore(
            defaults: defaults,
            key: PhoneWebSearchSettings.defaultsKey)
        let injected = PhoneWebSearchSettings(defaults: defaults,
                                              secretStore: secrets,
                                              documentStore: store)
        store.dropNextWrite = true

        XCTAssertThrowsError(try injected.save(mode: .searchAPI,
                                               baseURL: "https://search.example.com/v1/tools",
                                               apiKey: "new-key")) { error in
            XCTAssertEqual(error as? PhoneWebSearchSettingsError, .documentStore)
        }

        let loaded = try injected.load()
        XCTAssertEqual(loaded.configuration.baseURL, Self.searchBase)
        XCTAssertEqual(loaded.configuration.credentialRef, first.configuration.credentialRef)
        XCTAssertEqual(secrets.value(first.configuration.credentialRef), "old-key")
        XCTAssertNil(secrets.value(PhoneWebSearchSettings.alternateCredentialRef))
    }

    func testDurableDocumentWriteFailureIsNotTreatedAsACommit() throws {
        let first = try saveSearch(apiKey: "old-key")
        let store = UserDefaultsPhoneWebSearchDocumentStore(
            defaults: defaults,
            key: PhoneWebSearchSettings.defaultsKey,
            synchronize: { false })
        let injected = PhoneWebSearchSettings(defaults: defaults,
                                              secretStore: secrets,
                                              documentStore: store)

        XCTAssertThrowsError(try injected.save(mode: .searchAPI,
                                               baseURL: "https://search.example.com/v1/tools",
                                               apiKey: "new-key")) { error in
            XCTAssertEqual(error as? PhoneWebSearchSettingsError, .documentStore)
        }

        // The attempted write was rolled back in-process, and the new key was
        // compensated; a relaunch therefore still sees the old document plus
        // its still-readable old key.
        let loaded = try settings.load()
        XCTAssertEqual(loaded.configuration.baseURL, Self.searchBase)
        XCTAssertEqual(loaded.configuration.credentialRef, first.configuration.credentialRef)
        XCTAssertTrue(loaded.hasCredential)
        XCTAssertEqual(secrets.value(first.configuration.credentialRef), "old-key")
        XCTAssertNil(secrets.value(PhoneWebSearchSettings.alternateCredentialRef))
        XCTAssertNil(defaults.stringArray(forKey: PhoneWebSearchSettings.pendingDefaultsKey))
    }

    func testNonDurableKeylessDocumentCommitNeverDeletesTheKey() throws {
        let saved = try saveSearch(apiKey: "old-key")
        let store = UserDefaultsPhoneWebSearchDocumentStore(
            defaults: defaults,
            key: PhoneWebSearchSettings.defaultsKey,
            synchronize: { false })
        let injected = PhoneWebSearchSettings(defaults: defaults,
                                              secretStore: secrets,
                                              documentStore: store)

        XCTAssertThrowsError(try injected.remove()) { error in
            XCTAssertEqual(error as? PhoneWebSearchSettingsError, .documentStore)
        }

        // The marker was durable, but the keyless document was not. No key may
        // be deleted while the old document still points at it.
        XCTAssertNotNil(defaults.data(forKey: PhoneWebSearchSettings.deletionDefaultsKey))
        XCTAssertEqual(storedDocumentProbe()?.credentialRef,
                       saved.configuration.credentialRef)
        XCTAssertEqual(secrets.value(saved.configuration.credentialRef), "old-key")

        // A working store finishes the recorded metadata commit, deletes the
        // key and removes the document, without an old-document rollback.
        let loaded = try settings.load()
        XCTAssertEqual(loaded.configuration.mode, .followModel)
        XCTAssertTrue(secrets.allValues().isEmpty)
        XCTAssertNil(defaults.data(forKey: PhoneWebSearchSettings.defaultsKey))
        XCTAssertNil(defaults.data(forKey: PhoneWebSearchSettings.deletionDefaultsKey))
    }

    func testNonDurableDeletionMarkerNeverDeletesTheKey() throws {
        let saved = try saveSearch(apiKey: "old-key")
        let documentStore = UserDefaultsPhoneWebSearchDocumentStore(
            defaults: defaults,
            key: PhoneWebSearchSettings.defaultsKey)
        let markerStore = UserDefaultsPhoneWebSearchDocumentStore(
            defaults: defaults,
            key: PhoneWebSearchSettings.deletionDefaultsKey,
            synchronize: { false })
        let injected = PhoneWebSearchSettings(defaults: defaults,
                                              secretStore: secrets,
                                              documentStore: documentStore,
                                              markerStore: markerStore)

        XCTAssertThrowsError(try injected.clearAPIKey()) { error in
            XCTAssertEqual(error as? PhoneWebSearchSettingsError, .documentStore)
        }

        XCTAssertNil(defaults.data(forKey: PhoneWebSearchSettings.deletionDefaultsKey))
        XCTAssertEqual(storedDocumentProbe()?.credentialRef,
                       saved.configuration.credentialRef,
                       "the old document is untouched when the marker is not durable")
        XCTAssertEqual(secrets.value(saved.configuration.credentialRef), "old-key")
        let loaded = try injected.load()
        XCTAssertTrue(loaded.hasCredential)
    }

    func testNonDurableClearDocumentCommitNeverDeletesTheKey() throws {
        let saved = try saveSearch(apiKey: "old-key")
        let store = UserDefaultsPhoneWebSearchDocumentStore(
            defaults: defaults,
            key: PhoneWebSearchSettings.defaultsKey,
            synchronize: { false })
        let injected = PhoneWebSearchSettings(defaults: defaults,
                                              secretStore: secrets,
                                              documentStore: store)

        XCTAssertThrowsError(try injected.clearAPIKey()) { error in
            XCTAssertEqual(error as? PhoneWebSearchSettingsError, .documentStore)
        }

        // The marker is durable but the keyless document is not. The old
        // document and its key must both still be intact.
        XCTAssertNotNil(defaults.data(forKey: PhoneWebSearchSettings.deletionDefaultsKey))
        XCTAssertEqual(storedDocumentProbe()?.credentialRef,
                       saved.configuration.credentialRef)
        XCTAssertEqual(secrets.value(saved.configuration.credentialRef), "old-key")

        // A working store completes the recorded keyless commit and only then
        // deletes the key.
        let loaded = try settings.load()
        XCTAssertEqual(loaded.configuration.mode, .searchAPI)
        XCTAssertEqual(loaded.configuration.baseURL, Self.searchBase)
        XCTAssertFalse(loaded.hasCredential)
        XCTAssertNil(secrets.value(saved.configuration.credentialRef))
        XCTAssertNil(defaults.data(forKey: PhoneWebSearchSettings.deletionDefaultsKey))
        XCTAssertEqual(storedDocumentProbe()?.credentialRef,
                       PhoneWebSearchSettings.keylessCredentialRef)
    }

    func testPartialRemoveDeleteFailureKeepsKeylessStateAndRetryFinishes() throws {
        let first = try saveSearch(apiKey: "old-key")
        let legacyRef = "\(PhoneWebSearchSettings.defaultCredentialRef).legacy-\(UUID().uuidString.lowercased())"
        try secrets.setSecret("legacy-key", for: legacyRef)
        secrets.failDeleteAfterSuccessfulDeletes = 1

        XCTAssertThrowsError(try settings.remove()) { error in
            XCTAssertEqual(error as? PhoneWebSearchSettingsError, .secretStore)
        }

        XCTAssertNotNil(defaults.data(forKey: PhoneWebSearchSettings.defaultsKey))
        XCTAssertNotNil(defaults.data(forKey: PhoneWebSearchSettings.deletionDefaultsKey))
        XCTAssertEqual(storedDocumentProbe()?.mode, .followModel)
        XCTAssertEqual(storedDocumentProbe()?.credentialRef,
                       PhoneWebSearchSettings.keylessCredentialRef)
        XCTAssertNil(secrets.value(first.configuration.credentialRef),
                     "the successful part of the delete is not restored")
        XCTAssertFalse(settings.hasAPIKey())

        // A fresh instance sees only the persisted marker, as after a relaunch.
        let restarted = PhoneWebSearchSettings(defaults: defaults, secretStore: secrets)
        try restarted.remove()
        XCTAssertTrue(secrets.allValues().isEmpty)
        XCTAssertNil(defaults.data(forKey: PhoneWebSearchSettings.defaultsKey))
        XCTAssertNil(defaults.data(forKey: PhoneWebSearchSettings.deletionDefaultsKey))
    }

    func testRemovePostDeleteVerificationReadFailureKeepsMarkerAndRetryFinishes() throws {
        let saved = try saveSearch(apiKey: "old-key")
        secrets.failNextReadAfterDelete = true

        XCTAssertThrowsError(try settings.remove()) { error in
            XCTAssertEqual(error as? PhoneWebSearchSettingsError, .secretStore)
        }

        XCTAssertNil(secrets.value(saved.configuration.credentialRef),
                     "the delete already landed; a failed verification read must not restore it")
        XCTAssertNotNil(defaults.data(forKey: PhoneWebSearchSettings.deletionDefaultsKey))
        XCTAssertEqual(storedDocumentProbe()?.mode, .followModel)

        let loaded = try settings.load()
        XCTAssertEqual(loaded.configuration.mode, .followModel)
        XCTAssertTrue(secrets.allValues().isEmpty)
        XCTAssertNil(defaults.data(forKey: PhoneWebSearchSettings.defaultsKey))
        XCTAssertNil(defaults.data(forKey: PhoneWebSearchSettings.deletionDefaultsKey))
    }

    func testUncertainDocumentReadBackDoesNotRollBackTheNewKey() throws {
        let first = try saveSearch(apiKey: "old-key")
        let store = InjectedWebSearchDocumentStore(
            defaults: defaults,
            key: PhoneWebSearchSettings.defaultsKey)
        let injected = PhoneWebSearchSettings(defaults: defaults,
                                              secretStore: secrets,
                                              documentStore: store)
        store.failReadAfterNextWrite = true

        XCTAssertThrowsError(try injected.save(mode: .searchAPI,
                                               baseURL: Self.searchBase,
                                               apiKey: "new-key")) { error in
            XCTAssertEqual(error as? PhoneWebSearchSettingsError, .documentStore)
        }

        XCTAssertEqual(secrets.value(PhoneWebSearchSettings.alternateCredentialRef), "new-key",
                       "an uncertain commit must not roll back the key the document may point at")
        XCTAssertEqual(secrets.value(first.configuration.credentialRef), "old-key",
                       "the old key is still intact for the old document")

        let loaded = try injected.load()
        XCTAssertEqual(loaded.configuration.credentialRef,
                       PhoneWebSearchSettings.alternateCredentialRef)
        XCTAssertNil(secrets.value(first.configuration.credentialRef))
        XCTAssertNil(defaults.stringArray(forKey: PhoneWebSearchSettings.pendingDefaultsKey))
    }

    func testDocumentWriteThatLandedDespiteReportedFailureIsCommitted() throws {
        let first = try saveSearch(apiKey: "old-key")
        let store = InjectedWebSearchDocumentStore(
            defaults: defaults,
            key: PhoneWebSearchSettings.defaultsKey)
        let injected = PhoneWebSearchSettings(defaults: defaults,
                                              secretStore: secrets,
                                              documentStore: store)
        store.failNextWriteAfter = true

        let rotated = try injected.save(mode: .searchAPI,
                                        baseURL: Self.searchBase,
                                        apiKey: "new-key")
        XCTAssertEqual(rotated.configuration.credentialRef,
                       PhoneWebSearchSettings.alternateCredentialRef)
        XCTAssertEqual(secrets.value(rotated.configuration.credentialRef), "new-key")
        XCTAssertEqual(secrets.value(first.configuration.credentialRef), "old-key",
                       "a save never deletes the old key")

        let loaded = try injected.load()
        XCTAssertEqual(loaded.configuration.credentialRef, rotated.configuration.credentialRef)
        XCTAssertNil(secrets.value(first.configuration.credentialRef),
                     "the load that reads the landed document retires the old account")
    }

    func testCorruptDocumentRemoveDeletesRotatedAndRawReferences() throws {
        _ = try saveSearch(apiKey: "old-key")
        _ = try saveSearch(apiKey: "new-key")
        let legacyRef = "search.deepseek.api.legacy-\(UUID().uuidString.lowercased())"
        let ledgerOnlyRef = "search.deepseek.api.ledger-\(UUID().uuidString.lowercased())"
        try secrets.setSecret("legacy-key", for: legacyRef)
        try secrets.setSecret("ledger-only-key", for: ledgerOnlyRef)
        defaults.set([ledgerOnlyRef], forKey: PhoneWebSearchSettings.referencesDefaultsKey)
        // Invalid JSON, but the raw account name is still recoverable, while
        // the fixed slots cover the rotated active/retired accounts and the
        // ledger covers an account the corrupt document no longer names.
        defaults.set(Data("{\"credentialRef\":\"\(legacyRef)\",broken".utf8),
                     forKey: PhoneWebSearchSettings.defaultsKey)

        try settings.remove()

        XCTAssertTrue(secrets.allValues().isEmpty,
                      "remove must delete fixed slots and every reference visible in a corrupt document")
        XCTAssertNil(defaults.data(forKey: PhoneWebSearchSettings.defaultsKey))
        XCTAssertNil(defaults.stringArray(forKey: PhoneWebSearchSettings.referencesDefaultsKey))
    }

    func testUnsupportedVersionRemoveUsesRawDocumentReferences() throws {
        let activeRef = "search.deepseek.api.legacy-active-\(UUID().uuidString.lowercased())"
        let retiredRef = "search.deepseek.api.legacy-retired-\(UUID().uuidString.lowercased())"
        try secrets.setSecret("active-key", for: activeRef)
        try secrets.setSecret("retired-key", for: retiredRef)
        let document: [String: Any] = [
            "version": 99,
            "mode": "search-api",
            "baseURL": Self.searchBase,
            "credentialRef": activeRef,
            "retiredCredentialRefs": [retiredRef],
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: document),
                     forKey: PhoneWebSearchSettings.defaultsKey)

        try settings.remove()

        XCTAssertTrue(secrets.allValues().isEmpty)
        XCTAssertNil(defaults.data(forKey: PhoneWebSearchSettings.defaultsKey))
    }

    func testCorruptDocumentRemoveFailureLeavesKeylessTombstoneAndRetryFinishes() throws {
        let first = try saveSearch(apiKey: "old-key")
        _ = try saveSearch(apiKey: "new-key")
        defaults.set(Data("{not-json".utf8), forKey: PhoneWebSearchSettings.defaultsKey)
        secrets.failNextDelete = true

        XCTAssertThrowsError(try settings.remove()) { error in
            XCTAssertEqual(error as? PhoneWebSearchSettingsError, .secretStore)
        }

        // The corrupt old document was replaced by the keyless tombstone before
        // the delete attempt. It must not name a key that may have been lost.
        XCTAssertNotNil(defaults.data(forKey: PhoneWebSearchSettings.defaultsKey))
        XCTAssertEqual(storedDocumentProbe()?.mode, .followModel)
        XCTAssertEqual(storedDocumentProbe()?.credentialRef,
                       PhoneWebSearchSettings.keylessCredentialRef)
        XCTAssertNotNil(defaults.data(forKey: PhoneWebSearchSettings.deletionDefaultsKey))
        XCTAssertEqual(secrets.value(first.configuration.credentialRef), "old-key")

        try settings.remove()
        XCTAssertTrue(secrets.allValues().isEmpty)
        XCTAssertNil(defaults.data(forKey: PhoneWebSearchSettings.defaultsKey))
        XCTAssertNil(defaults.data(forKey: PhoneWebSearchSettings.deletionDefaultsKey))
    }

    func testFinalDocumentRemoveFailureKeepsKeylessStateAndRetryFinishes() throws {
        let first = try saveSearch(apiKey: "old-key")
        let store = InjectedWebSearchDocumentStore(
            defaults: defaults,
            key: PhoneWebSearchSettings.defaultsKey)
        let injected = PhoneWebSearchSettings(defaults: defaults,
                                              secretStore: secrets,
                                              documentStore: store)
        store.failNextRemove = true

        XCTAssertThrowsError(try injected.remove()) { error in
            XCTAssertEqual(error as? PhoneWebSearchSettingsError, .documentStore)
        }

        XCTAssertNotNil(defaults.data(forKey: PhoneWebSearchSettings.defaultsKey))
        XCTAssertEqual(storedDocumentProbe()?.mode, .followModel)
        XCTAssertEqual(storedDocumentProbe()?.credentialRef,
                       PhoneWebSearchSettings.keylessCredentialRef)
        XCTAssertNotNil(defaults.data(forKey: PhoneWebSearchSettings.deletionDefaultsKey))
        XCTAssertNil(secrets.value(first.configuration.credentialRef),
                     "keys are deleted only after the keyless document committed")
        XCTAssertFalse(injected.hasAPIKey())

        try injected.remove()
        XCTAssertNil(defaults.data(forKey: PhoneWebSearchSettings.defaultsKey))
        XCTAssertNil(defaults.data(forKey: PhoneWebSearchSettings.deletionDefaultsKey))
        XCTAssertTrue(secrets.allValues().isEmpty)
    }

    func testCorruptDocumentClearAPIKeyFailsClosedWithoutDeletingAnyKey() throws {
        let first = try saveSearch(apiKey: "old-key")
        defaults.set(Data("{not-json".utf8), forKey: PhoneWebSearchSettings.defaultsKey)

        XCTAssertThrowsError(try settings.clearAPIKey()) { error in
            guard let settingsError = error as? PhoneWebSearchSettingsError,
                  case .invalidStoredDocument = settingsError else {
                return XCTFail("expected invalidStoredDocument, got \(error)")
            }
        }
        XCTAssertEqual(secrets.value(first.configuration.credentialRef), "old-key")
    }

    func testDocumentReadFailureFailsClosedAndRemovePreservesKeys() async throws {
        let first = try saveSearch(apiKey: "old-key")
        let store = InjectedWebSearchDocumentStore(
            defaults: defaults,
            key: PhoneWebSearchSettings.defaultsKey)
        let injected = PhoneWebSearchSettings(defaults: defaults,
                                              secretStore: secrets,
                                              documentStore: store)

        store.failNextRead = true
        XCTAssertThrowsError(try injected.load()) { error in
            XCTAssertEqual(error as? PhoneWebSearchSettingsError, .documentStore)
        }

        store.failNextRead = true
        let provider = injected.makeCredentialProvider(modelProvider: model)
        for scope in [CredentialScope(service: Self.searchHost, audience: "/v1/tools/search"),
                      CredentialScope(service: Self.searchHost, audience: "/v1/messages")] {
            do {
                _ = try await provider.credential(for: scope)
                XCTFail("a document read failure must fail closed for \(scope.audience ?? "")")
            } catch let error as ProviderError {
                guard case .unauthorized = error else {
                    return XCTFail("expected unauthorized, got \(error)")
                }
            }
        }
        XCTAssertTrue(model.scopes.isEmpty)

        store.failNextRead = true
        XCTAssertThrowsError(try injected.remove()) { error in
            XCTAssertEqual(error as? PhoneWebSearchSettingsError, .documentStore)
        }
        XCTAssertEqual(secrets.value(first.configuration.credentialRef), "old-key")
        XCTAssertNotNil(defaults.data(forKey: PhoneWebSearchSettings.defaultsKey))
    }

    // MARK: - Host/path routing

    func testSameHostRoutesSearchAndFetchToTheSearchKeyAndMessagesToTheModelKey() async throws {
        _ = try saveSearch(apiKey: "search-key")
        let provider = settings.makeCredentialProvider(modelProvider: model)

        let messagesScope = CredentialScope(service: Self.searchHost, audience: "/v1/messages")
        let messages = try await provider.credential(for: messagesScope)
        XCTAssertEqual(messages.kind, .apiKey(header: "x-api-key"))
        XCTAssertEqual(messages.value, "model-key")

        for path in ["/v1/tools/search", "/v1/tools/fetch"] {
            let search = try await provider.credential(
                for: CredentialScope(service: Self.searchHost, audience: path))
            XCTAssertEqual(search.kind, .bearer, path)
            XCTAssertEqual(search.value, "search-key", path)
        }

        let unknownPath = try await provider.credential(
            for: CredentialScope(service: Self.searchHost, audience: "/v1/tools/unknown"))
        XCTAssertEqual(unknownPath.value, "model-key")
        XCTAssertNotEqual(unknownPath.value, "search-key")

        let anonymous = try await provider.credential(
            for: CredentialScope(service: "wttr.in", audience: "/weather"))
        XCTAssertEqual(anonymous.kind, .none)

        do {
            _ = try await provider.credential(
                for: CredentialScope(service: "unknown.example", audience: "/v1/tools/search"))
            XCTFail("an unknown host must not receive either credential")
        } catch let error as ProviderError {
            guard case .unauthorized = error else {
                return XCTFail("expected unauthorized, got \(error)")
            }
        }

        await provider.invalidate(messages, for: messagesScope)
        XCTAssertEqual(model.invalidatedScopes.map(\.service), [Self.searchHost])
        let search = try await provider.credential(
            for: CredentialScope(service: Self.searchHost, audience: "/v1/tools/search"))
        await provider.invalidate(search,
                                  for: CredentialScope(service: Self.searchHost,
                                                       audience: "/v1/tools/search"))
        XCTAssertEqual(model.invalidatedScopes.count, 1,
                       "invalidating a search credential must not touch the model provider")
    }

    func testMinimalRouterInitializerAlsoRoutesTheFetchOperation() async throws {
        try secrets.setSecret("search-key", for: "search.test.ref")
        let router = PhoneWebSearchCredentialRouter(
            modelProvider: model,
            searchHost: Self.searchHost,
            searchPath: "/v1/tools/search",
            credentialRef: "search.test.ref",
            secretStore: secrets)

        for path in ["/v1/tools/search", "/v1/tools/fetch"] {
            let credential = try await router.credential(
                for: CredentialScope(service: Self.searchHost, audience: path))
            XCTAssertEqual(credential.kind, .bearer, path)
            XCTAssertEqual(credential.value, "search-key", path)
        }
    }

    func testMissingSearchKeyFailsClosedWithoutConsultingTheModelProvider() async throws {
        let keyless = try saveSearch(apiKey: nil)
        XCTAssertFalse(keyless.hasCredential)
        let provider = settings.makeCredentialProvider(modelProvider: model)

        for path in ["/v1/tools/search", "/v1/tools/fetch"] {
            do {
                _ = try await provider.credential(
                    for: CredentialScope(service: Self.searchHost, audience: path))
                XCTFail("a missing search key must fail closed for \(path)")
            } catch let error as ProviderError {
                guard case .unauthorized = error else {
                    return XCTFail("expected unauthorized, got \(error)")
                }
            }
        }
        XCTAssertTrue(model.scopes.isEmpty,
                      "a missing search key must never be replaced with the model key")
    }

    func testMissingAudienceOnTheSearchHostFailsClosed() async throws {
        _ = try saveSearch(apiKey: "search-key")
        let provider = settings.makeCredentialProvider(modelProvider: model)
        do {
            _ = try await provider.credential(for: CredentialScope(service: Self.searchHost))
            XCTFail("the search host without an audience must not receive the model key")
        } catch let error as ProviderError {
            guard case .unauthorized = error else {
                return XCTFail("expected unauthorized, got \(error)")
            }
        }
        XCTAssertTrue(model.scopes.isEmpty)
    }

    func testCorruptDocumentFailsClosedForEveryRequest() async throws {
        defaults.set(Data("{not-json".utf8), forKey: PhoneWebSearchSettings.defaultsKey)
        XCTAssertThrowsError(try settings.load()) { error in
            guard let settingsError = error as? PhoneWebSearchSettingsError,
                  case .invalidStoredDocument = settingsError else {
                return XCTFail("expected invalidStoredDocument, got \(error)")
            }
        }
        XCTAssertThrowsError(try settings.environmentEntries())
        XCTAssertThrowsError(try settings.allowedHostRules())

        let provider = settings.makeCredentialProvider(modelProvider: model)
        for scope in [CredentialScope(service: Self.searchHost, audience: "/v1/tools/search"),
                      CredentialScope(service: Self.searchHost, audience: "/v1/messages"),
                      CredentialScope(service: "unknown.example", audience: "/v1/messages")] {
            do {
                _ = try await provider.credential(for: scope)
                XCTFail("a corrupt document must fail closed for \(scope.service)")
            } catch let error as ProviderError {
                guard case .unauthorized = error else {
                    return XCTFail("expected unauthorized, got \(error)")
                }
            }
        }
        XCTAssertTrue(model.scopes.isEmpty)
    }

    // MARK: - Helpers

    @discardableResult
    private func saveSearch(baseURL: String = PhoneWebSearchSettingsTests.searchBase,
                            apiKey: String?) throws -> PhoneWebSearchSnapshot {
        try settings.save(mode: .searchAPI, baseURL: baseURL, apiKey: apiKey)
    }

    private func storedDocumentProbe() -> StoredWebSearchDocumentProbe? {
        guard let data = defaults.data(forKey: PhoneWebSearchSettings.defaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode(StoredWebSearchDocumentProbe.self, from: data)
    }
}

private struct StoredWebSearchDocumentProbe: Decodable {
    var mode: PhoneWebSearchMode
    var baseURL: String
    var credentialRef: String
    var retiredCredentialRefs: [String]?

    func hasActiveReference(_ reference: String) -> Bool {
        credentialRef == reference
    }
}

private final class InMemoryWebSearchSecretStore: PhoneWebSearchSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    var failNextSet = false
    var failNextDelete = false
    /// Allow this many successful deletes, then fail the next one. Exercises a
    /// removal that deleted only part of the dedicated service.
    var failDeleteAfterSuccessfulDeletes: Int?
    /// Remove the value, then report an error, emulating a Keychain delete that
    /// succeeded before the error surfaced.
    var deleteThenThrowNext = false
    /// Fail the first read that follows a successful delete.
    var failNextReadAfterDelete = false
    /// Fail the first enumeration attempt.
    var failNextEnumeration = false
    var failNextRead = false

    private var storedReadFailures: Set<String> = []

    func failReads(for reference: String) {
        lock.lock()
        storedReadFailures.insert(reference)
        lock.unlock()
    }

    func secret(for reference: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        if failNextRead {
            failNextRead = false
            throw ModelProviderSettingsError.keychain(-1)
        }
        if storedReadFailures.contains(reference) {
            throw ModelProviderSettingsError.keychain(-1)
        }
        return values[reference]
    }

    func setSecret(_ secret: String, for reference: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if failNextSet {
            failNextSet = false
            throw ModelProviderSettingsError.keychain(-1)
        }
        values[reference] = secret
    }

    func deleteSecret(for reference: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if failNextDelete {
            failNextDelete = false
            throw ModelProviderSettingsError.keychain(-1)
        }
        if let remaining = failDeleteAfterSuccessfulDeletes {
            if remaining <= 0 {
                failDeleteAfterSuccessfulDeletes = nil
                throw ModelProviderSettingsError.keychain(-1)
            }
            failDeleteAfterSuccessfulDeletes = remaining - 1
        }
        values.removeValue(forKey: reference)
        if failNextReadAfterDelete {
            failNextReadAfterDelete = false
            failNextRead = true
        }
        if deleteThenThrowNext {
            deleteThenThrowNext = false
            throw ModelProviderSettingsError.keychain(-1)
        }
    }

    func allReferences() throws -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        if failNextEnumeration {
            failNextEnumeration = false
            throw ModelProviderSettingsError.keychain(-1)
        }
        return Set(values.keys)
    }

    func value(_ reference: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[reference]
    }

    func allValues() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

/// A store with no reset/enumeration surface. `remove()` must fail explicitly
/// instead of pretending that the fixed slots and ledger cover every account.
private final class NonEnumeratingWebSearchSecretStore: ModelProviderSecretStore, @unchecked Sendable {
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
        values[reference] = secret
    }

    func deleteSecret(for reference: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: reference)
    }

    func value(_ reference: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[reference]
    }
}

private final class InjectedWebSearchDocumentStore: PhoneWebSearchDocumentStore {
    private let defaults: UserDefaults
    private let key: String

    var failNextRead = false
    var failNextWriteBefore = false
    var failNextWriteAfter = false
    var failReadAfterNextWrite = false
    var dropNextWrite = false
    var failNextRemove = false

    init(defaults: UserDefaults, key: String) {
        self.defaults = defaults
        self.key = key
    }

    func read() throws -> Data? {
        if failNextRead {
            failNextRead = false
            throw PhoneWebSearchSettingsError.documentStore
        }
        return defaults.data(forKey: key)
    }

    func write(_ data: Data) throws {
        if failNextWriteBefore {
            failNextWriteBefore = false
            throw PhoneWebSearchSettingsError.documentStore
        }
        if dropNextWrite {
            dropNextWrite = false
            return
        }
        defaults.set(data, forKey: key)
        _ = defaults.synchronize()
        if failReadAfterNextWrite {
            failReadAfterNextWrite = false
            failNextRead = true
        }
        if failNextWriteAfter {
            failNextWriteAfter = false
            throw PhoneWebSearchSettingsError.documentStore
        }
    }

    func remove() throws {
        if failNextRemove {
            failNextRemove = false
            throw PhoneWebSearchSettingsError.documentStore
        }
        defaults.removeObject(forKey: key)
        _ = defaults.synchronize()
    }
}

private final class RecordingModelCredentialProvider: CredentialProvider, @unchecked Sendable {
    let modelHost: String
    let modelValue: String
    let anonymousHosts: Set<String>

    private let lock = NSLock()
    private var storedScopes: [CredentialScope] = []
    private var storedInvalidatedScopes: [CredentialScope] = []

    init(modelHost: String, modelValue: String, anonymousHosts: Set<String>) {
        self.modelHost = modelHost.lowercased()
        self.modelValue = modelValue
        self.anonymousHosts = Set(anonymousHosts.map { $0.lowercased() })
    }

    var scopes: [CredentialScope] {
        lock.lock()
        defer { lock.unlock() }
        return storedScopes
    }

    var invalidatedScopes: [CredentialScope] {
        lock.lock()
        defer { lock.unlock() }
        return storedInvalidatedScopes
    }

    func credential(for scope: CredentialScope) async throws -> Credential {
        lock.lock()
        storedScopes.append(scope)
        lock.unlock()
        if scope.service.lowercased() == modelHost {
            return Credential(kind: .apiKey(header: "x-api-key"), value: modelValue)
        }
        if anonymousHosts.contains(scope.service.lowercased()) {
            return Credential.none
        }
        throw ProviderError.unauthorized("unknown host \(scope.service)")
    }

    func invalidate(_ credential: Credential, for scope: CredentialScope) async {
        lock.lock()
        storedInvalidatedScopes.append(scope)
        lock.unlock()
    }
}
