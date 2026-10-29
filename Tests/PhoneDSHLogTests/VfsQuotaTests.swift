// SPDX-License-Identifier: MIT
// VFS prefix/total quotas are enforced at write time (budgets.md §4).

import Foundation
import XCTest
@testable import PhoneDSHLog
import PhoneDSHLog
import PhoneDSHWire

final class VfsQuotaTests: XCTestCase {
    private let mib = 1024 * 1024

    private func makeLog(_ quota: VfsQuota,
                         singleFileLimit: Int = 128 * 1024 * 1024) throws -> (WorkspaceLog, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-quota-\(UUID().uuidString)", isDirectory: true)
        var configuration = WorkspaceLogConfiguration(root: root,
                                                      singleFileLimitBytes: singleFileLimit,
                                                      groupCommitDelay: 0)
        configuration.vfsQuota = quota
        let log = try WorkspaceLog(configuration: configuration,
                                   bootID: Data(repeating: 0x42, count: 16))
        return (log, root)
    }

    private func write(_ path: String, _ bytes: Int) -> VfsMutationBody {
        VfsMutationBody(op: .write, mode: 0o644, path: path,
                        data: Data(repeating: 0x41, count: bytes))
    }

    func testWorkspaceQuotaRefusesTheWriteThatCrossesIt() async throws {
        let quota = VfsQuota(logicalBytes: 64 * mib, workspaceBytes: 4 * mib,
                             sessionBytes: 4 * mib, tmpBytes: 4 * mib)
        let (log, root) = try makeLog(quota)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await log.recover()

        _ = try await log.append(write("/dsh/workspace/a.bin", 2 * mib))
        _ = try await log.append(write("/dsh/workspace/b.bin", 2 * mib))
        do {
            _ = try await log.append(write("/dsh/workspace/c.bin", 1))
            XCTFail("a write that crosses the workspace quota must be refused")
        } catch LogError.vfsQuotaExceeded(let path, let bucket, let limit, let projected) {
            XCTAssertEqual(path, "/dsh/workspace/c.bin")
            XCTAssertEqual(bucket, "workspace")
            XCTAssertEqual(limit, 4 * mib)
            XCTAssertEqual(projected, 4 * mib + 1)
        }
    }

    func testSessionsQuotaRefusesItsPrefix() async throws {
        let quota = VfsQuota(logicalBytes: 64 * mib, workspaceBytes: 4 * mib,
                             sessionBytes: 1 * mib, tmpBytes: 1 * mib)
        let (log, root) = try makeLog(quota)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await log.recover()

        do {
            _ = try await log.append(write("/dsh/home/sessions/s1/session.jsonl", mib + 1))
            XCTFail("the sessions prefix has its own quota")
        } catch LogError.vfsQuotaExceeded(_, let bucket, _, _) {
            XCTAssertEqual(bucket, "sessions")
        }
    }

    func testTotalQuotaCountsEveryPrefix() async throws {
        let quota = VfsQuota(logicalBytes: 3 * mib, workspaceBytes: 2 * mib,
                             sessionBytes: 2 * mib, tmpBytes: 2 * mib)
        let (log, root) = try makeLog(quota)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await log.recover()

        _ = try await log.append(write("/dsh/workspace/a.bin", 2 * mib))
        do {
            _ = try await log.append(write("/dsh/home/sessions/s.jsonl", 2 * mib))
            XCTFail("the total quota must count bytes across prefixes")
        } catch LogError.vfsQuotaExceeded(_, let bucket, let limit, _) {
            XCTAssertEqual(bucket, "vfs")
            XCTAssertEqual(limit, 3 * mib)
        }
    }

    func testRemovingAFreeSpaceLetsTheNextWriteThrough() async throws {
        let quota = VfsQuota(logicalBytes: 8 * mib, workspaceBytes: 2 * mib,
                             sessionBytes: 8 * mib, tmpBytes: 8 * mib)
        let (log, root) = try makeLog(quota)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await log.recover()

        _ = try await log.append(write("/dsh/workspace/fill.bin", 2 * mib))
        do {
            _ = try await log.append(write("/dsh/workspace/extra.bin", 1))
            XCTFail("workspace is full")
        } catch LogError.vfsQuotaExceeded { }
        _ = try await log.append(VfsMutationBody(op: .remove, mode: 0, path: "/dsh/workspace/fill.bin",
                                                 data: Data()))
        _ = try await log.append(write("/dsh/workspace/extra.bin", 1))
    }

    func testEightGiBRowRefusesAtItsDocumentedWorkspaceBound() async throws {
        // budgets.md §4, 8 GiB row: workspace 288 MiB. Cross it with 1 MiB
        // chunks and assert the single refusal comes from the quota.
        let row = VfsQuota(logicalBytes: 388 * mib, workspaceBytes: 288 * mib,
                           sessionBytes: 230 * mib, tmpBytes: 50 * mib)
        let (log, root) = try makeLog(row)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await log.recover()

        var written = 0
        do {
            while written <= 288 * mib {
                _ = try await log.append(write("/dsh/workspace/part-\(written).bin", mib))
                written += mib
            }
            XCTFail("288 MiB + must be refused")
        } catch LogError.vfsQuotaExceeded(_, let bucket, let limit, _) {
            XCTAssertEqual(bucket, "workspace")
            XCTAssertEqual(limit, 288 * mib)
            XCTAssertGreaterThan(written, 0)
        }
    }
}
