// SPDX-License-Identifier: MIT
// Retained-workspace recovery: a compacted WAL can still prove the exact bytes
// and mode of the two generated boot-metadata paths. The repair must be scoped
// to those paths, keep every Session/user file, record the preimage in the
// workspace-private backup tree, and stay idempotent.

import Darwin
import Foundation
import XCTest
@testable import PhoneDSHLog
import PhoneDSHWire

final class MaterializedInvariantLocalRecoveryTests: XCTestCase {
    private struct Fixture {
        var root: URL
        var manifest: Manifest
        var records: [WALRecord]
        var watermark: UInt64
        var agentsMseq: UInt64
        var capabilitiesMseq: UInt64
    }

    private let agentsPath = "/dsh/home/AGENTS.md"
    private let capabilitiesPath = "/dsh/home/capabilities.json"
    private let sessionPath = "/dsh/home/sessions/session.jsonl"
    private let notesPath = "/dsh/workspace/notes.txt"

    // MARK: - Fixture

    private func configuration(_ root: URL) -> WorkspaceLogConfiguration {
        LogTestSupport.configuration(root: root,
                                     segmentRollBytes: 384,
                                     groupCommitDelay: 0)
    }

    private func materializedURL(_ root: URL, _ path: String) -> URL {
        WorkspacePaths(root: root).materializedDirectory
            .appendingPathComponent(String(path.dropFirst("/dsh/".count)))
    }

    private func readMaterialized(_ root: URL, _ path: String) throws -> Data {
        try Data(contentsOf: materializedURL(root, path))
    }

    /// Builds a real workspace. The first epoch owns a Session file, an early
    /// user file and many filler records; it is then legally compacted away.
    /// The second epoch writes the two derived metadata paths, so their
    /// complete bases remain in the retained WAL while mseq 1 is gone.
    private func makeCompactedFixture(_ test: XCTestCase,
                                      name: String,
                                      agentsData: Data = Data("agents-v1\n".utf8),
                                      agentsMode: UInt32 = 0o644,
                                      capabilitiesData: Data = Data("{\"v\":1}\n".utf8),
                                      capabilitiesMode: UInt32 = 0o640,
                                      sessionData: Data = Data("{\"type\":\"session\"}\n".utf8))
        async throws -> Fixture {
        let root = LogTestSupport.root(for: test, name: name)
        let log = try WorkspaceLog(configuration: configuration(root),
                                   bootID: LogTestSupport.bootID(0x61))
        _ = try await log.append(LogTestSupport.write(sessionPath, bytes: sessionData))
        _ = try await log.append(LogTestSupport.write(notesPath, data: "early notes\n"))
        for index in 0..<24 {
            let path = String(format: "/dsh/workspace/filler/f%02d.txt", index)
            _ = try await log.append(LogTestSupport.write(
                path, bytes: Data(repeating: UInt8(index + 1), count: 160)))
        }
        _ = try await log.closeEpoch()

        let agentsMseq = try await log.append(LogTestSupport.write(
            agentsPath, bytes: agentsData, mode: agentsMode))
        let capabilitiesMseq = try await log.append(LogTestSupport.write(
            capabilitiesPath, bytes: capabilitiesData, mode: capabilitiesMode))
        _ = try await log.append(LogTestSupport.write(notesPath, data: "late notes\n"))
        _ = try await log.closeEpoch()

        let manifest = try XCTUnwrap(try ManifestStore(root: root).read())
        let segments = try LogTestSupport.segments(in: root).sorted { $0.name < $1.name }
        guard let cutoff = segments.firstIndex(where: { segment in
            segment.records.contains { !$0.isEpochClose && $0.mseq == agentsMseq }
        }) else {
            throw LogTestSupport.FixtureError(description: "agents base is not in a segment")
        }
        let retainedFiles = Set(segments[cutoff...]
            .filter { !$0.records.isEmpty }
            .map(\.manifestFile))
        let retainedList = manifest.segments.filter { retainedFiles.contains($0.file) }
        guard let first = retainedList.first, first.firstMseq > 1 else {
            throw LogTestSupport.FixtureError(
                description: "compaction did not move the retained start above mseq 1")
        }
        for segment in segments[..<cutoff] {
            try FileManager.default.removeItem(at: segment.url)
        }
        let compacted = Manifest(bootID: manifest.bootID,
                                 materializedUptoMseq: manifest.materializedUptoMseq,
                                 lastMseq: manifest.lastMseq,
                                 lastDurableEpoch: manifest.lastDurableEpoch,
                                 segments: retainedList)
        try ManifestStore(root: root).write(compacted)
        return Fixture(root: root,
                       manifest: compacted,
                       records: try LogTestSupport.records(in: root),
                       watermark: compacted.materializedUptoMseq,
                       agentsMseq: agentsMseq,
                       capabilitiesMseq: capabilitiesMseq)
    }

    /// Opens a fresh epoch without closing it, so the next recovery has an
    /// unlisted tail to adopt and therefore runs the materialized invariant.
    private func appendUnlistedTail(_ root: URL, bootByte: UInt8) async throws {
        let writer = try WALWriter(configuration: configuration(root),
                                   bootID: LogTestSupport.bootID(bootByte))
        _ = try await writer.append(LogTestSupport.write(
            "/dsh/workspace/after-compaction.txt", data: "tail\n"))
    }

    private func openAndRecover(_ root: URL, bootByte: UInt8) async throws
        -> WorkspaceLogRecovery {
        let log = try WorkspaceLog(configuration: configuration(root),
                                   bootID: LogTestSupport.bootID(bootByte))
        return try await log.recover()
    }

    // MARK: - Behaviour

    func testCompactedWALRepairsDerivedMetadataAndKeepsSessionsAndUserFiles()
        async throws {
        let agents = Data("agents-retained\n".utf8)
        let capabilities = Data("{\"retained\":true}\n".utf8)
        let fixture = try await makeCompactedFixture(
            self, name: "local-repair-e2e",
            agentsData: agents, agentsMode: 0o640,
            capabilitiesData: capabilities, capabilitiesMode: 0o600)

        let sessionURL = materializedURL(fixture.root, sessionPath)
        let notesURL = materializedURL(fixture.root, notesPath)
        let sessionBefore = try Data(contentsOf: sessionURL)
        let notesBefore = try Data(contentsOf: notesURL)
        let sessionInode = try inode(of: sessionURL)
        let notesInode = try inode(of: notesURL)

        let corruptedAgents = Data("agents-lost\n".utf8)
        let corruptedCapabilities = Data("{\"live\":true}\n".utf8)
        try corruptedAgents.write(to: materializedURL(fixture.root, agentsPath))
        try corruptedCapabilities.write(to: materializedURL(fixture.root, capabilitiesPath))
        try LogFile.setMode(materializedURL(fixture.root, agentsPath), mode: 0o600)
        try LogFile.setMode(materializedURL(fixture.root, capabilitiesPath), mode: 0o644)

        try await appendUnlistedTail(fixture.root, bootByte: 0x62)
        let report = try await openAndRecover(fixture.root, bootByte: 0x63)

        XCTAssertEqual(Set(report.localRepairs.map(\.path)),
                       Set([agentsPath, capabilitiesPath]),
                       "both retained derived paths must be restored locally")
        XCTAssertEqual(report.nextMseq, fixture.manifest.lastMseq + 2,
                       "a local repair must not fabricate or consume an mseq")
        XCTAssertEqual(try readMaterialized(fixture.root, agentsPath), agents)
        XCTAssertEqual(try LogFile.fileMode(materializedURL(fixture.root, agentsPath)),
                       mode_t(0o640))
        XCTAssertEqual(try readMaterialized(fixture.root, capabilitiesPath), capabilities)
        XCTAssertEqual(try LogFile.fileMode(materializedURL(fixture.root, capabilitiesPath)),
                       mode_t(0o600))

        XCTAssertEqual(try Data(contentsOf: sessionURL), sessionBefore,
                       "a Session JSONL file must not be rewritten")
        XCTAssertEqual(try Data(contentsOf: notesURL), notesBefore,
                       "a retained user file must not be rewritten")
        XCTAssertEqual(try inode(of: sessionURL), sessionInode,
                       "a local repair must not replace the materialized tree")
        XCTAssertEqual(try inode(of: notesURL), notesInode,
                       "a local repair must not replace unrelated files")
        XCTAssertEqual(try readMaterialized(fixture.root,
                                            "/dsh/workspace/after-compaction.txt"),
                       Data("tail\n".utf8),
                       "the unlisted tail must still be replayed")

        let agentsBackup = try backupPreimage(fixture.root, for: agentsPath)
        XCTAssertEqual(try Data(contentsOf: agentsBackup), corruptedAgents,
                       "the exact pre-repair bytes must be recoverable")
        XCTAssertEqual(try LogFile.fileMode(agentsBackup), mode_t(0o600))
        XCTAssertEqual(try LogFile.fileMode(agentsBackup.deletingLastPathComponent()),
                       mode_t(0o700))
        let record = try backupRecord(fixture.root, for: agentsPath)
        XCTAssertEqual(record["vfs_path"] as? String, agentsPath)
        XCTAssertEqual(record["original_state"] as? String, "file")
        XCTAssertEqual((record["original_mode"] as? NSNumber)?.uint32Value, 0o600)
        XCTAssertEqual((record["expected_mode"] as? NSNumber)?.uint32Value, 0o640)

        let backupCount = try backupFiles(fixture.root).count
        let second = try await openAndRecover(fixture.root, bootByte: 0x64)
        XCTAssertTrue(second.localRepairs.isEmpty,
                      "a second recovery has no divergence to repair")
        XCTAssertEqual(try backupFiles(fixture.root).count, backupCount,
                       "an idempotent recovery must not grow the preimage set")

        // A normal post-repair capability publish is still an ordinary WAL
        // append followed by a new manifest, not a second local repair.
        let log = try WorkspaceLog(configuration: configuration(fixture.root),
                                   bootID: LogTestSupport.bootID(0x65))
        let before = try XCTUnwrap(try ManifestStore(root: fixture.root).read())
        let published = Data("{\"republished\":true}\n".utf8)
        let mseq = try await log.append(LogTestSupport.write(
            capabilitiesPath, bytes: published, mode: 0o644))
        _ = try await log.closeEpoch()
        let after = try XCTUnwrap(try ManifestStore(root: fixture.root).read())
        XCTAssertGreaterThan(mseq, before.lastMseq)
        XCTAssertGreaterThan(after.lastMseq, before.lastMseq)
        XCTAssertEqual(try readMaterialized(fixture.root, capabilitiesPath), published)
        XCTAssertEqual(try LogFile.fileMode(materializedURL(fixture.root, capabilitiesPath)),
                       mode_t(0o644))
    }

    func testModeOnlyDivergenceRestoresModeWithoutRewritingBytes() async throws {
        let agents = Data("agents-mode\n".utf8)
        let fixture = try await makeCompactedFixture(
            self, name: "local-repair-mode", agentsData: agents, agentsMode: 0o640)
        let target = materializedURL(fixture.root, agentsPath)
        try LogFile.setMode(target, mode: 0o600)

        let report = try MaterializedInvariant.checkAndRepair(
            paths: WorkspacePaths(root: fixture.root),
            records: fixture.records,
            materializedUptoMseq: fixture.watermark,
            allowRepair: true,
            bootIDHex: "00000000000000000000000000000000")

        XCTAssertEqual(report.localRepairs.count, 1)
        XCTAssertEqual(report.localRepairs.first?.kind, .modeMismatch)
        XCTAssertEqual(report.localRepairs.first?.path, agentsPath)
        XCTAssertFalse(report.repaired, "a local repair is not a full-tree rebuild")
        XCTAssertEqual(try Data(contentsOf: target), agents)
        XCTAssertEqual(try LogFile.fileMode(target), mode_t(0o640))
        let record = try backupRecord(fixture.root, for: agentsPath)
        XCTAssertEqual((record["original_mode"] as? NSNumber)?.uint32Value, 0o600)
        XCTAssertEqual((record["expected_mode"] as? NSNumber)?.uint32Value, 0o640)

        let again = try MaterializedInvariant.checkAndRepair(
            paths: WorkspacePaths(root: fixture.root),
            records: fixture.records,
            materializedUptoMseq: fixture.watermark,
            allowRepair: true)
        XCTAssertTrue(again.localRepairs.isEmpty,
                      "re-running the same proof after repair is a clean check")
    }

    func testDisabledRepairStillRefusesDerivedMetadata() async throws {
        let fixture = try await makeCompactedFixture(self, name: "local-repair-disabled")
        let target = materializedURL(fixture.root, agentsPath)
        let corrupt = Data("agents-disabled\n".utf8)
        try corrupt.write(to: target)

        XCTAssertThrowsError(try MaterializedInvariant.checkAndRepair(
            paths: WorkspacePaths(root: fixture.root),
            records: fixture.records,
            materializedUptoMseq: fixture.watermark,
            allowRepair: false)) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("materialized copy diverges"), message)
            XCTAssertTrue(message.contains(agentsPath), message)
        }
        XCTAssertEqual(try Data(contentsOf: target), corrupt)
        XCTAssertTrue(try backupFiles(fixture.root).isEmpty)
    }

    func testUserFileStillFailsClosedEvenWithARetainedBase() async throws {
        let fixture = try await makeCompactedFixture(self, name: "local-repair-user")
        let target = materializedURL(fixture.root, notesPath)
        try Data("tampered notes\n".utf8).write(to: target)

        XCTAssertThrowsError(try MaterializedInvariant.checkAndRepair(
            paths: WorkspacePaths(root: fixture.root),
            records: fixture.records,
            materializedUptoMseq: fixture.watermark,
            allowRepair: true)) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("materialized copy diverges"), message)
            XCTAssertTrue(message.contains(notesPath), message)
            XCTAssertTrue(message.contains("contentMismatch"), message)
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("tampered notes\n".utf8),
                       "a refused repair must not modify the divergent path")
        XCTAssertTrue(try backupFiles(fixture.root).isEmpty,
                      "a refused repair must not create a partial backup tree")
    }

    func testMissingBaseForADerivedPathStillFailsClosed() async throws {
        let fixture = try await makeCompactedFixture(self, name: "local-repair-no-base")
        let agentsTarget = materializedURL(fixture.root, agentsPath)
        let capabilitiesTarget = materializedURL(fixture.root, capabilitiesPath)
        try Data("agents-no-base\n".utf8).write(to: agentsTarget)
        try Data("{\"capabilities\":\"no-base\"}\n".utf8).write(to: capabilitiesTarget)

        // Remove the AGENTS full-write record. Its materialized file still
        // exists, so the two-path policy cannot prove it and must not repair
        // only capabilities.json.
        let withoutAgents = fixture.records.filter { $0.mseq != fixture.agentsMseq }
        XCTAssertThrowsError(try MaterializedInvariant.checkAndRepair(
            paths: WorkspacePaths(root: fixture.root),
            records: withoutAgents,
            materializedUptoMseq: fixture.watermark,
            allowRepair: true)) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("materialized copy diverges"), message)
        }
        XCTAssertEqual(try Data(contentsOf: agentsTarget), Data("agents-no-base\n".utf8))
        XCTAssertEqual(try Data(contentsOf: capabilitiesTarget),
                       Data("{\"capabilities\":\"no-base\"}\n".utf8),
                       "the other policy path must not be repaired alone")
        XCTAssertTrue(try backupFiles(fixture.root).isEmpty)
    }

    func testGapAfterTheBaseStillFailsClosed() async throws {
        let fixture = try await makeCompactedFixture(self, name: "local-repair-gap")
        let target = materializedURL(fixture.root, agentsPath)
        try Data("agents-gapped\n".utf8).write(to: target)

        // Drop the record immediately after the AGENTS base. The base itself
        // remains, but the suffix no longer proves there was no later write.
        let gapped = fixture.records.filter { $0.mseq != fixture.agentsMseq + 1 }
        XCTAssertThrowsError(try MaterializedInvariant.checkAndRepair(
            paths: WorkspacePaths(root: fixture.root),
            records: gapped,
            materializedUptoMseq: fixture.watermark,
            allowRepair: true)) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("materialized copy diverges"), message)
            XCTAssertTrue(message.contains("contiguous suffix"), message)
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("agents-gapped\n".utf8))
    }

    func testSymlinkedTargetStillFailsClosed() async throws {
        let fixture = try await makeCompactedFixture(self, name: "local-repair-symlink")
        let target = materializedURL(fixture.root, agentsPath)
        let elsewhere = materializedURL(fixture.root, "/dsh/workspace/symlink-target.txt")
        try Data("not agents\n".utf8).write(to: elsewhere)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: elsewhere)

        XCTAssertThrowsError(try MaterializedInvariant.checkAndRepair(
            paths: WorkspacePaths(root: fixture.root),
            records: fixture.records,
            materializedUptoMseq: fixture.watermark,
            allowRepair: true)) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("materialized copy diverges"), message)
            XCTAssertTrue(message.contains("missingFile") || message.contains("symlink"), message)
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: target.path),
                       elsewhere.path)
        XCTAssertTrue(try backupFiles(fixture.root).isEmpty,
                      "a symlinked target is refused before any backup or write")
    }

    func testBackupFailureLeavesTheCorruptPreimageAndRetrySucceeds() async throws {
        let agents = Data("agents-backup\n".utf8)
        let fixture = try await makeCompactedFixture(
            self, name: "local-repair-backup", agentsData: agents, agentsMode: 0o640)
        let target = materializedURL(fixture.root, agentsPath)
        let corrupt = Data("agents-corrupt\n".utf8)
        try corrupt.write(to: target)
        let blocker = fixture.root.appendingPathComponent(
            MaterializedInvariant.recoveryBackupName, isDirectory: false)
        try Data("not a directory".utf8).write(to: blocker)

        XCTAssertThrowsError(try MaterializedInvariant.checkAndRepair(
            paths: WorkspacePaths(root: fixture.root),
            records: fixture.records,
            materializedUptoMseq: fixture.watermark,
            allowRepair: true)) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("preimage backup"), message)
        }
        XCTAssertEqual(try Data(contentsOf: target), corrupt,
                       "a failed backup must not be followed by an overwrite")

        try FileManager.default.removeItem(at: blocker)
        let report = try MaterializedInvariant.checkAndRepair(
            paths: WorkspacePaths(root: fixture.root),
            records: fixture.records,
            materializedUptoMseq: fixture.watermark,
            allowRepair: true)
        XCTAssertEqual(report.localRepairs.map(\.path), [agentsPath])
        XCTAssertEqual(try Data(contentsOf: target), agents)
        XCTAssertEqual(try LogFile.fileMode(target), mode_t(0o640))
        XCTAssertEqual(try Data(contentsOf: try backupPreimage(fixture.root, for: agentsPath)),
                       corrupt)
    }

    // MARK: - Private retained-workspace diagnostic

    /// Mac-only diagnostic. The environment variable must name a *copy* of a
    /// retained workspace; the test copies it again before opening it, so the
    /// caller's private backup is never modified.
    func testRetainedWorkspaceBackupCopyFromEnvironmentRecovers() async throws {
        guard let path = ProcessInfo.processInfo.environment["PDSH_WAL_AUDIT_WORKSPACE"],
              !path.isEmpty else {
            throw XCTSkip("set PDSH_WAL_AUDIT_WORKSPACE to a private copy of Documents/chat-host")
        }
        let source = URL(fileURLWithPath: path, isDirectory: true)
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-wal-audit-\(UUID().uuidString)", isDirectory: true)
        let copy = temporary.appendingPathComponent("chat-host", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary,
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: copy)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let sessionsBefore = try sessionDigests(copy)
        let report = try await openAndRecover(copy, bootByte: 0xA7)
        print("PDSH_WAL_AUDIT localRepairs="
            + report.localRepairs.map { "\($0.kind.rawValue) \($0.path)" }.joined(separator: ", "))
        for repair in report.localRepairs {
            XCTAssertTrue(MaterializedInvariant.locallyRepairablePaths.contains(repair.path),
                          "unexpected local-repair path \(repair.path)")
            let target = materializedURL(copy, repair.path)
            let data = try Data(contentsOf: target)
            XCTAssertEqual(SHA256.hash(data), repair.expectedSha256)
            XCTAssertEqual(UInt32(try LogFile.fileMode(target)), repair.expectedMode)
            XCTAssertTrue(repair.backupRecorded)
        }
        XCTAssertEqual(try sessionDigests(copy), sessionsBefore,
                       "retained Session JSONL files must be byte-identical after recovery")
    }

    // MARK: - Filesystem helpers

    private func inode(of url: URL) throws -> UInt64 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw LogTestSupport.FixtureError(description: "lstat failed for \(url.lastPathComponent)")
        }
        return info.st_ino
    }

    private func backupRoot(_ root: URL) -> URL {
        root.appendingPathComponent(MaterializedInvariant.recoveryBackupName,
                                    isDirectory: true)
    }

    private func backupFiles(_ root: URL) throws -> [URL] {
        let directory = backupRoot(root)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []) else { return [] }
        var files: [URL] = []
        while let element = enumerator.nextObject() {
            guard let nsURL = element as? NSURL else { continue }
            let url = nsURL as URL
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private func backupPreimage(_ root: URL, for path: String) throws -> URL {
        let relative = String(path.dropFirst("/dsh/".count))
        let directory = backupRoot(root).appendingPathComponent(relative, isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        let matches = files.filter { $0.pathExtension == "preimage" }
        XCTAssertEqual(matches.count, 1, "expected exactly one preimage for \(path)")
        return try XCTUnwrap(matches.first)
    }

    private func backupRecord(_ root: URL, for path: String) throws -> [String: Any] {
        let relative = String(path.dropFirst("/dsh/".count))
        let directory = backupRoot(root).appendingPathComponent(relative, isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        let matches = files.filter { $0.pathExtension == "json" }
        XCTAssertEqual(matches.count, 1, "expected exactly one preimage record for \(path)")
        let url = try XCTUnwrap(matches.first)
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func sessionDigests(_ root: URL) throws -> [String: String] {
        let sessions = WorkspacePaths(root: root).materializedHomeDirectory
            .appendingPathComponent("sessions", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sessions.path) else { return [:] }
        guard let enumerator = FileManager.default.enumerator(
            at: sessions,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []) else { return [:] }
        var result: [String: String] = [:]
        while let element = enumerator.nextObject() {
            guard let nsURL = element as? NSURL else { continue }
            let url = nsURL as URL
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relative = url.path.hasPrefix(sessions.path + "/")
                ? String(url.path.dropFirst(sessions.path.count + 1))
                : url.lastPathComponent
            result[relative] = SHA256.hash(try Data(contentsOf: url))
        }
        return result
    }
}
