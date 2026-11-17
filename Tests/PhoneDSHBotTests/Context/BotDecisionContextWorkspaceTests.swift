// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import XCTest
@testable import PhoneDSHBot

private final class FakeWorkspaceCatalog: @unchecked Sendable, BotWorkspaceCataloging {
    private let lock = NSLock()
    private var files: [String: String]
    let modifiedAtMS: Int64

    init(files: [String: String], modifiedAtMS: Int64 = 1_760_000_000_000) {
        self.files = files
        self.modifiedAtMS = modifiedAtMS
    }

    func set(_ path: String, content: String) {
        lock.lock(); defer { lock.unlock() }
        files[path] = content
    }

    func listFiles(botID: String, maximumCount: Int) async throws -> [BotWorkspaceFileEntry] {
        lock.lock(); defer { lock.unlock() }
        return files.keys.sorted().prefix(maximumCount).map {
            BotWorkspaceFileEntry(
                path: $0, byteCount: files[$0]!.utf8.count, modifiedAtMS: modifiedAtMS)
        }
    }

    func readText(botID: String, path: String, maximumBytes: Int) async throws -> BotWorkspaceFileContent? {
        lock.lock(); defer { lock.unlock() }
        guard let content = files[path], content.utf8.count <= maximumBytes else { return nil }
        let digest = SHA256.hash(data: Data(content.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return BotWorkspaceFileContent(
            text: content, contentSHA256: "sha256:\(digest)")
    }
}

final class BotDecisionContextWorkspaceTests: XCTestCase {
    private func makeService(
        catalog: FakeWorkspaceCatalog
    ) throws -> (service: BotDecisionContextService, cleanup: () -> Void) {
        let made = try makeMemoryTestStore()
        let memory = makeMemory(store: made.store)
        let workspace = WorkspaceDecisionContextService(catalog: catalog)
        let service = BotDecisionContextService(
            memoryForBot: { _ in memory },
            permissionRevision: { _, _, _ in "rev-1" },
            materialState: { _ in (.current, nil) },
            workspaceMaterials: workspace,
            now: { 1_760_000_000_000 })
        return (service, { cleanupMemoryTestStore(made.root) })
    }

    private func request(stage: BotDecisionStage = .preStep) -> BotDecisionRequest {
        BotDecisionRequest(
            stage: stage, botID: "main", sessionID: "gb-main",
            turnID: "gb-main#1", query: "report guide 周报")
    }

    func testWorkspaceMaterialJoinsTheSameBlockAndBudget() async throws {
        let catalog = FakeWorkspaceCatalog(files: [
            "docs/report-guide-v2.md":
                "# 客户周报填写指引 v2\n- 负责人 OWNER：林\n- 结构：成果、风险、下周计划",
        ])
        let made = try makeService(catalog: catalog)
        defer { made.cleanup() }
        let block = try await made.service.materials(for: request())
        XCTAssertEqual(block.materials.count, 1)
        let material = try XCTUnwrap(block.materials.first)
        XCTAssertTrue(material.ref.hasPrefix("workspace:docs/report-guide-v2.md@sha256:"))
        XCTAssertEqual(material.path, "docs/report-guide-v2.md")
        XCTAssertEqual(material.scope, .agent)
        XCTAssertEqual(material.state, .current)
        XCTAssertTrue(material.evidence.isEmpty)
        XCTAssertTrue(material.materialID.contains(":w"), "workspace id must not collide with mat:<n>")
        XCTAssertLessThanOrEqual(material.snippet.unicodeScalars.count, 300)
    }

    func testReviewRegeneratesWhenWorkspaceContentChanges() async throws {
        let catalog = FakeWorkspaceCatalog(files: [
            "docs/report-guide-v2.md": "# v2\n- OWNER：林\n- 风险段必须写",
        ])
        let made = try makeService(catalog: catalog)
        defer { made.cleanup() }
        let block = try await made.service.materials(for: request())
        let material = try XCTUnwrap(block.materials.first)
        var delivery = request(stage: .preDelivery)
        delivery.permissionRevision = block.authorizationRevision
        delivery.activeMaterialRefs = [material.ref]
        let proposal = BotDeliveryProposal(
            request: delivery, tool: "show_attachment",
            materialRefs: [material.ref])

        let unchanged = try await made.service.review(proposal)
        XCTAssertEqual(unchanged, .proceed)

        catalog.set("docs/report-guide-v2.md", content: "# v2\n- OWNER：王\n- 风险段不要写")
        let changed = try await made.service.review(proposal)
        guard case let .regenerate(newBlock, reason) = changed else {
            return XCTFail("expected regenerate, got \(changed)")
        }
        XCTAssertEqual(reason, .materialChanged)
        XCTAssertEqual(newBlock.materials.first?.state, .current)
    }

}
