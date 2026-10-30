// SPDX-License-Identifier: MIT

@testable import ProbeKit
import XCTest

final class PhonePermissionContractTests: XCTestCase {
    func testEnvelopeEgressErrorsAndDateAliases() throws {
        let success = try PhoneToolEnvelope.success(tool: "device.status", scope: "granted", data: [:])
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(success.utf8)) as? [String: Any])
        XCTAssertEqual(value["egress"] as? String, "model")
        XCTAssertEqual(value["scope"] as? String, "granted")

        let failure = try PhoneToolEnvelope.failure(tool: "health.query", error: .noData("没有记录"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(failure.utf8)) as? [String: Any])
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "no_data")
        XCTAssertEqual(error["retryable"] as? Bool, false)

        let from = try PhoneToolEnvelope.date(["from": "2026-10-30T10:00:00+08:00"], "from", alias: "start")
        let start = try PhoneToolEnvelope.date(["start": "2026-10-30T10:00:00+08:00"], "from", alias: "start")
        XCTAssertEqual(from, start)
    }

    func testAuditPersistsOnlyMetadataAcrossInstances() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneCapabilityAuditTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audit = PhoneCapabilityAudit(directory: directory)
        await audit.record(PhoneCapabilityAuditRecord(
            capability: .device, tool: "device.status", egress: true, outcome: "success"))
        let restored = PhoneCapabilityAudit(directory: directory)
        let records = await restored.recent()
        XCTAssertEqual(records.map(\.tool), ["device.status"])
        XCTAssertEqual(records.first?.egress, true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("permissions-audit.json").path))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try Data(contentsOf: directory.appendingPathComponent("permissions-audit.json"))) as? [[String: Any]])
        XCTAssertEqual(Set(json.first?.keys.sorted() ?? []), ["capability", "tool", "at", "egress", "outcome"])
    }

    @MainActor
    func testFolderBookmarkRestoresTheSameRootWithoutClaimingAccess() throws {
        let suite = "PhoneFolderGrantTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneFolderGrantTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = PhoneFolderRoot(id: "folder-test", name: "Fixture", kind: "security-scoped", url: directory)
        try PhoneFolderBookmarkStore.save(root, existing: [], defaults: defaults)
        let restored = PhoneFolderBookmarkStore.load(defaults: defaults)
        XCTAssertEqual(restored.roots.map(\.id), ["folder-test"])
        XCTAssertEqual(restored.roots.first?.url?.standardizedFileURL, directory.standardizedFileURL)
        let store = PhoneFolderGrantStore(defaults: defaults)
        XCTAssertTrue(store.roots.contains(where: { $0.id == "folder-test" }))
    }

    @MainActor
    func testHealthRejectsInvalidMetricsBeforeQueryingTheStore() async {
        let tools = PhonePersonalTools()
        do {
            _ = try await tools.healthSummary(object: ["metrics": ["steps", "steps"]])
            XCTFail("duplicate metrics must fail")
        } catch PhoneToolError.invalidArguments {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        do {
            _ = try await tools.healthQuery(object: ["metric": "steps", "bucket": "week"])
            XCTFail("non-day buckets must fail")
        } catch PhoneToolError.invalidArguments {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    @MainActor
    func testCompositeGatesLegacyAndExtendedToolsAndReturnsRealDeviceState() async throws {
        let suite = "PhoneCompositeContractTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let bridge = PhoneCapabilityBridge(
            permissionStore: PhonePermissionStore(defaults: defaults),
            requester: PhonePermissionRequester(), audit: PhoneCapabilityAudit())
        let composite = CompositePhoneToolBridge(office: OfficeToolBridge(), phone: bridge)
        XCTAssertEqual(composite.handles.count, 51)
        XCTAssertFalse(composite.supportsContext)

        for tool in ["calendar.create_event", "contacts.search", "location.geofence", "focus.status",
                     "home.list", "music.play", "activity.start", "shortcuts.run"] {
            let result = try await composite.callTool(name: tool, arguments: "{}")
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
            XCTAssertEqual((value["error"] as? [String: Any])?["code"] as? String,
                           "capability_disabled", tool)
        }

        let result = try await composite.callTool(name: "device.status", arguments: "{}")
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        XCTAssertEqual(value["ok"] as? Bool, true)
        XCTAssertEqual(value["egress"] as? String, "model")
        XCTAssertEqual(value["scope"] as? String, "granted")
        let data = try XCTUnwrap(value["data"] as? [String: Any])
        for key in ["battery", "thermal", "freeDisk", "network", "lowPower"] {
            XCTAssertNotNil(data[key], key)
        }
    }
}
