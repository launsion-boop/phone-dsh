// SPDX-License-Identifier: MIT
// Model provider settings: validation, legacy migration, crash-safe secret
// ordering, UserDefaults/Keychain separation and the launch plan the host
// wiring consumes. The secret store is in-memory, so the suite never reads or
// writes the real Keychain.

import Foundation
import XCTest
import PhoneDSHAgentCore
@testable import PhoneDSH

final class PhoneModelProviderSettingsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var secrets: InMemoryModelProviderSecretStore!
    private var settings: PhoneModelProviderSettings!

    override func setUp() {
        super.setUp()
        suiteName = "PhoneModelProviderSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        secrets = InMemoryModelProviderSecretStore()
        settings = PhoneModelProviderSettings(defaults: defaults, secretStore: secrets)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        secrets = nil
        settings = nil
        super.tearDown()
    }

    private func profile(id: String = "deepseek",
                         displayName: String = "DeepSeek",
                         baseURL: String = "https://api.example.com/anthropic",
                         model: String = "deepseek-flash",
                         reasoningEffort: String? = "high",
                         credentialRef: String? = nil) -> ProviderProfile {
        ProviderProfile(id: id,
                        displayName: displayName,
                        baseURL: baseURL,
                        model: model,
                        reasoningEffort: reasoningEffort,
                        credentialRef: credentialRef)
    }

    func testValidationRejectsEmptyIDsAndNonHTTPEndpoints() {
        XCTAssertThrowsError(try settings.upsert(profile(id: "   "))) { error in
            XCTAssertEqual(error as? ModelProviderSettingsError, .emptyID)
        }
        XCTAssertThrowsError(try settings.upsert(profile(id: "has space"))) { error in
            XCTAssertEqual(error as? ModelProviderSettingsError, .invalidID("has space"))
        }
        XCTAssertThrowsError(try settings.upsert(profile(baseURL: "ftp://api.example.com"))) { error in
            guard case .invalidBaseURL = error as? ModelProviderSettingsError else {
                return XCTFail("expected invalidBaseURL, got \(error)")
            }
        }
        XCTAssertThrowsError(try settings.upsert(profile(baseURL: "https:///missing-host"))) { error in
            guard case .invalidBaseURL = error as? ModelProviderSettingsError else {
                return XCTFail("expected invalidBaseURL, got \(error)")
            }
        }
        XCTAssertThrowsError(try settings.upsert(profile(model: "  "))) { error in
            XCTAssertEqual(error as? ModelProviderSettingsError, .emptyModel)
        }
    }

    func testUpsertKeepsIDsUniqueAndSelectsTheFirstProfile() throws {
        try settings.upsert(profile(id: "first"), apiKey: "first-secret")
        try settings.upsert(profile(id: "second", displayName: "Second"), apiKey: "second-secret")
        var snapshot = try settings.load()
        XCTAssertEqual(snapshot.profiles.map(\.id), ["first", "second"])
        XCTAssertEqual(snapshot.selectedID, "first")

        try settings.upsert(profile(id: "first", displayName: "Renamed"), apiKey: nil)
        snapshot = try settings.load()
        XCTAssertEqual(snapshot.profiles.map(\.id), ["first", "second"])
        XCTAssertEqual(snapshot.profiles.first?.displayName, "Renamed")
        XCTAssertEqual(try settings.apiKey(for: "first"), "first-secret")
    }

    func testNonSecretDocumentNeverContainsTheKey() throws {
        let key = "sk-test-never-store-me"
        try settings.upsert(profile(), apiKey: key)

        let data = try XCTUnwrap(defaults.data(forKey: PhoneModelProviderSettings.defaultsKey))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains(key))
        XCTAssertFalse(json.contains("apiKey"))
        XCTAssertFalse(json.contains("secret"))
        XCTAssertEqual(secrets.values["provider.deepseek"], key)
    }

    func testSelectRemoveAndKeyDeletion() throws {
        try settings.upsert(profile(id: "a", displayName: "A"), apiKey: "a-key")
        try settings.upsert(profile(id: "b", displayName: "B"), apiKey: "b-key")
        try settings.select(id: "b")
        XCTAssertEqual(try settings.load().selected?.id, "b")

        try settings.remove(id: "b")
        let afterRemove = try settings.load()
        XCTAssertEqual(afterRemove.profiles.map(\.id), ["a"])
        XCTAssertEqual(afterRemove.selectedID, "a")
        XCTAssertNil(secrets.values["provider.b"])

        try settings.removeAPIKey(for: "a")
        XCTAssertNil(secrets.values["provider.a"])
        XCTAssertEqual(try settings.load().selected?.id, "a")
    }

    func testFirstLoadMigratesLegacyDefaultsAndKeychainIntoTheDefaultProfile() throws {
        defaults.set("https://legacy.example/anthropic", forKey: "chat.model.baseURL")
        defaults.set("legacy-model", forKey: "chat.model.name")
        secrets.values["model-api-key"] = "legacy-key"

        let snapshot = try settings.load()
        XCTAssertEqual(snapshot.profiles.count, 1)
        let migrated = try XCTUnwrap(snapshot.selected)
        XCTAssertEqual(migrated.id, "default")
        XCTAssertEqual(snapshot.selectedID, migrated.id)
        XCTAssertEqual(migrated.baseURL, "https://legacy.example/anthropic")
        XCTAssertEqual(migrated.model, "legacy-model")
        XCTAssertEqual(migrated.credentialRef, "provider.default")
        XCTAssertEqual(try settings.apiKey(for: migrated.id), "legacy-key")

        // The non-secret legacy fields and the old account are cleaned only
        // after the new document committed.
        XCTAssertNil(defaults.object(forKey: "chat.model.baseURL"))
        XCTAssertNil(defaults.object(forKey: "chat.model.name"))
        XCTAssertNil(secrets.values["model-api-key"])
        XCTAssertEqual(secrets.values["provider.default"], "legacy-key")
        XCTAssertNotNil(defaults.data(forKey: PhoneModelProviderSettings.defaultsKey))

        let reloaded = try settings.load()
        XCTAssertEqual(reloaded.profiles.map(\.id), ["default"])
        XCTAssertEqual(try settings.apiKey(for: "default"), "legacy-key")
    }

    func testFirstLoadMigratesLegacyEnvironmentWithoutWritingItsKeyToDefaults() throws {
        let environmentSettings = PhoneModelProviderSettings(
            defaults: defaults,
            secretStore: secrets,
            environment: [
                "PDSH_MODEL_BASE_URL": "https://env.example/v1",
                "PDSH_MODEL_NAME": "env-model",
                "PDSH_MODEL_API_KEY": "env-key",
            ])
        let snapshot = try environmentSettings.load()
        let migrated = try XCTUnwrap(snapshot.selected)
        XCTAssertEqual(migrated.baseURL, "https://env.example/v1")
        XCTAssertEqual(migrated.model, "env-model")
        XCTAssertEqual(migrated.credentialRef, "provider.default")
        XCTAssertEqual(secrets.values["provider.default"], "env-key")
        XCTAssertNil(secrets.values["model-api-key"])

        let data = try XCTUnwrap(defaults.data(forKey: PhoneModelProviderSettings.defaultsKey))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("env-key"))
        XCTAssertFalse(json.contains("apiKey"))
    }

    func testLegacyKeychainReadFailureDoesNotCommitOrDeleteTheOldKey() throws {
        defaults.set("https://legacy.example/anthropic", forKey: "chat.model.baseURL")
        defaults.set("legacy-model", forKey: "chat.model.name")
        secrets.values["model-api-key"] = "legacy-key"
        secrets.readFailures.insert("model-api-key")

        let environmentSettings = PhoneModelProviderSettings(
            defaults: defaults,
            secretStore: secrets,
            environment: ["PDSH_MODEL_API_KEY": "env-key"])
        let fallback = try environmentSettings.load()
        let profile = try XCTUnwrap(fallback.selected)
        XCTAssertEqual(profile.id, "default")
        XCTAssertEqual(profile.credentialRef, "model-api-key")
        XCTAssertEqual(profile.baseURL, "https://legacy.example/anthropic")
        XCTAssertEqual(profile.model, "legacy-model")

        // A read failure is not "no key": nothing was committed, no legacy
        // default was removed and the environment key did not replace the
        // unreadable device account.
        XCTAssertNil(defaults.data(forKey: PhoneModelProviderSettings.defaultsKey))
        XCTAssertEqual(defaults.string(forKey: "chat.model.baseURL"), "https://legacy.example/anthropic")
        XCTAssertEqual(defaults.string(forKey: "chat.model.name"), "legacy-model")
        XCTAssertEqual(secrets.values["model-api-key"], "legacy-key")
        XCTAssertNil(secrets.values["provider.default"])
        XCTAssertFalse(secrets.values.values.contains("env-key"))

        secrets.readFailures.remove("model-api-key")
        let migrated = try environmentSettings.load()
        let migratedProfile = try XCTUnwrap(migrated.selected)
        XCTAssertEqual(migratedProfile.credentialRef, "provider.default")
        XCTAssertEqual(secrets.values["provider.default"], "legacy-key")
        XCTAssertNil(secrets.values["model-api-key"])
        XCTAssertNotNil(defaults.data(forKey: PhoneModelProviderSettings.defaultsKey))
    }

    func testMissingLegacyKeyIsNotAReadFailureAndStillMigratesTheEndpoint() throws {
        defaults.set("https://legacy.example/anthropic", forKey: "chat.model.baseURL")
        defaults.set("legacy-model", forKey: "chat.model.name")

        let snapshot = try settings.load()
        let profile = try XCTUnwrap(snapshot.selected)
        XCTAssertEqual(profile.credentialRef, "provider.default")
        XCTAssertEqual(profile.baseURL, "https://legacy.example/anthropic")
        XCTAssertNotNil(defaults.data(forKey: PhoneModelProviderSettings.defaultsKey))
        XCTAssertNil(secrets.values["provider.default"])
        XCTAssertNil(secrets.values["model-api-key"])
    }

    func testLegacyMigrationWriteFailureKeepsTheOldAccountAndFields() throws {
        defaults.set("https://legacy.example/anthropic", forKey: "chat.model.baseURL")
        defaults.set("legacy-model", forKey: "chat.model.name")
        secrets.values["model-api-key"] = "legacy-key"
        secrets.setFailures.insert("provider.default")

        let fallback = try settings.load()
        let fallbackProfile = try XCTUnwrap(fallback.selected)
        XCTAssertEqual(fallbackProfile.credentialRef, "model-api-key")
        XCTAssertNil(defaults.data(forKey: PhoneModelProviderSettings.defaultsKey))
        XCTAssertEqual(defaults.string(forKey: "chat.model.baseURL"), "https://legacy.example/anthropic")
        XCTAssertEqual(defaults.string(forKey: "chat.model.name"), "legacy-model")
        XCTAssertEqual(secrets.values["model-api-key"], "legacy-key")
        // The failed migration must not leave the legacy account queued for a
        // later unrelated document write to delete.
        XCTAssertNil(defaults.stringArray(forKey: PhoneModelProviderSettings.pendingSecretDeletionsKey))

        secrets.setFailures.remove("provider.default")
        let migrated = try settings.load()
        let migratedProfile = try XCTUnwrap(migrated.selected)
        XCTAssertEqual(migratedProfile.credentialRef, "provider.default")
        XCTAssertEqual(secrets.values["provider.default"], "legacy-key")
        XCTAssertNil(secrets.values["model-api-key"])
    }

    func testLegacyValuesDoNotOverwriteAnExistingProviderDocument() throws {
        try settings.upsert(profile(id: "current"), apiKey: "current-key")
        defaults.set("https://legacy.example", forKey: "chat.model.baseURL")
        defaults.set("legacy-model", forKey: "chat.model.name")
        secrets.values["model-api-key"] = "legacy-key"

        let snapshot = try settings.load()
        XCTAssertEqual(snapshot.profiles.map(\.id), ["current"])
        XCTAssertEqual(try settings.apiKey(for: "current"), "current-key")
    }

    func testRemoveCommitsTheDocumentBeforeDeletingTheKeyAndReconcilesAnOrphan() throws {
        try settings.upsert(profile(id: "a"), apiKey: "a-key")
        secrets.deleteFailures.insert("provider.a")

        try settings.remove(id: "a")
        XCTAssertTrue(try settings.load().profiles.isEmpty)
        // The document is committed; the leftover key is an orphan, not a
        // profile pointing at a deleted credential.
        XCTAssertEqual(secrets.values["provider.a"], "a-key")

        secrets.deleteFailures.remove("provider.a")
        _ = try settings.load()
        XCTAssertNil(secrets.values["provider.a"])
    }

    func testFailedSecretWriteDoesNotPersistTheProfileChange() throws {
        try settings.upsert(profile(id: "a", displayName: "Original"), apiKey: "a-key")
        secrets.setFailures.insert("provider.a")

        XCTAssertThrowsError(try settings.upsert(profile(id: "a", displayName: "Changed"), apiKey: "new-key")) { error in
            XCTAssertEqual(error as? ModelProviderSettingsError, .keychain(-1))
        }
        let snapshot = try settings.load()
        XCTAssertEqual(snapshot.profiles.first?.displayName, "Original")
        XCTAssertEqual(secrets.values["provider.a"], "a-key")
    }

    func testKeyDeletionAfterCommitIsRetryableAndNeverLosesTheProfile() throws {
        try settings.upsert(profile(), apiKey: "host-key")
        secrets.deleteFailures.insert("provider.deepseek")

        XCTAssertThrowsError(try settings.upsert(profile(), apiKey: "")) { error in
            XCTAssertEqual(error as? ModelProviderSettingsError, .keychain(-1))
        }
        XCTAssertEqual(try settings.load().profiles.count, 1)
        XCTAssertEqual(secrets.values["provider.deepseek"], "host-key")

        secrets.deleteFailures.remove("provider.deepseek")
        try settings.upsert(profile(), apiKey: "")
        XCTAssertNil(secrets.values["provider.deepseek"])
    }

    func testChangingCredentialReferenceMigratesTheKeyToTheNewAccount() throws {
        try settings.upsert(profile(id: "a", credentialRef: "provider.old"), apiKey: "old-key")
        try settings.upsert(profile(id: "a", credentialRef: "provider.new"), apiKey: nil)

        // `apiKey: nil` means "keep the current one", so the secret must move
        // to the new account instead of being deleted with the old one.
        XCTAssertNil(secrets.values["provider.old"])
        XCTAssertEqual(secrets.values["provider.new"], "old-key")
        XCTAssertEqual(try settings.load().profiles.first?.credentialRef, "provider.new")
        XCTAssertEqual(try settings.apiKey(for: "a"), "old-key")
    }

    func testChangingCredentialReferenceReadFailureKeepsTheOldKeyAndDocument() throws {
        try settings.upsert(profile(id: "a", credentialRef: "provider.old"), apiKey: "old-key")
        secrets.readFailures.insert("provider.old")

        XCTAssertThrowsError(try settings.upsert(profile(id: "a", credentialRef: "provider.new"),
                                                 apiKey: nil)) { error in
            XCTAssertEqual(error as? ModelProviderSettingsError, .keychain(-1))
        }
        XCTAssertEqual(try settings.load().profiles.first?.credentialRef, "provider.old")
        XCTAssertEqual(secrets.values["provider.old"], "old-key")
        XCTAssertNil(secrets.values["provider.new"])

        secrets.readFailures.remove("provider.old")
        try settings.upsert(profile(id: "a", credentialRef: "provider.new"), apiKey: nil)
        XCTAssertEqual(secrets.values["provider.new"], "old-key")
        XCTAssertNil(secrets.values["provider.old"])
    }

    func testChangingCredentialReferenceWriteFailureKeepsTheOldKeyAndDocument() throws {
        try settings.upsert(profile(id: "a", credentialRef: "provider.old"), apiKey: "old-key")
        secrets.setFailures.insert("provider.new")

        XCTAssertThrowsError(try settings.upsert(profile(id: "a", credentialRef: "provider.new"),
                                                 apiKey: nil)) { error in
            XCTAssertEqual(error as? ModelProviderSettingsError, .keychain(-1))
        }
        XCTAssertEqual(try settings.load().profiles.first?.credentialRef, "provider.old")
        XCTAssertEqual(secrets.values["provider.old"], "old-key")
        XCTAssertNil(secrets.values["provider.new"])

        secrets.setFailures.remove("provider.new")
        try settings.upsert(profile(id: "a", credentialRef: "provider.new"), apiKey: nil)
        XCTAssertEqual(secrets.values["provider.new"], "old-key")
        XCTAssertNil(secrets.values["provider.old"])
    }

    func testCreateRejectsDuplicateIDWithoutReplacingTheExistingProfile() throws {
        try settings.upsert(profile(id: "first",
                                    baseURL: "https://first.example",
                                    model: "first-model"), apiKey: "first-key")

        XCTAssertThrowsError(try settings.create(profile(id: "first",
                                                         displayName: "Replacement",
                                                         baseURL: "https://other.example",
                                                         model: "other-model"),
                                                 apiKey: "new-key")) { error in
            XCTAssertEqual(error as? ModelProviderSettingsError, .duplicateProviderID("first"))
        }

        let snapshot = try settings.load()
        XCTAssertEqual(snapshot.profiles.count, 1)
        XCTAssertEqual(snapshot.profiles.first?.baseURL, "https://first.example")
        XCTAssertEqual(snapshot.profiles.first?.model, "first-model")
        XCTAssertEqual(secrets.values["provider.first"], "first-key")
        XCTAssertEqual(try settings.apiKey(for: "first"), "first-key")
    }

    func testChangingCredentialReferenceCommitsTheDocumentBeforeDeletingTheOldAccount() throws {
        try settings.upsert(profile(id: "a", credentialRef: "provider.old"), apiKey: "old-key")
        let defaults = self.defaults!
        var observedDeleteAfterCommit = false
        secrets.onDelete = { reference in
            guard reference == "provider.old" else { return }
            observedDeleteAfterCommit = true
            let data = try XCTUnwrap(defaults.data(forKey: PhoneModelProviderSettings.defaultsKey))
            let json = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertTrue(json.contains("\"provider.new\""))
            XCTAssertFalse(json.contains("\"provider.old\""))
        }

        try settings.upsert(profile(id: "a", credentialRef: "provider.new"), apiKey: "new-key")
        XCTAssertTrue(observedDeleteAfterCommit)
        XCTAssertEqual(secrets.values["provider.new"], "new-key")
        XCTAssertNil(secrets.values["provider.old"])
        XCTAssertEqual(try settings.load().profiles.first?.credentialRef, "provider.new")
    }

    func testOldCredentialDeleteFailureLeavesAnOrphanForTheNextLoad() throws {
        try settings.upsert(profile(id: "a", credentialRef: "provider.old"), apiKey: "old-key")
        secrets.deleteFailures.insert("provider.old")

        try settings.upsert(profile(id: "a", credentialRef: "provider.new"), apiKey: "new-key")
        XCTAssertEqual(try settings.load().profiles.first?.credentialRef, "provider.new")
        XCTAssertEqual(secrets.values["provider.new"], "new-key")
        XCTAssertEqual(secrets.values["provider.old"], "old-key")

        secrets.deleteFailures.remove("provider.old")
        _ = try settings.load()
        XCTAssertNil(secrets.values["provider.old"])
        XCTAssertEqual(secrets.values["provider.new"], "new-key")
    }

    func testPendingDeletionNeverRemovesAKeyStillReferencedByTheDocument() throws {
        try settings.upsert(profile(), apiKey: "host-key")
        defaults.set(["provider.deepseek"],
                     forKey: PhoneModelProviderSettings.pendingSecretDeletionsKey)

        _ = try settings.load()
        XCTAssertEqual(secrets.values["provider.deepseek"], "host-key")
        XCTAssertNil(defaults.stringArray(forKey: PhoneModelProviderSettings.pendingSecretDeletionsKey))
    }

    func testAPIKeyStatusKeepsMissingPresentAndReadFailureDistinct() throws {
        try settings.upsert(profile(id: "a"), apiKey: nil)
        XCTAssertEqual(try settings.apiKeyStatus(for: "a"), .missing)
        XCTAssertFalse(try settings.hasAPIKey(for: "a"))

        try settings.upsert(profile(id: "a"), apiKey: "stored-key")
        XCTAssertEqual(try settings.apiKeyStatus(for: "a"), .present)
        XCTAssertTrue(try settings.hasAPIKey(for: "a"))

        secrets.readFailures.insert("provider.a")
        // A failed Keychain read is not "no key": the page must be able to tell
        // the user that it cannot safely replace or delete the credential.
        XCTAssertEqual(try settings.apiKeyStatus(for: "a"), .unreadable)
        XCTAssertThrowsError(try settings.hasAPIKey(for: "a")) { error in
            XCTAssertEqual(error as? ModelProviderSettingsError, .keychain(-1))
        }
        // Neither query may have damaged the stored value.
        XCTAssertEqual(secrets.values["provider.a"], "stored-key")
    }

    func testSecretIntentPrefersANewKeyOverAStaleDeleteToggle() {
        // The editor clears the toggle when a key is typed, and the payload rule
        // repeats that precedence so a late toggle change cannot discard it.
        let replacement = PhoneModelProviderSettings.secretIntent(enteredKey: " new-key ",
                                                                  deleteStoredKey: true)
        XCTAssertEqual(replacement, .replace("new-key"))
        XCTAssertEqual(replacement.apiKeyArgument, "new-key")

        XCTAssertEqual(PhoneModelProviderSettings.secretIntent(enteredKey: "   ",
                                                               deleteStoredKey: true),
                       .delete)
        XCTAssertEqual(PhoneModelProviderSettings.secretIntent(enteredKey: "",
                                                               deleteStoredKey: true).apiKeyArgument,
                       "")
        XCTAssertEqual(PhoneModelProviderSettings.secretIntent(enteredKey: "  ",
                                                               deleteStoredKey: false),
                       .keep)
        XCTAssertNil(PhoneModelProviderSettings.secretIntent(enteredKey: "",
                                                             deleteStoredKey: false).apiKeyArgument)
    }

    func testInterruptedFirstCreateWithoutDocumentCleansTheOrphanedKey() throws {
        // The key is written before the document. Simulate a crash after that
        // write by failing the store's post-write hook: no document exists, the
        // pending sidecar names the new account and only the key remains.
        secrets.onSet = { reference in
            if reference == "provider.orphan" {
                throw ModelProviderSettingsError.keychain(-1)
            }
        }
        XCTAssertThrowsError(try settings.create(profile(id: "orphan"), apiKey: "orphan-key"))
        XCTAssertNil(defaults.data(forKey: PhoneModelProviderSettings.defaultsKey))
        XCTAssertEqual(secrets.values["provider.orphan"], "orphan-key")
        XCTAssertEqual(defaults.stringArray(forKey: PhoneModelProviderSettings.pendingSecretDeletionsKey),
                       ["provider.orphan"])

        secrets.onSet = nil
        let recovered = try settings.load()
        XCTAssertTrue(recovered.profiles.isEmpty)
        XCTAssertNil(secrets.values["provider.orphan"])
        XCTAssertNil(defaults.stringArray(forKey: PhoneModelProviderSettings.pendingSecretDeletionsKey))
    }

    func testNoDocumentRecoveryKeepsAKeyAMigrationStillNeeds() throws {
        // A crash during legacy migration leaves no document and both accounts
        // queued. The no-document recovery path must not flush the legacy account
        // before the migration has copied it to the committed provider account.
        defaults.set("https://legacy.example/anthropic", forKey: "chat.model.baseURL")
        defaults.set("legacy-model", forKey: "chat.model.name")
        secrets.values["model-api-key"] = "legacy-key"
        secrets.values["provider.default"] = "legacy-key"
        defaults.set(["model-api-key", "provider.default"],
                     forKey: PhoneModelProviderSettings.pendingSecretDeletionsKey)

        let migrated = try settings.load()
        XCTAssertEqual(try XCTUnwrap(migrated.selected).credentialRef, "provider.default")
        XCTAssertEqual(secrets.values["provider.default"], "legacy-key")
        XCTAssertNil(secrets.values["model-api-key"])
        XCTAssertNotNil(defaults.data(forKey: PhoneModelProviderSettings.defaultsKey))
    }

    func testInvalidLegacyEndpointWithKeyIsPreservedAndNeverSentToANewHost() throws {
        // The old settings page accepted arbitrary base URLs. Even when the
        // stored endpoint can no longer be normalized, the Keychain value is
        // still the user's only real key: a no-document load with a pending
        // sidecar must not treat it as an interrupted-create orphan. This URL
        // passes `URL`'s scheme/host check but is rejected by `normalized`
        // because of its query, so the launch path needs the same stricter rule.
        let invalidEndpoint = "https://legacy.example/anthropic?mode=legacy"
        defaults.set(invalidEndpoint, forKey: "chat.model.baseURL")
        defaults.set("legacy-model", forKey: "chat.model.name")
        secrets.values["model-api-key"] = "legacy-key"
        // A pending account from an interrupted first create is a genuine
        // orphan and must still be reconciled on this no-document path; only
        // the legacy account and the migration target are protected.
        secrets.values["provider.orphan"] = "orphan-key"
        defaults.set(["model-api-key", "provider.orphan"],
                     forKey: PhoneModelProviderSettings.pendingSecretDeletionsKey)

        let preserved = try settings.load()
        let profile = try XCTUnwrap(preserved.selected)
        XCTAssertEqual(profile.id, "default")
        XCTAssertEqual(profile.credentialRef, "model-api-key")
        XCTAssertEqual(profile.baseURL, invalidEndpoint)
        XCTAssertEqual(profile.model, "legacy-model")

        // The migration did not commit and no copy was written to the normal
        // account, so the legacy key is untouched and still the only copy.
        XCTAssertNil(defaults.data(forKey: PhoneModelProviderSettings.defaultsKey))
        XCTAssertEqual(secrets.values["model-api-key"], "legacy-key")
        XCTAssertNil(secrets.values["provider.default"])
        // The unrelated interrupted-create account is still cleaned up.
        XCTAssertNil(secrets.values["provider.orphan"])

        // The invalid endpoint fails closed instead of silently switching to
        // the built-in endpoint, which would send the legacy key to a new host.
        XCTAssertThrowsError(try settings.environmentEntries()) { error in
            XCTAssertEqual(error as? ModelProviderSettingsError, .invalidBaseURL(invalidEndpoint))
        }
        XCTAssertThrowsError(try settings.makeCredentialProvider()) { error in
            XCTAssertEqual(error as? ModelProviderSettingsError, .invalidBaseURL(invalidEndpoint))
        }
        XCTAssertEqual(secrets.values["model-api-key"], "legacy-key")
        XCTAssertNil(secrets.values["provider.default"])
        XCTAssertFalse(secrets.reads.contains("provider.default"))

        // Repairing the endpoint in place keeps using the preserved account.
        try settings.upsert(ProviderProfile(id: "default",
                                            displayName: "Default model service",
                                            baseURL: "https://legacy.example/anthropic",
                                            model: "legacy-model",
                                            credentialRef: "model-api-key"),
                            apiKey: nil)
        XCTAssertEqual(try settings.apiKey(for: "default"), "legacy-key")
        XCTAssertEqual(secrets.values["model-api-key"], "legacy-key")
        XCTAssertNil(secrets.values["provider.default"])
    }

    func testInvalidLegacyRepairSnapshotCannotBeCommittedAsADocument() throws {
        let invalidEndpoint = "https://legacy.example/anthropic?mode=legacy"
        defaults.set(invalidEndpoint, forKey: "chat.model.baseURL")
        defaults.set("legacy-model", forKey: "chat.model.name")
        secrets.values["model-api-key"] = "legacy-key"

        _ = try settings.load()
        // Adding another service while the preserved legacy profile still has
        // an unnormalized endpoint must fail before a document is written;
        // otherwise the next load would reject the document and lock the user
        // out of repairing it.
        XCTAssertThrowsError(try settings.create(profile(id: "other",
                                                         baseURL: "https://other.example",
                                                         model: "other-model"),
                                                 apiKey: "other-key")) { error in
            XCTAssertEqual(error as? ModelProviderSettingsError, .invalidBaseURL(invalidEndpoint))
        }
        XCTAssertNil(defaults.data(forKey: PhoneModelProviderSettings.defaultsKey))
        XCTAssertEqual(secrets.values["model-api-key"], "legacy-key")
        XCTAssertNil(secrets.values["provider.other"])

        // Repairing the legacy profile itself is still possible and commits a
        // document the store can decode again.
        try settings.upsert(ProviderProfile(id: "default",
                                            displayName: "Default model service",
                                            baseURL: "https://legacy.example/anthropic",
                                            model: "legacy-model",
                                            credentialRef: "model-api-key"),
                            apiKey: nil)
        XCTAssertNotNil(defaults.data(forKey: PhoneModelProviderSettings.defaultsKey))
        XCTAssertEqual(try settings.apiKey(for: "default"), "legacy-key")
    }

    func testInvalidLegacyRecoveryKeepsAPendingMigrationTargetAccount() throws {
        let invalidEndpoint = "https://legacy.example/anthropic?mode=legacy"
        defaults.set(invalidEndpoint, forKey: "chat.model.baseURL")
        defaults.set("legacy-model", forKey: "chat.model.name")
        // A crash during legacy migration can leave a copy in the migration
        // target account before the document commits. The fallback snapshot
        // references only `model-api-key`, so this value survives solely
        // because the no-document recovery protects `provider.default`.
        secrets.values["provider.default"] = "migrated-copy"
        defaults.set(["model-api-key", "provider.default"],
                     forKey: PhoneModelProviderSettings.pendingSecretDeletionsKey)

        let preserved = try settings.load()
        XCTAssertEqual(try XCTUnwrap(preserved.selected).credentialRef, "model-api-key")
        XCTAssertEqual(secrets.values["provider.default"], "migrated-copy")
        XCTAssertNil(defaults.data(forKey: PhoneModelProviderSettings.defaultsKey))
    }

    func testCorruptOrDuplicateStoredDocumentsFailClosed() throws {
        let duplicate = """
        {"version":1,"selectedId":"a","providers":[
          {"id":"a","displayName":"A","baseURL":"https://a.example","model":"m","credentialRef":"provider.a"},
          {"id":"a","displayName":"A2","baseURL":"https://b.example","model":"m","credentialRef":"provider.a2"}
        ]}
        """
        defaults.set(Data(duplicate.utf8), forKey: PhoneModelProviderSettings.defaultsKey)
        XCTAssertThrowsError(try settings.load()) { error in
            XCTAssertEqual(error as? ModelProviderSettingsError, .duplicateProviderID("a"))
        }

        let missingSelection = """
        {"version":1,"selectedId":"nope","providers":[
          {"id":"a","displayName":"A","baseURL":"https://a.example","model":"m","credentialRef":"provider.a"}
        ]}
        """
        defaults.set(Data(missingSelection.utf8), forKey: PhoneModelProviderSettings.defaultsKey)
        XCTAssertThrowsError(try settings.load()) { error in
            guard case .invalidStoredDocument = error as? ModelProviderSettingsError else {
                return XCTFail("expected invalidStoredDocument, got \(error)")
            }
        }
    }

    func testCredentialProviderReadsTheKeychainOnlyForTheSelectedHost() async throws {
        try settings.upsert(profile(), apiKey: "host-key")
        let provider = try settings.makeCredentialProvider(egressAllowHosts: ["wttr.in", "*.example.org"])
        let model = try await provider.credential(
            for: CredentialScope(service: "api.example.com",
                                 audience: "/anthropic/v1/messages",
                                 scheme: "https",
                                 port: 443))
        XCTAssertEqual(model.kind, .apiKey(header: "x-api-key"))
        XCTAssertEqual(model.value, "host-key")
        let readsAfterModelHost = secrets.reads
        XCTAssertEqual(readsAfterModelHost.last, "provider.deepseek")

        let anonymous = try await provider.credential(for: CredentialScope(service: "wttr.in"))
        XCTAssertEqual(anonymous.kind, .none)
        XCTAssertEqual(secrets.reads, readsAfterModelHost,
                       "an exact allow-listed host must not read the Keychain")

        // The wildcard allow-list is for a different domain. This look-alike
        // host is neither the selected model host nor on the egress allow-list,
        // so the provider must refuse it instead of treating it as anonymous.
        do {
            _ = try await provider.credential(for: CredentialScope(service: "docs.example.com"))
            XCTFail("an unlisted host must be refused")
        } catch let error as ProviderError {
            guard case .unauthorized = error else { return XCTFail("expected unauthorized, got \(error)") }
        }
        XCTAssertEqual(secrets.reads, readsAfterModelHost,
                       "an unlisted host must not read the Keychain")
    }

    func testModelCredentialIsScopedToProtocolPathsOnTheConfiguredOrigin() async throws {
        try settings.upsert(profile(baseURL: "https://api.example.com/anthropic"), apiKey: "model-key")
        let provider = try settings.makeCredentialProvider()

        // The configured base is the Anthropic prefix; Messages, models,
        // count_tokens and file resources are the paths DSH actually calls.
        let allowed = [
            "/anthropic/v1/messages",
            "/anthropic/v1/messages/count_tokens",
            "/anthropic/v1/models",
            "/anthropic/v1/models/deepseek-flash",
            "/anthropic/v1/files",
            "/anthropic/v1/files/file_123",
            "/models",
        ]
        for path in allowed {
            let credential = try await provider.credential(
                for: CredentialScope(service: "api.example.com",
                                     audience: path,
                                     scheme: "https",
                                     port: nil))
            XCTAssertEqual(credential.kind, .apiKey(header: "x-api-key"), path)
            XCTAssertEqual(credential.value, "model-key", path)
        }
        let readsAfterAllowedPaths = secrets.reads

        // Prefix-shaped siblings must not be mistaken for descendants of a
        // model operation route.
        let denied = [
            "/mcp",
            "/anthropic/mcp",
            "/anthropic/v1/mcp",
            "/v1/messages",
            "/anthropic/v1/models-mcp",
            "/anthropic/v1/modelsfoo",
            "/anthropic/v1/modelsABC",
            "/anthropic/v1/filesystem",
            "/anthropic/v1/files-mcp",
            "/models-other",
            "/modelsABC",
            "/v1/modelsfoo",
        ]
        for path in denied {
            let credential = try await provider.credential(
                for: CredentialScope(service: "api.example.com",
                                     audience: path,
                                     scheme: "https",
                                     port: nil))
            XCTAssertEqual(credential.kind, .none,
                           "\(path) must not receive the model key")
        }
        // A same-host request on another scheme or port is a different origin,
        // even when its path looks like the model API.
        for scope in [CredentialScope(service: "api.example.com",
                                      audience: "/anthropic/v1/messages",
                                      scheme: "http",
                                      port: 80),
                      CredentialScope(service: "api.example.com",
                                      audience: "/anthropic/v1/messages",
                                      scheme: "https",
                                      port: 8443)] {
            let credential = try await provider.credential(for: scope)
            XCTAssertEqual(credential.kind, .none,
                           "scheme/port \(scope.scheme ?? "?")/\(scope.port ?? 0) must not receive the model key")
        }
        XCTAssertEqual(secrets.reads, readsAfterAllowedPaths,
                       "a non-model path, scheme or port must not read the model Keychain")

        do {
            _ = try await provider.credential(
                for: CredentialScope(service: "other.example.com",
                                     audience: "/anthropic/v1/messages",
                                     scheme: "https",
                                     port: nil))
            XCTFail("a different host must be refused")
        } catch let error as ProviderError {
            guard case .unauthorized = error else { return XCTFail("expected unauthorized, got \(error)") }
        }
    }

    func testConfiguredEndpointProviderRefusesABareHostScope() async throws {
        try settings.upsert(profile(), apiKey: "model-key")
        let provider = try settings.makeCredentialProvider()
        let readsAfterSetup = secrets.reads

        let bare = try await provider.credential(for: CredentialScope(service: "api.example.com"))
        XCTAssertEqual(bare.kind, .none,
                       "production must prove the model path and origin before reading the key")
        XCTAssertEqual(secrets.reads, readsAfterSetup,
                       "a bare host scope must not read the model Keychain")
    }

    func testDefaultPortEndpointDoesNotBecomeAnUnreachableHostRule() throws {
        try settings.upsert(profile(baseURL: "https://api.example.com:443/anthropic"),
                            apiKey: "model-key")
        let profile = try settings.profile(id: "deepseek")
        XCTAssertEqual(profile.allowedModelHost, "https://api.example.com")

        var plan = ModelProviderLaunchPlan()
        try settings.apply(to: &plan)
        XCTAssertEqual(plan.allowedModelHosts, Set(["https://api.example.com"]))
    }

    func testAnthropicBaseAlreadyAtV1DoesNotDuplicateTheVersion() async throws {
        try settings.upsert(profile(baseURL: "https://api.example.com/anthropic/v1"), apiKey: "model-key")
        let provider = try settings.makeCredentialProvider()

        for path in ["/anthropic/v1/messages", "/anthropic/v1/models"] {
            let credential = try await provider.credential(
                for: CredentialScope(service: "api.example.com",
                                     audience: path,
                                     scheme: "https",
                                     port: 443))
            XCTAssertEqual(credential.kind, .apiKey(header: "x-api-key"), path)
        }
        let duplicated = try await provider.credential(
            for: CredentialScope(service: "api.example.com",
                                 audience: "/anthropic/v1/v1/messages",
                                 scheme: "https",
                                 port: 443))
        XCTAssertEqual(duplicated.kind, .none)
    }

    func testModelCredentialHonoursAnExplicitPort() async throws {
        try settings.upsert(profile(baseURL: "https://api.example.com:8443/anthropic"), apiKey: "model-key")
        let provider = try settings.makeCredentialProvider()

        let configured = try await provider.credential(
            for: CredentialScope(service: "api.example.com",
                                 audience: "/anthropic/v1/messages",
                                 scheme: "https",
                                 port: 8443))
        XCTAssertEqual(configured.kind, .apiKey(header: "x-api-key"))
        XCTAssertEqual(configured.value, "model-key")

        for scope in [CredentialScope(service: "api.example.com",
                                      audience: "/anthropic/v1/messages",
                                      scheme: "https",
                                      port: 443),
                      CredentialScope(service: "api.example.com",
                                      audience: "/anthropic/v1/messages",
                                      scheme: "http",
                                      port: 8443)] {
            let credential = try await provider.credential(for: scope)
            XCTAssertEqual(credential.kind, .none,
                           "the configured origin is https:8443, not \(scope.scheme ?? "?")/\(scope.port ?? 0)")
        }
    }

    func testOpenAICompatibleProtocolPathsKeepTheKey() async throws {
        try settings.upsert(profile(baseURL: "https://api.example.com/openai/v1"), apiKey: "model-key")
        let provider = try settings.makeCredentialProvider()

        for path in ["/openai/v1/chat/completions",
                     "/openai/v1/responses",
                     "/openai/v1/models",
                     "/models"] {
            let credential = try await provider.credential(
                for: CredentialScope(service: "api.example.com",
                                     audience: path,
                                     scheme: "https",
                                     port: 443))
            XCTAssertEqual(credential.kind, .apiKey(header: "x-api-key"), path)
            XCTAssertEqual(credential.value, "model-key", path)
        }

        for path in ["/openai/mcp",
                     "/openai/v1/mcp",
                     "/openai/v1/models-mcp",
                     "/openai/v1/modelsfoo",
                     "/openai/v1/responses-mcp",
                     "/openai/v1/filesystem",
                     "/models-other"] {
            let credential = try await provider.credential(
                for: CredentialScope(service: "api.example.com",
                                     audience: path,
                                     scheme: "https",
                                     port: 443))
            XCTAssertEqual(credential.kind, .none, path)
        }
    }

    func testMissingKeyDoesNotPreventBuildingTheProvider() async throws {
        try settings.upsert(profile(), apiKey: nil)
        let provider = try settings.makeCredentialProvider()
        do {
            _ = try await provider.credential(
                for: CredentialScope(service: "api.example.com",
                                     audience: "/anthropic/v1/messages",
                                     scheme: "https",
                                     port: 443))
            XCTFail("a missing key must fail the request instead of inventing one")
        } catch let error as ProviderError {
            guard case .unauthorized = error else { return XCTFail("expected unauthorized, got \(error)") }
        }
    }

    func testEgressOnlyProviderBootsWithoutAProfileAndStillServesAnonymousHosts() async throws {
        let provider = settings.makeEgressOnlyCredentialProvider(egressAllowHosts: ["wttr.in", "*.example.org"])
        let anonymous = try await provider.credential(for: CredentialScope(service: "docs.example.org"))
        XCTAssertEqual(anonymous.kind, .none)
        do {
            _ = try await provider.credential(for: CredentialScope(service: "api.example.com"))
            XCTFail("without a selected profile no model host may receive a credential")
        } catch let error as ProviderError {
            guard case .unauthorized = error else { return XCTFail("expected unauthorized, got \(error)") }
        }
    }

    func testApplyToEnvironmentAndLaunchPlanCarriesNoSecret() throws {
        try settings.upsert(profile(), apiKey: "launch-key")
        var environment: [String: String] = ["DSH_TELEMETRY_DISABLED": "1"]
        try settings.apply(to: &environment)
        XCTAssertEqual(environment["DEEPSEEK_BASE_URL"], "https://api.example.com/anthropic")
        XCTAssertEqual(environment["PDSH_MODEL_NAME"], "deepseek-flash")
        XCTAssertEqual(environment["DSH_TELEMETRY_DISABLED"], "1")
        let json = try XCTUnwrap(environment[PhoneModelProviderSettings.workerEnvironmentKey])
        XCTAssertTrue(json.contains("\"selectedId\":\"deepseek\""))
        XCTAssertTrue(json.contains("\"model\":\"deepseek-flash\""))
        XCTAssertTrue(json.contains("\"reasoningEffort\":\"high\""))
        XCTAssertFalse(json.contains("launch-key"))
        XCTAssertFalse(json.contains("credentialRef"))
        XCTAssertFalse(json.contains("apiKey"))

        var plan = ModelProviderLaunchPlan()
        try settings.apply(to: &plan, egressAllowHosts: ["wttr.in"])
        XCTAssertEqual(plan.allowedModelHosts, Set(["https://api.example.com"]))
        XCTAssertEqual(plan.environment["PDSH_MODEL_NAME"], "deepseek-flash")
    }

    func testSearchBaseUsesTheSelectedModelHostAndAnthropicV1() {
        let base = URL(string: "https://api.example.com/anthropic")!
        XCTAssertEqual(PhoneModelProviderSettings.searchBaseURL(for: base),
                       "https://api.example.com/anthropic/v1")
        let alreadyV1 = URL(string: "https://api.example.com/anthropic/v1/")!
        XCTAssertEqual(PhoneModelProviderSettings.searchBaseURL(for: alreadyV1),
                       "https://api.example.com/anthropic/v1")
        XCTAssertNil(PhoneModelProviderSettings.searchBaseURL(for: URL(string: "file:///tmp/x")!))
    }

    func testApplyWithoutSelectionFailsInsteadOfInventingADefault() {
        var environment: [String: String] = [:]
        XCTAssertThrowsError(try settings.apply(to: &environment)) { error in
            XCTAssertEqual(error as? ModelProviderSettingsError, .noSelectedProvider)
        }
        XCTAssertTrue(environment.isEmpty)
    }
}

private final class InMemoryModelProviderSecretStore: ModelProviderSecretStore, @unchecked Sendable {
    var values: [String: String] = [:]
    var readFailures: Set<String> = []
    var setFailures: Set<String> = []
    var deleteFailures: Set<String> = []
    var onSet: ((String) throws -> Void)?
    var onDelete: ((String) throws -> Void)?
    private(set) var reads: [String] = []

    func secret(for reference: String) throws -> String? {
        reads.append(reference)
        if readFailures.contains(reference) { throw ModelProviderSettingsError.keychain(-1) }
        return values[reference]
    }

    func setSecret(_ secret: String, for reference: String) throws {
        if setFailures.contains(reference) { throw ModelProviderSettingsError.keychain(-1) }
        values[reference] = secret
        try onSet?(reference)
    }

    func deleteSecret(for reference: String) throws {
        if deleteFailures.contains(reference) { throw ModelProviderSettingsError.keychain(-1) }
        try onDelete?(reference)
        values.removeValue(forKey: reference)
    }
}
