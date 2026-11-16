// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import XCTest
@testable import PhoneDSHBot

// G-2 r6 workspace decision materials: bounded Bot-workspace candidates that
// enter the SAME decision-material block. These tests drive the real service
// over a stub catalog (ranking/budget/cancel) and the real production catalog
// over a temporary materialized workspace (paths, bytes, UTF-8, escapes).

private func sha256(_ data: Data) -> String {
    "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private final class StubCatalog: BotWorkspaceCataloging, @unchecked Sendable {
    struct File {
        var text: String
        var modifiedAtMS: Int64
        var contentSHA256: String?
        var truncated: Bool

        init(text: String, modifiedAtMS: Int64 = 1_760_000_000_000,
             contentSHA256: String? = nil, truncated: Bool = false) {
            self.text = text
            self.modifiedAtMS = modifiedAtMS
            self.contentSHA256 = contentSHA256
            self.truncated = truncated
        }
    }

    private let lock = NSLock()
    private var files: [String: File]
    private var readCount = 0
    var listError: Error?
    var readError: Error?

    init(_ files: [String: File]) { self.files = files }

    var reads: Int { lock.withLock { readCount } }

    func listFiles(botID: String, maximumCount: Int) async throws -> [BotWorkspaceFileEntry] {
        if let listError { throw listError }
        return lock.withLock {
            files.map { path, file in
                BotWorkspaceFileEntry(
                    path: path,
                    byteCount: max(1, Data(file.text.utf8).count),
                    modifiedAtMS: file.modifiedAtMS)
            }.sorted { $0.path < $1.path }
        }
    }

    func readText(botID: String, path: String,
                  maximumBytes: Int) async throws -> BotWorkspaceFileContent? {
        if let readError { throw readError }
        return lock.withLock {
            readCount += 1
            guard let file = files[path] else { return nil }
            return BotWorkspaceFileContent(
                text: file.text,
                contentSHA256: file.contentSHA256 ?? sha256(Data(file.text.utf8)),
                truncated: file.truncated)
        }
    }

    func replace(_ path: String, with text: String) {
        lock.withLock {
            files[path] = File(text: text,
                               modifiedAtMS: (files[path]?.modifiedAtMS ?? 1_760_000_000_000) + 1_000)
        }
    }
}

final class WorkspaceDecisionContextTests: XCTestCase {
    private func limits(maxMaterials: Int = 4, maxCharacters: Int = 1_600,
                        maxSnippetCharacters: Int = 240) -> BotDecisionLimits {
        BotDecisionLimits(maxMaterials: maxMaterials, maxCharacters: maxCharacters,
                          maxSnippetCharacters: maxSnippetCharacters,
                          deadlineMilliseconds: 1_500)
    }

    private func service(_ catalog: any BotWorkspaceCataloging,
                         now: @escaping @Sendable () -> Int64 = { 1_000_000 }) ->
        WorkspaceDecisionContextService {
        WorkspaceDecisionContextService(catalog: catalog, now: now)
    }

    // MARK: same-domain discovery

    func testSelectsCurrentAndArchivedGuidelineForTheSameTask() async {
        let catalog = StubCatalog([
            "docs/report-guide-v2.md": .init(
                text: "# 周报填写指引 v2（当前）\n- 标题格式：`[周报]`\n- 必须包含三段：本周完成、风险、下周计划\n- 结尾固定一行：OWNER: 林",
                modifiedAtMS: 1_760_300_000_000),
            "docs/archive/report-guide-v1.md": .init(
                text: "# 周报填写指引 v1（已废弃）\n- 只写两段：完成、计划\n- 结尾固定一行：OLD_GUIDE_9C1",
                modifiedAtMS: 1_760_200_000_000),
            "docs/notes/meeting.md": .init(text: "# 会议记录\n- 咖啡", modifiedAtMS: 1_760_100_000_000),
        ])
        let selection = await service(catalog).selection(
            query: "以后每周五帮我写周报。先写这周的，把这周成品保存为 `reports/weekly.md`。",
            goal: "每周五交付周报",
            botID: "main",
            materialPrefix: "req12345",
            limits: limits())

        XCTAssertEqual(selection.materials.count, 2)
        XCTAssertFalse(selection.truncated) // the unrelated note is not a candidate at all
        let paths = Set(selection.materials.map(\.path))
        XCTAssertEqual(paths, ["docs/report-guide-v2.md", "docs/archive/report-guide-v1.md"])
        let current = selection.materials.first { $0.path == "docs/report-guide-v2.md" }
        let archived = selection.materials.first { $0.path == "docs/archive/report-guide-v1.md" }
        XCTAssertNotNil(current)
        XCTAssertNotNil(archived)
        // The model can tell current from archived from the material text.
        XCTAssertTrue(current?.snippet.contains("当前") == true)
        XCTAssertTrue(archived?.snippet.contains("废弃") == true)
    }

    func testGeneralizesToAnotherDomainWithoutPathSpecialCases() async {
        let catalog = StubCatalog([
            "handbook/api/error-codes.md": .init(
                text: "# 错误码规范（当前）\n- E1001 参数错误\n- 禁止直接返回内部堆栈",
                modifiedAtMS: 1_760_000_000_500),
            "handbook/api/ownership.md": .init(
                text: "# 服务归属\n- 支付服务由结算组维护", modifiedAtMS: 1_760_000_000_400),
            "notes/meeting.md": .init(text: "# 会议记录\n- 咖啡", modifiedAtMS: 1_760_000_000_300),
        ])
        let selection = await service(catalog).selection(
            query: "按错误码规范把 API 的报错改一下", botID: "main", materialPrefix: "req00001",
            limits: limits())

        XCTAssertEqual(selection.materials.map(\.path), ["handbook/api/error-codes.md"])
        XCTAssertTrue(selection.materials[0].snippet.contains("E1001"))
    }

    func testNoMatchingTokenInjectsNothing() async {
        let catalog = StubCatalog([
            "docs/report-guide-v2.md": .init(text: "# 周报填写指引 v2（当前）"),
        ])
        let selection = await service(catalog).selection(
            query: "今天适合穿什么", botID: "main", materialPrefix: "req00002", limits: limits())
        XCTAssertTrue(selection.materials.isEmpty)
        XCTAssertFalse(selection.truncated)
        XCTAssertEqual(catalog.reads, 1) // one bounded read, no fabricated match
    }

    // MARK: bounds

    func testMaterialsStayBoundedByCountCharactersAndSnippet() async {
        var files: [String: StubCatalog.File] = [:]
        for index in 0..<6 {
            files["docs/guide-\(index).md"] = .init(
                text: "规范 \(index) " + String(repeating: "说明 ", count: 120)
                    + " 结束",
                modifiedAtMS: 1_760_000_000_000 + Int64(index))
        }
        let catalog = StubCatalog(files)
        let selection = await service(catalog).selection(
            query: "规范", botID: "main", materialPrefix: "req00003",
            limits: limits(maxMaterials: 4, maxCharacters: 600, maxSnippetCharacters: 80))

        XCTAssertLessThanOrEqual(selection.materials.count, 2)
        XCTAssertEqual(selection.materials.count, 2)
        XCTAssertTrue(selection.truncated)
        let totalCharacters = selection.materials.reduce(0) { $0 + $1.snippet.unicodeScalars.count }
        XCTAssertLessThanOrEqual(totalCharacters, 600)
        for material in selection.materials {
            XCTAssertLessThanOrEqual(material.snippet.unicodeScalars.count, 80)
            XCTAssertEqual(material.evidence, [])
            XCTAssertEqual(material.scope, .agent)
            XCTAssertEqual(material.state, .current)
            XCTAssertNil(material.reason)
            XCTAssertGreaterThanOrEqual(material.version, 1)
            XCTAssertEqual(material.updatedAtMS,
                           catalogEntryTime(path: material.path, catalog: catalog))
        }
    }

    private func catalogEntryTime(path: String, catalog: StubCatalog) -> Int64 {
        // The stub writes modifiedAtMS = base + index; recover it from the path.
        let index = Int(path.split(separator: "-").last?.split(separator: ".").first ?? "0") ?? 0
        return 1_760_000_000_000 + Int64(index)
    }

    func testOversizedAndNonUTF8CandidatesAreSkippedNotFabricated() async {
        let catalog = StubCatalog([
            "docs/ok.md": .init(text: "# 周报规范\n- 当前", modifiedAtMS: 1_760_000_000_000),
            "docs/truncated.md": .init(text: "# 周报规范\n- 截断", modifiedAtMS: 1_760_000_000_001,
                                       truncated: true),
            "docs/broken.md": .init(text: "# 周报规范\n- 坏", modifiedAtMS: 1_760_000_000_002,
                                    contentSHA256: "not-a-digest"),
        ])
        let selection = await service(catalog).selection(
            query: "周报规范", botID: "main", materialPrefix: "req00004", limits: limits())
        XCTAssertEqual(selection.materials.map(\.path), ["docs/ok.md"])
    }

    // MARK: deadline and cancellation

    func testDeadlineStopsBeforeListing() async {
        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var value: Int64 = 0
            func next() -> Int64 { lock.withLock { value += 10_000; return value } }
        }
        let clock = Clock()
        let catalog = StubCatalog(["docs/a.md": .init(text: "周报")])
        let selection = await service(catalog, now: { clock.next() }).selection(
            query: "周报", botID: "main", materialPrefix: "req00005", limits: limits())
        XCTAssertTrue(selection.materials.isEmpty)
        XCTAssertEqual(catalog.reads, 0)
    }

    func testCancellationStopsWithoutMaterial() async {
        struct BlockingCatalog: BotWorkspaceCataloging {
            func listFiles(botID: String, maximumCount: Int) async throws -> [BotWorkspaceFileEntry] {
                while !Task.isCancelled { await Task.yield() }
                return [BotWorkspaceFileEntry(path: "docs/a.md", byteCount: 4,
                                              modifiedAtMS: 1_760_000_000_000)]
            }
            func readText(botID: String, path: String,
                          maximumBytes: Int) async throws -> BotWorkspaceFileContent? {
                BotWorkspaceFileContent(text: "周报", contentSHA256: sha256(Data("周报".utf8)))
            }
        }
        let task = Task {
            await service(BlockingCatalog()).selection(
                query: "周报", botID: "main", materialPrefix: "req00006", limits: limits())
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        let selection = await task.value
        XCTAssertTrue(selection.materials.isEmpty)
    }

    // MARK: identity and revalidation

    func testMaterialIdentityMatchesTheFrozenWorkspaceShape() async {
        let text = "# 周报规范\n- 当前版本"
        let catalog = StubCatalog([
            "docs/report-guide-v2.md": .init(text: text, modifiedAtMS: 1_760_000_123_000,
                                             contentSHA256: sha256(Data(text.utf8))),
        ])
        let selection = await service(catalog).selection(
            query: "周报规范", botID: "main", materialPrefix: "req00007", limits: limits())
        let material = try? XCTUnwrap(selection.materials.first)
        guard let material else { return XCTFail("expected material") }
        XCTAssertEqual(material.materialID, "mat:req00007:w1")
        XCTAssertTrue(material.ref.hasPrefix("workspace:docs/report-guide-v2.md@sha256:"))
        XCTAssertEqual(material.ref.unicodeScalars.count,
                       "workspace:".unicodeScalars.count + "docs/report-guide-v2.md".unicodeScalars.count
                       + "@sha256:".unicodeScalars.count + 64)
        XCTAssertTrue(material.ref.unicodeScalars.count <= 256)
        XCTAssertEqual(WorkspaceDecisionContextService.workspacePath(fromRef: material.ref),
                       "docs/report-guide-v2.md")
        XCTAssertEqual(material.version, 1_760_000_123)
        XCTAssertEqual(material.updatedAtMS, 1_760_000_123_000)
        XCTAssertEqual(material.selectionReason, .match)
    }

    func testPreDeliveryRevalidationDetectsAChangedFile() async throws {
        let text = "# 规范\n- 第一版"
        let catalog = StubCatalog(["docs/guide.md": .init(text: text)])
        let service = service(catalog)
        let ref = await service.selection(query: "规范", botID: "main",
                                          materialPrefix: "req00008",
                                          limits: limits()).materials.first?.ref
        let materialRef = try XCTUnwrap(ref)
        let observed = await service.currentContentSHA256(forWorkspaceRef: materialRef, botID: "main")
        XCTAssertEqual(observed, sha256(Data(text.utf8)))

        catalog.replace("docs/guide.md", with: "# 规范\n- 第二版（已改）")
        let current = await service.currentContentSHA256(forWorkspaceRef: materialRef, botID: "main")
        XCTAssertNotEqual(current, observed)
        XCTAssertEqual(current, sha256(Data("# 规范\n- 第二版（已改）".utf8)))

        XCTAssertNil(await service.currentContentSHA256(
            forWorkspaceRef: "memory:user/a.md@v1", botID: "main"))
        XCTAssertNil(await service.currentContentSHA256(
            forWorkspaceRef: "workspace:../escape.md@sha256:" + String(repeating: "0", count: 64),
            botID: "main"))
        XCTAssertNil(await service.currentContentSHA256(
            forWorkspaceRef: "workspace:docs/guide.md@sha256:short", botID: "main"))
    }

    func testInvalidWorkspacePathsAreRejectedByTheService() {
        for path in ["/etc/passwd", "../secret.md", "docs/../secret.md", "docs//a.md",
                     "docs\\a.md", "docs/a.md\n", "docs/a b.md", "docs/a@b.md",
                     "docs/a.md " , ""] {
            XCTAssertFalse(WorkspaceDecisionContextService.validWorkspacePath(path), path)
        }
        XCTAssertTrue(WorkspaceDecisionContextService.validWorkspacePath("docs/report-guide-v2.md"))
        XCTAssertTrue(WorkspaceDecisionContextService.validWorkspacePath("handbook/api/error-codes.md"))
    }

    // MARK: production directory catalog

    private func makeWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-decisions-\(UUID().uuidString)", isDirectory: true)
        let bot = root.appendingPathComponent(
            "materialized/workspace/.dshbot/agents/main", isDirectory: true)
        try FileManager.default.createDirectory(at: bot, withIntermediateDirectories: true)
        return root
    }

    private func write(_ relative: String, data: Data, root: URL) throws -> URL {
        let url = root.appendingPathComponent(
            "materialized/workspace/.dshbot/agents/main", isDirectory: true)
            .appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    func testDirectoryCatalogListsOnlyItsOwnBotRoot() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try write("docs/report-guide-v2.md", data: Data("# 周报 v2".utf8), root: root)
        let other = root.appendingPathComponent(
            "materialized/workspace/.dshbot/agents/other/docs/other.md")
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("# other".utf8).write(to: other)

        let catalog = BotWorkspaceDirectoryCatalog(workspaceRoot: root)
        let entries = try await catalog.listFiles(botID: "main", maximumCount: 100)
        XCTAssertEqual(entries.map(\.path), ["docs/report-guide-v2.md"])
        XCTAssertGreaterThan(entries[0].modifiedAtMS, 0)
    }

    func testDirectoryCatalogHashesTheExactBytesReadIncludingBOM() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let body = Data([0xEF, 0xBB, 0xBF] + Array("# 标题".utf8))
        _ = try write("docs/bom.md", data: body, root: root)
        let catalog = BotWorkspaceDirectoryCatalog(workspaceRoot: root)
        let content = try await catalog.readText(
            botID: "main", path: "docs/bom.md", maximumBytes: 64 * 1024)
        let read = try XCTUnwrap(content)
        XCTAssertEqual(read.text, "# 标题") // BOM removed from the rendered text
        XCTAssertEqual(read.contentSHA256, sha256(body)) // digest over the bytes read
        XCTAssertFalse(read.truncated)
    }

    func testDirectoryCatalogSkipsNonUTF8OversizedAndMissingFiles() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try write("docs/binary.md", data: Data([0xFF, 0xFE, 0x00, 0x41]), root: root)
        _ = try write("docs/large.md", data: Data(repeating: 0x61, count: 70_000), root: root)
        let catalog = BotWorkspaceDirectoryCatalog(workspaceRoot: root)
        XCTAssertNil(try await catalog.readText(botID: "main", path: "docs/binary.md",
                                                maximumBytes: 64 * 1024))
        XCTAssertNil(try await catalog.readText(botID: "main", path: "docs/large.md",
                                                maximumBytes: 64 * 1024))
        XCTAssertNil(try await catalog.readText(botID: "main", path: "docs/missing.md",
                                                maximumBytes: 64 * 1024))
    }

    func testDirectoryCatalogRefusesEscapesAndSymlinksOutsideTheBotRoot() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try write("docs/ok.md", data: Data("# ok".utf8), root: root)
        let outside = root.appendingPathComponent("materialized/workspace/secret.md")
        try Data("secret".utf8).write(to: outside)
        let link = root.appendingPathComponent(
            "materialized/workspace/.dshbot/agents/main/docs/link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let catalog = BotWorkspaceDirectoryCatalog(workspaceRoot: root)
        do {
            _ = try await catalog.readText(botID: "main", path: "../secret.md",
                                           maximumBytes: 64 * 1024)
            XCTFail("relative escape must be refused")
        } catch let error as BotWorkspaceCatalogError {
            XCTAssertEqual(error, .invalidPath)
        }
        do {
            _ = try await catalog.readText(botID: "main", path: "/etc/passwd",
                                           maximumBytes: 64 * 1024)
            XCTFail("absolute path must be refused")
        } catch let error as BotWorkspaceCatalogError {
            XCTAssertEqual(error, .invalidPath)
        }
        do {
            _ = try await catalog.readText(botID: "main", path: "docs/link.md",
                                           maximumBytes: 64 * 1024)
            XCTFail("symlink escape must be refused")
        } catch let error as BotWorkspaceCatalogError {
            XCTAssertEqual(error, .pathOutsideWorkspace)
        }
    }

    func testDirectoryCatalogRequiresADshWorkspaceBotRoot() async {
        let catalog = BotWorkspaceDirectoryCatalog(workspaceRoot: URL(fileURLWithPath: "/tmp"),
                                                   dataDirectory: "/dsh/home")
        do {
            _ = try await catalog.listFiles(botID: "main", maximumCount: 10)
            XCTFail("a non-workspace root must be refused")
        } catch let error as BotWorkspaceCatalogError {
            XCTAssertEqual(error, .invalidBotRoot)
        }
    }

    func testDirectoryCatalogSurvivesAChangedFileDuringRead() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try write("docs/changing.md", data: Data("# 规范".utf8), root: root)
        let catalog = BotWorkspaceDirectoryCatalog(workspaceRoot: root)
        let first = try await catalog.readText(
            botID: "main", path: "docs/changing.md", maximumBytes: 64 * 1024)
        XCTAssertNotNil(first)
        // A later read sees the new bytes and a new digest, never the old copy.
        try Data("# 规范 v2".utf8).write(to: url)
        let second = try await catalog.readText(
            botID: "main", path: "docs/changing.md", maximumBytes: 64 * 1024)
        XCTAssertEqual(second?.text, "# 规范 v2")
        XCTAssertNotEqual(first?.contentSHA256, second?.contentSHA256)
    }
}
