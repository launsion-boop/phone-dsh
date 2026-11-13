// SPDX-License-Identifier: MIT
import CryptoKit
import Foundation
import XCTest
import PhoneDSHAgentCore
@testable import PhoneDSHBLE

/// WP3 storage conformance for `spec/device/v1/device-panel.md` §4.1.
///
/// All storage tests inject the frozen WP1 evaluator signature so they do not
/// depend on the evaluator implementation. `testRealEvaluatorAdoptAndReEvaluate`
/// is the one test that drives the real `evaluateDevicePanelDescriptor`; it is
/// skipped while WP1's frozen `fatalError` placeholder is still in place (a
/// placeholder call would abort the whole test binary) and becomes live as soon
/// as WP1 lands.
final class DevicePanelStoreTests: XCTestCase {
    private static let deviceA = "5f0c2a9e-7d41-4b6a-9c3e-2a1b0d4e8f77"
    private static let deviceB = "0b9d6e3a-1c2f-4d5e-8a7b-9c0d1e2f3a4b"

    private var temporaryContainers: [URL] = []

    override func tearDown() {
        for container in temporaryContainers {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: container.path)
            try? FileManager.default.removeItem(at: container)
        }
        temporaryContainers = []
        super.tearDown()
    }

    // MARK: - Fixtures and helpers

    /// `(container, storeDirectory)`. `storeDirectory` deliberately does not
    /// exist yet: adopt must create it on demand. `container` is the boundary
    /// the traversal test asserts against.
    private func makeSandbox() throws -> (container: URL, directory: URL) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("device-panel-store-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        temporaryContainers.append(container)
        return (container, container.appendingPathComponent("root/device-panels", isDirectory: true))
    }

    /// The frozen evaluator signature, with a settable outcome. It records every
    /// call so a test can prove which bytes, device ID and tools were passed.
    private final class ScriptedEvaluator {
        var result: DevicePanelDescriptorResult = .ok
        var descriptor: DevicePanelDescriptor? = DevicePanelDescriptor(controls: [])
        private(set) var evaluations: [(bytes: Data, linkDeviceID: String, tools: [JSONValue])] = []

        func evaluate(
            _ bytes: Data,
            _ linkDeviceID: String,
            _ tools: [JSONValue]
        ) -> (DevicePanelDescriptorResult, DevicePanelDescriptor?) {
            evaluations.append((bytes, linkDeviceID, tools))
            return (result, result == .ok ? descriptor : nil)
        }
    }

    /// An evaluator whose verdict depends on the tools it is given, standing in
    /// for a tool table that changed after adoption.
    private final class ToolGateEvaluator {
        private(set) var calls: [(linkDeviceID: String, tools: [JSONValue])] = []

        func evaluate(
            _ bytes: Data,
            _ linkDeviceID: String,
            _ tools: [JSONValue]
        ) -> (DevicePanelDescriptorResult, DevicePanelDescriptor?) {
            calls.append((linkDeviceID, tools))
            guard !tools.isEmpty else { return (.tool_not_advertised, nil) }
            return (.ok, DevicePanelDescriptor(controls: []))
        }
    }

    private var lightSetTool: JSONValue {
        .object([
            "name": .string("light.set"),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object(["on": .object(["type": .string("boolean")])]),
                "required": .array([.string("on")]),
                "additionalProperties": .bool(false),
            ]),
        ])
    }

    private func panelFileName(for linkDeviceID: String) -> String {
        let digest = SHA256.hash(data: Data(linkDeviceID.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".json"
    }

    private func entries(in directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    /// §4.1 rule 4 + P18: the host-private directory holds exactly one
    /// `<64 lowercase hex>.json` per adopted device and nothing else.
    private func assertOnlyPanelFiles(
        in directory: URL,
        expected: [String],
        message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let names = entries(in: directory)
        XCTAssertEqual(Set(names), Set(expected), message, file: file, line: line)
        for name in names {
            XCTAssertNotNil(
                name.range(of: #"^[0-9a-f]{64}\.json$"#, options: .regularExpression),
                "not <64 lowercase hex>.json: \(name)",
                file: file,
                line: line
            )
        }
    }

    // MARK: - Default location (P18)

    func testDefaultDirectoryIsApplicationSupportDevicePanels() {
        // Computing the default URL performs no I/O; the store must not create
        // or touch anything until adopt is called.
        let store = DevicePanelStore()
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        XCTAssertEqual(store.directory.lastPathComponent, "device-panels")
        XCTAssertEqual(store.directory.deletingLastPathComponent(), applicationSupport)
    }

    // MARK: - adopt

    func testAdoptOkWritesTheExactBytesAndCreatesTheDirectoryOnDemand() throws {
        let (_, directory) = try makeSandbox()
        let evaluator = ScriptedEvaluator()
        let store = DevicePanelStore(directory: directory, evaluator: evaluator.evaluate)
        // Deliberately non-canonical: different key order, extra spaces and a
        // trailing newline. The store must copy the bytes, never re-serialize.
        let bytes = Data(
            #"{ "title" : "书房", "v":1, "device_id":"5f0c2a9e-7d41-4b6a-9c3e-2a1b0d4e8f77", "controls" : [] }"#.utf8
        ) + Data("\n".utf8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        XCTAssertEqual(try store.adopt(bytes, linkDeviceID: Self.deviceA, tools: [lightSetTool]), .ok)

        let file = directory.appendingPathComponent(panelFileName(for: Self.deviceA))
        XCTAssertEqual(try Data(contentsOf: file), bytes, "adopt must copy the descriptor bytes verbatim")
        XCTAssertEqual(evaluator.evaluations.count, 1)
        XCTAssertEqual(evaluator.evaluations[0].bytes, bytes)
        XCTAssertEqual(evaluator.evaluations[0].linkDeviceID, Self.deviceA)
        XCTAssertEqual(evaluator.evaluations[0].tools, [lightSetTool])
        assertOnlyPanelFiles(in: directory, expected: [panelFileName(for: Self.deviceA)])
    }

    func testRejectedAdoptWritesNothingAndKeepsThePreviousCopy() throws {
        let (_, directory) = try makeSandbox()
        let evaluator = ScriptedEvaluator()
        let store = DevicePanelStore(directory: directory, evaluator: evaluator.evaluate)

        // A rejected first adopt must not even create the directory.
        evaluator.result = .too_large
        XCTAssertEqual(try store.adopt(Data("{}".utf8), linkDeviceID: Self.deviceA, tools: []), .too_large)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "a rejected adopt must write nothing")

        let accepted = Data(
            #"{"v":1,"device_id":"5f0c2a9e-7d41-4b6a-9c3e-2a1b0d4e8f77","controls":[{"tool":"light.set","label":"开灯"}]}"#.utf8
        )
        evaluator.result = .ok
        XCTAssertEqual(try store.adopt(accepted, linkDeviceID: Self.deviceA, tools: [lightSetTool]), .ok)
        let file = directory.appendingPathComponent(panelFileName(for: Self.deviceA))

        evaluator.result = .schema
        let rejected = Data(
            #"{"v":1,"device_id":"5f0c2a9e-7d41-4b6a-9c3e-2a1b0d4e8f77","controls":[]}"#.utf8
        )
        XCTAssertEqual(try store.adopt(rejected, linkDeviceID: Self.deviceA, tools: [lightSetTool]), .schema)
        XCTAssertEqual(evaluator.evaluations.last?.bytes, rejected)
        XCTAssertEqual(try Data(contentsOf: file), accepted, "a rejected adopt must not touch the previous copy")
        assertOnlyPanelFiles(in: directory, expected: [panelFileName(for: Self.deviceA)])
    }

    func testSecondAdoptAtomicallyReplacesTheFirstWithNoStrayFiles() throws {
        let (_, directory) = try makeSandbox()
        let evaluator = ScriptedEvaluator()
        let store = DevicePanelStore(directory: directory, evaluator: evaluator.evaluate)
        let first = Data(#"{"generation":1}"#.utf8)
        let second = Data(#"{"generation":2}"#.utf8)

        XCTAssertEqual(try store.adopt(first, linkDeviceID: Self.deviceA, tools: []), .ok)
        XCTAssertEqual(try store.adopt(second, linkDeviceID: Self.deviceA, tools: []), .ok)

        let file = directory.appendingPathComponent(panelFileName(for: Self.deviceA))
        XCTAssertEqual(try Data(contentsOf: file), second)
        XCTAssertFalse(
            String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("generation\":1"),
            "the first copy must be gone"
        )
        assertOnlyPanelFiles(in: directory, expected: [panelFileName(for: Self.deviceA)])
    }

    func testTwoDevicesAreIndependent() throws {
        let (_, directory) = try makeSandbox()
        let evaluator = ScriptedEvaluator()
        let store = DevicePanelStore(directory: directory, evaluator: evaluator.evaluate)
        let bytesA = Data(#"{"device":"a","generation":1}"#.utf8)
        let bytesA2 = Data(#"{"device":"a","generation":2}"#.utf8)
        let bytesB = Data(#"{"device":"b","generation":1}"#.utf8)

        XCTAssertEqual(try store.adopt(bytesA, linkDeviceID: Self.deviceA, tools: []), .ok)
        XCTAssertEqual(try store.adopt(bytesB, linkDeviceID: Self.deviceB, tools: []), .ok)
        XCTAssertEqual(try store.adopt(bytesA2, linkDeviceID: Self.deviceA, tools: []), .ok)

        let fileA = directory.appendingPathComponent(panelFileName(for: Self.deviceA))
        let fileB = directory.appendingPathComponent(panelFileName(for: Self.deviceB))
        XCTAssertEqual(try Data(contentsOf: fileA), bytesA2)
        XCTAssertEqual(try Data(contentsOf: fileB), bytesB, "adopting for one device must not touch another device")
        XCTAssertEqual(store.active(linkDeviceID: Self.deviceA, tools: [])?.0, .ok)
        XCTAssertEqual(store.active(linkDeviceID: Self.deviceB, tools: [])?.0, .ok)
        assertOnlyPanelFiles(
            in: directory,
            expected: [panelFileName(for: Self.deviceA), panelFileName(for: Self.deviceB)]
        )
    }

    func testHostileDeviceIDsCannotEscapeTheInjectedDirectory() throws {
        let (container, directory) = try makeSandbox()
        let evaluator = ScriptedEvaluator()
        let store = DevicePanelStore(directory: directory, evaluator: evaluator.evaluate)
        let hostileIDs = [
            "../../escaped-panel",
            "a/b/c",
            "..",
            "nul\u{0000}byte",
            String(repeating: "x", count: 300),
            "..\\..\\windows-style",
        ]

        var expected: [String] = []
        for (index, linkDeviceID) in hostileIDs.enumerated() {
            let bytes = Data("descriptor-\(index)".utf8)
            XCTAssertEqual(try store.adopt(bytes, linkDeviceID: linkDeviceID, tools: [lightSetTool]), .ok)

            let file = directory.appendingPathComponent(panelFileName(for: linkDeviceID))
            XCTAssertEqual(try Data(contentsOf: file), bytes)
            XCTAssertTrue(
                file.path.hasPrefix(directory.path + "/"),
                "the adopted copy must stay inside the injected directory: \(file.path)"
            )
            XCTAssertEqual(store.active(linkDeviceID: linkDeviceID, tools: [lightSetTool])?.0, .ok)
            expected.append(panelFileName(for: linkDeviceID))

            // Any `..`/`/` escape would create an entry beside `root` or beside
            // the injected directory. Nothing may ever appear there.
            XCTAssertEqual(entries(in: container), ["root"])
            XCTAssertEqual(entries(in: container.appendingPathComponent("root")), ["device-panels"])
        }
        XCTAssertEqual(Set(expected).count, hostileIDs.count, "each device ID must map to its own file")
        assertOnlyPanelFiles(in: directory, expected: expected)
    }

    // MARK: - active

    func testActiveReturnsNilWhenNothingWasAdopted() throws {
        let (_, directory) = try makeSandbox()
        let evaluator = ScriptedEvaluator()
        let store = DevicePanelStore(directory: directory, evaluator: evaluator.evaluate)

        XCTAssertNil(store.active(linkDeviceID: Self.deviceA, tools: [lightSetTool]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "reading must not create the directory")
        XCTAssertTrue(evaluator.evaluations.isEmpty, "there are no bytes to evaluate")
    }

    func testActiveReEvaluatesWithCurrentToolsAndNeverDeletesOnFailure() throws {
        let (_, directory) = try makeSandbox()
        let evaluator = ToolGateEvaluator()
        let store = DevicePanelStore(directory: directory, evaluator: evaluator.evaluate)
        let bytes = Data(
            #"{"v":1,"device_id":"5f0c2a9e-7d41-4b6a-9c3e-2a1b0d4e8f77","controls":[{"tool":"light.set","label":"开灯"}]}"#.utf8
        )
        XCTAssertEqual(try store.adopt(bytes, linkDeviceID: Self.deviceA, tools: [lightSetTool]), .ok)
        XCTAssertEqual(evaluator.calls.count, 1)

        // The tool table changed and no longer advertises light.set.
        let failed = store.active(linkDeviceID: Self.deviceA, tools: [])
        XCTAssertEqual(failed?.0, .tool_not_advertised, "active must return the current failure reason")
        XCTAssertNil(failed?.1)
        XCTAssertEqual(evaluator.calls.count, 2)
        XCTAssertEqual(evaluator.calls[1].linkDeviceID, Self.deviceA)
        XCTAssertEqual(evaluator.calls[1].tools, [], "active must re-evaluate with the current tools")
        let file = directory.appendingPathComponent(panelFileName(for: Self.deviceA))
        XCTAssertEqual(try Data(contentsOf: file), bytes, "a failing re-evaluation must never delete the copy")
        assertOnlyPanelFiles(in: directory, expected: [panelFileName(for: Self.deviceA)])

        // The same bytes become usable again once the tool table recovers; no
        // re-adoption is involved.
        let recovered = store.active(linkDeviceID: Self.deviceA, tools: [lightSetTool])
        XCTAssertEqual(recovered?.0, .ok)
        XCTAssertNotNil(recovered?.1)
        XCTAssertEqual(evaluator.calls.count, 3)
    }

    func testExternallyCorruptedFileYieldsAFailureResultWithoutCrashOrDeletion() throws {
        let (_, directory) = try makeSandbox()
        let evaluator = ScriptedEvaluator()
        let store = DevicePanelStore(directory: directory, evaluator: evaluator.evaluate)
        let original = Data(
            #"{"v":1,"device_id":"5f0c2a9e-7d41-4b6a-9c3e-2a1b0d4e8f77","controls":[{"tool":"light.set","label":"开灯"}]}"#.utf8
        )
        XCTAssertEqual(try store.adopt(original, linkDeviceID: Self.deviceA, tools: [lightSetTool]), .ok)
        let file = directory.appendingPathComponent(panelFileName(for: Self.deviceA))

        for corrupted in [Data("{ this is not a descriptor".utf8), Data([0xFF, 0xFE, 0x00])] {
            try corrupted.write(to: file)
            evaluator.result = .invalid_json
            let outcome = store.active(linkDeviceID: Self.deviceA, tools: [lightSetTool])
            XCTAssertEqual(outcome?.0, .invalid_json)
            XCTAssertNil(outcome?.1)
            XCTAssertEqual(evaluator.evaluations.last?.bytes, corrupted, "active must evaluate the bytes it read")
            XCTAssertEqual(try Data(contentsOf: file), corrupted, "a corrupt copy is reported, not deleted")
        }
        assertOnlyPanelFiles(in: directory, expected: [panelFileName(for: Self.deviceA)])
    }

    // MARK: - remove

    func testRemoveDeletesTheCopyAndIsIdempotent() throws {
        let (_, directory) = try makeSandbox()
        let evaluator = ScriptedEvaluator()
        let store = DevicePanelStore(directory: directory, evaluator: evaluator.evaluate)
        XCTAssertEqual(try store.adopt(Data(#"{"device":"a"}"#.utf8), linkDeviceID: Self.deviceA, tools: []), .ok)
        XCTAssertEqual(try store.adopt(Data(#"{"device":"b"}"#.utf8), linkDeviceID: Self.deviceB, tools: []), .ok)

        try store.remove(linkDeviceID: Self.deviceA)
        XCTAssertNil(store.active(linkDeviceID: Self.deviceA, tools: []))
        XCTAssertEqual(store.active(linkDeviceID: Self.deviceB, tools: [])?.0, .ok, "removal is per device")
        XCTAssertNoThrow(try store.remove(linkDeviceID: Self.deviceA), "removing an absent copy is not an error")
        XCTAssertNoThrow(try store.remove(linkDeviceID: "never-adopted"), "removing an absent copy is not an error")
        assertOnlyPanelFiles(in: directory, expected: [panelFileName(for: Self.deviceB)])
    }

    // MARK: - Atomicity under a real write failure

    func testFailedWriteLeavesNoPartialFileAndKeepsThePreviousCopy() throws {
        let (_, directory) = try makeSandbox()
        let evaluator = ScriptedEvaluator()
        let store = DevicePanelStore(directory: directory, evaluator: evaluator.evaluate)
        let first = Data(#"{"generation":1}"#.utf8)
        XCTAssertEqual(try store.adopt(first, linkDeviceID: Self.deviceA, tools: []), .ok)
        let file = directory.appendingPathComponent(panelFileName(for: Self.deviceA))

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        try XCTSkipIf(
            FileManager.default.isWritableFile(atPath: directory.path),
            "the test process can write a read-only directory (elevated privileges); write failure not simulated"
        )

        XCTAssertThrowsError(try store.adopt(Data(#"{"generation":2}"#.utf8), linkDeviceID: Self.deviceA, tools: []))
        XCTAssertEqual(try Data(contentsOf: file), first, "a failed write must leave the previous copy untouched")
        assertOnlyPanelFiles(
            in: directory,
            expected: [panelFileName(for: Self.deviceA)],
            message: "a failed write must not leave a partial or temporary file"
        )

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        XCTAssertEqual(try store.adopt(Data(#"{"generation":3}"#.utf8), linkDeviceID: Self.deviceA, tools: []), .ok)
        XCTAssertEqual(try Data(contentsOf: file), Data(#"{"generation":3}"#.utf8))
        assertOnlyPanelFiles(in: directory, expected: [panelFileName(for: Self.deviceA)])
    }

    // MARK: - The real WP1 evaluator (not the storage seam)

    /// Marked clearly: this is the only test that calls the real
    /// `evaluateDevicePanelDescriptor`. Everything above injects the frozen
    /// storage seam, so WP3 can be reviewed while WP1 is still in parallel.
    ///
    /// While WP1's file is the frozen `fatalError` placeholder, calling it would
    /// abort the whole test process, so the placeholder is detected from source
    /// and reported as a skip. Once WP1 replaces it, this test runs unchanged.
    func testRealEvaluatorAdoptAndReEvaluate() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let evaluatorSource = repositoryRoot.appendingPathComponent("Sources/PhoneDSHBLE/DevicePanelDescriptor.swift")
        let source = String(decoding: try Data(contentsOf: evaluatorSource), as: UTF8.self)
        try XCTSkipIf(
            source.contains("fatalError(\"WP1: DevicePanelDescriptor.swift evaluator not implemented\")"),
            "WP1 evaluateDevicePanelDescriptor is still the frozen fatalError placeholder; this test becomes live when WP1 lands"
        )

        let (_, directory) = try makeSandbox()
        let store = DevicePanelStore(directory: directory)
        let linkDeviceID = "5f0c2a9e-7d41-4b6a-9c3e-2a1b0d4e8f77"
        // A literal valid descriptor and a literal tools/list entry, both per
        // device-panel.md §4.2 / §2 (same shape as the shared golden vector).
        let descriptor = Data(
            #"{"v":1,"device_id":"5f0c2a9e-7d41-4b6a-9c3e-2a1b0d4e8f77","controls":[{"tool":"light.set","label":"开灯","preset":{"on":true}}]}"#.utf8
        )
        let tools: [JSONValue] = [lightSetTool]

        XCTAssertEqual(try store.adopt(descriptor, linkDeviceID: linkDeviceID, tools: tools), .ok)
        let file = directory.appendingPathComponent(panelFileName(for: linkDeviceID))
        XCTAssertEqual(try Data(contentsOf: file), descriptor, "the real evaluator must not change the stored bytes")

        let active = store.active(linkDeviceID: linkDeviceID, tools: tools)
        XCTAssertEqual(active?.0, .ok)
        XCTAssertEqual(active?.1?.controls.map(\.tool), ["light.set"])

        // A changed tool table makes the same bytes fail without deleting them.
        let toolChanged = store.active(linkDeviceID: linkDeviceID, tools: [])
        XCTAssertEqual(toolChanged?.0, .tool_not_advertised)
        XCTAssertNil(toolChanged?.1)
        XCTAssertEqual(try Data(contentsOf: file), descriptor)

        // A descriptor for another device is rejected and the adopted copy stays.
        let mismatched = Data(
            #"{"v":1,"device_id":"00000000-0000-0000-0000-000000000000","controls":[{"tool":"light.set","label":"开灯"}]}"#.utf8
        )
        XCTAssertEqual(try store.adopt(mismatched, linkDeviceID: linkDeviceID, tools: tools), .device_mismatch)
        XCTAssertEqual(try Data(contentsOf: file), descriptor)
        assertOnlyPanelFiles(in: directory, expected: [panelFileName(for: linkDeviceID)])
    }

    /// The Discover shortcuts list adopted panels without a connected device:
    /// the summary comes from the stored bytes, and a stray or misnamed file in
    /// the directory is never listed.
    func testAdoptedSummariesListStoredDescriptorsOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("panel-summaries-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DevicePanelStore(directory: directory, evaluator: { _, _, _ in
            (.ok, DevicePanelDescriptor(title: nil, controls: []))
        })
        XCTAssertEqual(store.adoptedSummaries(), [])
        try store.adopt(Data(#"{"v":1,"device_id":"dev-b","title":"书房","controls":[]}"#.utf8), linkDeviceID: "dev-b", tools: [])
        try store.adopt(Data(#"{"v":1,"device_id":"dev-a","controls":[]}"#.utf8), linkDeviceID: "dev-a", tools: [])
        try Data("{}".utf8).write(to: directory.appendingPathComponent("notes.json"))
        // Right-looking name, but the content names another device.
        try Data(#"{"device_id":"dev-b"}"#.utf8).write(to: directory.appendingPathComponent(String(repeating: "a", count: 64) + ".json"))
        XCTAssertEqual(store.adoptedSummaries(), [
            .init(linkDeviceID: "dev-a", title: nil), .init(linkDeviceID: "dev-b", title: "书房"),
        ])
        try store.remove(linkDeviceID: "dev-b")
        XCTAssertEqual(store.adoptedSummaries().map(\.linkDeviceID), ["dev-a"])
    }
}
