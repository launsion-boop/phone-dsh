// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotModelImageToolTests: XCTestCase {
    func testCatalogAdvertisesAttachToModelAsAnApprovalGatedImageTool() {
        XCTAssertTrue(BotToolCatalog.allDefinitions.contains {
            $0.name == BotToolCatalog.attachToModelName
        })
        XCTAssertTrue(BotToolCatalog.isRegistered(BotToolCatalog.attachToModelName))
        XCTAssertEqual(BotToolEffectClassifier.policy(for: BotToolCatalog.attachToModelName), .ask)
    }

    func testAttachToModelFailsClosedWhenTheHostHasNoReader() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        await beginUserTurn(fixture.runtime)
        try await grant(fixture, path: "/dsh/workspace/photo.jpg")
        let result = try await registerAndExecute(
            fixture.runtime, name: BotToolCatalog.attachToModelName,
            arguments: .object([
                "path": .string("/dsh/workspace/photo.jpg"),
                "purpose": .string("看看这张照片"),
            ]))
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(result.structuredContent?["error"]?["code"], .string("unsupported"))
    }

    func testAttachToModelReturnsAnImageContentBlock() async throws {
        let image = BotModelImage(data: Data([0xFF, 0xD8, 0x01]), name: "camera.jpg",
                                  pixelWidth: 800, pixelHeight: 600)
        let fixture = try makeBotMCPFixture(modelImageReader: { request in
            XCTAssertEqual(request.path, "/dsh/workspace/photo.jpg")
            XCTAssertEqual(request.page, 2)
            XCTAssertEqual(request.purpose, "看看这张照片")
            return image
        })
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        await beginUserTurn(fixture.runtime)
        try await grant(fixture, path: "/dsh/workspace/photo.jpg")
        let result = try await registerAndExecute(
            fixture.runtime, name: BotToolCatalog.attachToModelName,
            arguments: .object([
                "path": .string("/dsh/workspace/photo.jpg"),
                "page": .number(2),
                "purpose": .string("看看这张照片"),
            ]))
        XCTAssertNotEqual(result.isError, true)
        XCTAssertEqual(result.content.first?["type"]?.stringValue, "text")
        let imageBlock = result.content.first { $0["type"]?.stringValue == "image" }
        XCTAssertEqual(imageBlock?["mimeType"]?.stringValue, "image/jpeg")
        XCTAssertEqual(imageBlock?["name"]?.stringValue, "camera.jpg")
        XCTAssertEqual(result.structuredContent?["kind"]?.stringValue, "image")
    }

    func testAttachToModelRequiresExactlyOneSourceAndAPurpose() async throws {
        let fixture = try makeBotMCPFixture(modelImageReader: { _ in
            XCTFail("the reader must not run for an invalid request")
            return BotModelImage(data: Data(), name: "x.jpg", pixelWidth: 1, pixelHeight: 1)
        })
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        await beginUserTurn(fixture.runtime)
        try await grant(fixture, path: "/dsh/workspace/a.jpg")
        let both = try await registerAndExecute(
            fixture.runtime, name: BotToolCatalog.attachToModelName,
            arguments: .object([
                "path": .string("/dsh/workspace/a.jpg"),
                "fileId": .string("art_1"),
                "purpose": .string("看看"),
            ]))
        XCTAssertEqual(both.structuredContent?["error"]?["code"], .string("invalid_arguments"))
        let bare = try await registerAndExecute(
            fixture.runtime, name: BotToolCatalog.attachToModelName,
            arguments: .object([
                "path": .string("/dsh/workspace/a.jpg"),
            ]))
        XCTAssertEqual(bare.structuredContent?["error"]?["code"], .string("invalid_arguments"))
    }

    func testAttachToModelAcceptsAPhotosLibraryIdentifier() async throws {
        let image = BotModelImage(data: Data([0xFF, 0xD8, 0x01]), name: "photo.jpg",
                                  pixelWidth: 640, pixelHeight: 480)
        let fixture = try makeBotMCPFixture(modelImageReader: { request in
            XCTAssertEqual(request.photoID, "asset/local-id")
            XCTAssertNil(request.path)
            XCTAssertNil(request.fileID)
            return image
        })
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        await beginUserTurn(fixture.runtime)
        try await grant(fixture, path: "asset/local-id")
        let result = try await registerAndExecute(
            fixture.runtime, name: BotToolCatalog.attachToModelName,
            arguments: .object([
                "photoId": .string("asset/local-id"),
                "purpose": .string("看看这张照片"),
            ]))
        XCTAssertNotEqual(result.isError, true)
        XCTAssertEqual(result.content.first { $0["type"]?.stringValue == "image" }?["name"]?.stringValue,
                       "photo.jpg")
    }

    private func grant(_ fixture: BotMCPTestFixture, path: String) async throws {
        _ = try await fixture.runtime.grants.add(BotGrant(
            botId: "main", tool: BotToolCatalog.attachToModelName,
            operation: "model.image.attach", resource: "attachment=\(path)",
            scope: .session, sessionId: "gb-main", decision: .allow))
    }
}
