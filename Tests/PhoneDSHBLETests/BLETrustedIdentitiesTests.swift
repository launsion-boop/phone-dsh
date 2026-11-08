// SPDX-License-Identifier: MIT
import Foundation
import XCTest
@testable import PhoneDSHBLE

final class BLETrustedIdentitiesTests: XCTestCase {
    func testSharedLegacyPreferenceFixturesUseIsolatedDefaults() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("spec/device/v1/golden/legacy-identity-preferences.jsonl")
        let lines = try String(contentsOf: path, encoding: .utf8).split(whereSeparator: \.isNewline)
        XCTAssertEqual(lines.count, 13)
        for line in lines {
            let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let id = try XCTUnwrap(row["id"] as? String)
            let suite = "BLEIdentityFixtures." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            if try XCTUnwrap(row["present"] as? Bool) {
                defaults.set(try XCTUnwrap(row["initial"]), forKey: BLETrustedIdentities.key)
            }
            let incoming = try XCTUnwrap(row["incoming"] as? String)
            XCTAssertEqual(BLETrustedIdentities.insertIfVisibleValid(incoming, defaults: defaults),
                           try XCTUnwrap(row["accepted"] as? Bool), id)
            let expected = try XCTUnwrap(row["expected"])
            let actual = try XCTUnwrap(defaults.object(forKey: BLETrustedIdentities.key), id)
            if let expectedStrings = expected as? [String] {
                let actualStrings = try XCTUnwrap(actual as? [String], id)
                XCTAssertEqual(actualStrings.map { $0.unicodeScalars.map(\.value) },
                               expectedStrings.map { $0.unicodeScalars.map(\.value) }, id)
            } else {
                XCTAssertTrue(NSDictionary(dictionary: ["value": actual]).isEqual(to: ["value": expected]), id)
                XCTAssertFalse(BLETrustedIdentities.contains(incoming, defaults: defaults), id)
            }
        }
    }

    func testVisibleDataValueIsPreserved() throws {
        let suite = "BLEIdentityData." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = Data([0, 1, 2, 255])
        defaults.set(old, forKey: BLETrustedIdentities.key)
        XCTAssertFalse(BLETrustedIdentities.insertIfVisibleValid("ble:new", defaults: defaults))
        XCTAssertEqual(defaults.data(forKey: BLETrustedIdentities.key), old)
    }

    func testNoWriteForWrongTypeOrExistingValueAndUnobservableWriteFails() throws {
        let suite = "BLEIdentitySpy." + UUID().uuidString
        let spy = try XCTUnwrap(IdentityDefaultsSpy(suiteName: suite))
        defer { spy.removePersistentDomain(forName: suite) }
        spy.stored = ["old", 7]
        XCTAssertFalse(BLETrustedIdentities.insertIfVisibleValid("new", defaults: spy))
        XCTAssertEqual(spy.writes, 0)
        spy.stored = ["old"]
        XCTAssertTrue(BLETrustedIdentities.insertIfVisibleValid("old", defaults: spy))
        XCTAssertEqual(spy.writes, 0)
        spy.ignoreWrites = true
        XCTAssertFalse(BLETrustedIdentities.insertIfVisibleValid("new", defaults: spy))
        XCTAssertEqual(spy.writes, 1)
        XCTAssertEqual(spy.stored as? [String], ["old"])
    }

    func testReadbackRequiresExactUnicodeScalars() throws {
        let suite = "BLEIdentityScalars." + UUID().uuidString
        let spy = try XCTUnwrap(IdentityDefaultsSpy(suiteName: suite))
        defer { spy.removePersistentDomain(forName: suite) }
        spy.stored = ["old"]
        spy.transformWrite = { _ in ["old", "cafe\u{301}"] }
        XCTAssertFalse(BLETrustedIdentities.insertIfVisibleValid("café", defaults: spy))
        XCTAssertEqual((spy.stored as? [String])?.last?.unicodeScalars.map(\.value), "cafe\u{301}".unicodeScalars.map(\.value))
    }

    func testCanonicallyEquivalentDuplicateDoesNotRewriteOriginalScalars() throws {
        let suite = "BLEIdentityDuplicateScalars." + UUID().uuidString
        let spy = try XCTUnwrap(IdentityDefaultsSpy(suiteName: suite))
        defer { spy.removePersistentDomain(forName: suite) }
        let original = "café"
        spy.stored = [original]
        XCTAssertTrue(BLETrustedIdentities.insertIfVisibleValid("cafe\u{301}", defaults: spy))
        XCTAssertEqual(spy.writes, 0)
        XCTAssertEqual((spy.stored as? [String])?.first?.unicodeScalars.map(\.value), original.unicodeScalars.map(\.value))
    }

    func testReadbackRejectsReorderedOrNormalizedHistoricalValues() throws {
        let observedValues = [["second", "first", "new"], ["cafe\u{301}", "second", "new"]]
        let originalValues = [["first", "second"], ["café", "second"]]
        for (original, observed) in zip(originalValues, observedValues) {
            let suite = "BLEIdentityHistoryReadback." + UUID().uuidString
            let spy = try XCTUnwrap(IdentityDefaultsSpy(suiteName: suite))
            defer { spy.removePersistentDomain(forName: suite) }
            spy.stored = original
            spy.transformWrite = { _ in observed }
            XCTAssertFalse(BLETrustedIdentities.insertIfVisibleValid("new", defaults: spy))
            XCTAssertEqual(spy.writes, 1)
            XCTAssertEqual((spy.stored as? [String])?.map { $0.unicodeScalars.map(\.value) },
                           observed.map { $0.unicodeScalars.map(\.value) })
        }
    }

    func testMissingOrInvalidReadbackFailsWithoutRollback() throws {
        let invalidValues: [Any?] = [nil, 7, ["old"]]
        for invalid in invalidValues {
            let suite = "BLEIdentityReadback." + UUID().uuidString
            let spy = try XCTUnwrap(IdentityDefaultsSpy(suiteName: suite))
            defer { spy.removePersistentDomain(forName: suite) }
            spy.stored = ["old"]
            spy.readbackOverride = { invalid }
            XCTAssertFalse(BLETrustedIdentities.insertIfVisibleValid("new", defaults: spy))
            XCTAssertEqual(spy.writes, 1)
            XCTAssertEqual(spy.stored as? [String], ["old", "new"])
        }
    }

    func testCompatibilityWrapperPreservesMalformedValueAndRetainsVoidSignature() throws {
        let suite = "BLEIdentityWrapper." + UUID().uuidString
        let spy = try XCTUnwrap(IdentityDefaultsSpy(suiteName: suite))
        defer { spy.removePersistentDomain(forName: suite) }
        let insert: (String, UserDefaults) -> Void = BLETrustedIdentities.insert(_:defaults:)
        spy.stored = ["old", 7]
        insert("new", spy)
        XCTAssertEqual(spy.writes, 0)
        XCTAssertFalse(BLETrustedIdentities.contains("old", defaults: spy))
        XCTAssertEqual((spy.stored as? [Any])?.count, 2)
        spy.stored = nil
        XCTAssertFalse(BLETrustedIdentities.contains("old", defaults: spy))
        insert("new", spy)
        XCTAssertEqual(spy.stored as? [String], ["new"])
    }

    func testSharedSynchronousReentryFixturesFailWithoutReadOrWrite() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("spec/device/v1/golden/legacy-identity-reentrant.jsonl")
        let lines = try String(contentsOf: path, encoding: .utf8).split(whereSeparator: \.isNewline)
        XCTAssertEqual(lines.count, 3)
        for line in lines {
            let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let id = try XCTUnwrap(row["id"] as? String)
            let suite = "BLEIdentityReentry." + UUID().uuidString
            let spy = try XCTUnwrap(IdentityDefaultsSpy(suiteName: suite))
            defer { spy.removePersistentDomain(forName: suite) }
            spy.stored = try XCTUnwrap(row["initial"] as? [String])
            let outer = try XCTUnwrap(row["outer"] as? String), nested = try XCTUnwrap(row["nested"] as? String)
            let operation = try XCTUnwrap(row["nested_operation"] as? String)
            let phase = try XCTUnwrap(row["inject_phase"] as? String)
            var nestedResult: Bool?
            var nestedReads = -1, nestedWrites = -1
            let nestedCall = {
                let beforeReads = spy.reads, beforeWrites = spy.writes
                nestedResult = operation == "contains" ? BLETrustedIdentities.contains(nested, defaults: spy)
                    : BLETrustedIdentities.insertIfVisibleValid(nested, defaults: spy)
                nestedReads = spy.reads - beforeReads; nestedWrites = spy.writes - beforeWrites
            }
            spy.onRead = { count in if (phase == "read" && count == 1) || (phase == "readback" && count == 2) { nestedCall() } }
            spy.onWrite = { if phase == "set" { nestedCall() } }
            XCTAssertEqual(BLETrustedIdentities.insertIfVisibleValid(outer, defaults: spy), row["outer_result"] as? Bool, id)
            XCTAssertEqual(nestedResult, row["nested_result"] as? Bool, id)
            XCTAssertEqual(nestedReads, 0, id); XCTAssertEqual(nestedWrites, 0, id)
            XCTAssertEqual(spy.stored as? [String], row["after_outer"] as? [String], id)
            spy.onRead = nil; spy.onWrite = nil
            let retry = operation == "contains" ? BLETrustedIdentities.contains(nested, defaults: spy)
                : BLETrustedIdentities.insertIfVisibleValid(nested, defaults: spy)
            XCTAssertEqual(retry, row["retry_result"] as? Bool, id)
            XCTAssertEqual(spy.stored as? [String], row["after_retry"] as? [String], id)
        }
    }

    func testConcurrentInsertionsThroughAPIKeepBothValues() throws {
        let suite = "BLEIdentityConcurrent." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            XCTAssertTrue(BLETrustedIdentities.insertIfVisibleValid("identity-\(index)", defaults: defaults))
        }
        let values = try XCTUnwrap(defaults.object(forKey: BLETrustedIdentities.key) as? [String])
        XCTAssertEqual(values.count, 40)
        XCTAssertEqual(Set(values), Set((0..<40).map { "identity-\($0)" }))
    }

    func testReentrantCompatibilityWrapperDoesNotReadOrWrite() throws {
        let suite = "BLEIdentityVoidReentry." + UUID().uuidString
        let spy = try XCTUnwrap(IdentityDefaultsSpy(suiteName: suite))
        defer { spy.removePersistentDomain(forName: suite) }
        spy.stored = ["old"]
        var nestedReads = -1, nestedWrites = -1
        spy.onWrite = {
            let reads = spy.reads, writes = spy.writes
            BLETrustedIdentities.insert("nested", defaults: spy)
            nestedReads = spy.reads - reads; nestedWrites = spy.writes - writes
        }
        XCTAssertTrue(BLETrustedIdentities.insertIfVisibleValid("outer", defaults: spy))
        XCTAssertEqual(nestedReads, 0); XCTAssertEqual(nestedWrites, 0)
        XCTAssertEqual(spy.stored as? [String], ["old", "outer"])
    }

}

private final class IdentityDefaultsSpy: UserDefaults, @unchecked Sendable {
    var stored: Any?
    var reads = 0, writes = 0
    var ignoreWrites = false
    var transformWrite: ((Any?) -> Any?)?
    var readbackOverride: (() -> Any?)?
    var onRead: ((Int) -> Void)?
    var onWrite: (() -> Void)?
    override func object(forKey defaultName: String) -> Any? {
        reads += 1
        onRead?(reads)
        if reads > 1, let readbackOverride { return readbackOverride() }
        return stored
    }
    override func set(_ value: Any?, forKey defaultName: String) {
        writes += 1; onWrite?()
        if !ignoreWrites { stored = transformWrite?(value) ?? value }
    }
}
