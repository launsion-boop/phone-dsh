// SPDX-License-Identifier: MIT

import XCTest
import PhoneDSHLog
import PhoneDSHWire
@testable import PhoneDSH

final class SessionLogErasureTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-log-erasure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testRewriteRemovesOriginalBytesFromWalAndSurvivesRecovery() async throws {
        let original = """
        {"type":"session","version":4,"id":"gb-main","createdAt":1,"isSeeded":false,"delegationDepth":0}
        {"type":"user/message","seq":0,"time":1760000001000,"data":{"message":{"role":"user","content":[{"type":"text","text":"remember QUOKKA_7F3A9"}]}}}
        {"type":"assistant/message","seq":1,"time":1760000002000,"data":{"message":{"role":"assistant","content":[{"type":"text","text":"kept context"}]}}}

        """
        let oldGeneration = """
        {"type":"session","version":3,"id":"gb-main"}
        {"type":"user/message","seq":0,"time":1760000001000,"data":{"message":{"role":"user","content":[{"type":"text","text":"remember QUOKKA_7F3A9"}]}}}

        """
        let currentPath = "/dsh/home/sessions/project/gb-main/session.v4.jsonl"
        let oldPath = "/dsh/home/sessions/project/gb-main/session.v3.jsonl"
        let bootID = Data(repeating: 0x42, count: 16)
        var log: WorkspaceLog? = try WorkspaceLog(
            configuration: WorkspaceLogConfiguration(root: root), bootID: bootID)
        _ = try await log!.append(VfsMutationBody(
            op: .write, mode: 0o644, path: currentPath, data: Data(original.utf8)))
        _ = try await log!.append(VfsMutationBody(
            op: .write, mode: 0o644, path: oldPath, data: Data(oldGeneration.utf8)))
        _ = try await log!.closeEpoch()

        let tombstone = try BotTombstone.line(
            sessionID: "gb-main", seq: 0, time: 1_760_000_001_000, erasureID: "erasure-test")
        let request = PhoneDSHSessionErasureRequest(
            sessionID: "gb-main",
            replacements: [PhoneDSHSessionLineReplacement(seq: 0, line: tombstone)])
        let result = try await SessionLogErasure.apply(
            request: request, workspaceRoot: root, log: log!)
        XCTAssertEqual(result.erasedSeqs, [0])
        XCTAssertEqual(result.removedFiles, ["project/gb-main/session.v3.jsonl"])
        XCTAssertGreaterThan(result.rewriteMseq, 0)

        try assertBytesAbsent("QUOKKA_7F3A9")
        let scan = try WALReader.scan(directory: WorkspacePaths(root: root).walDirectory)
        XCTAssertFalse(scan.segments.contains { segment in
            guard let first = segment.firstMutationMseq else { return false }
            return first < result.rewriteStartMseq
        })

        log = nil
        let recovered = try WorkspaceLog(
            configuration: WorkspaceLogConfiguration(root: root),
            bootID: Data(repeating: 0x43, count: 16))
        _ = try await recovered.materialize()
        try assertBytesAbsent("QUOKKA_7F3A9")
        let materialized = root.appendingPathComponent(
            "materialized/home/sessions/project/gb-main/session.v4.jsonl")
        let text = try String(contentsOf: materialized, encoding: .utf8)
        XCTAssertTrue(text.contains("session-erasure"))
        XCTAssertFalse(text.contains("QUOKKA_7F3A9"))
        XCTAssertTrue(text.contains("kept context"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(
            "materialized/home/sessions/project/gb-main/session.v3.jsonl").path))
        _ = try await recovered.closeEpoch()
    }

    func testPlanRejectsMissingSessionAndCompressedGeneration() async throws {
        XCTAssertThrowsError(try SessionLogErasure.plan(
            request: PhoneDSHSessionErasureRequest(sessionID: "gb-missing", replacements: []),
            workspaceRoot: root))
    }

    private func assertBytesAbsent(_ needle: String) throws {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true,
                  let data = try? Data(contentsOf: url) else { continue }
            XCTAssertNil(data.range(of: Data(needle.utf8)),
                         "\(url.path) still contains the erased word")
        }
    }
}

private enum BotTombstone {
    static let type = "phone-dsh/session-erasure"
    static func line(sessionID: String, seq: Int, time: Int64,
                     erasureID: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": type,
            "seq": seq,
            "time": time,
            "ignorable": true,
            "data": [
                "erased": true,
                "erasureId": erasureID,
                "record": "record://session/\(sessionID)#\(seq)",
            ],
        ], options: [.sortedKeys])
    }
}
