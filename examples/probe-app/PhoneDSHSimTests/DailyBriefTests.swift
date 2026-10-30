// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — Daily Brief parser, refresh and persistence tests.

import Foundation
import ProbeKit
import XCTest

final class DailyBriefTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func source(id: String = "source-1", name: String = "Example Feed",
                        url: String = "https://feed.test/rss") -> DailyBriefSource {
        DailyBriefSource(id: id, name: name, url: URL(string: url)!)
    }

    private func item(id: String, source: DailyBriefSource, title: String? = nil) -> DailyBriefItem {
        DailyBriefItem(id: id, sourceID: source.id, sourceName: source.name,
                       title: title ?? "Item \(id)", summary: "Summary",
                       link: URL(string: "https://example.com/\(id)"), publishedAt: fixedDate)
    }

    private func snapshot(source: DailyBriefSource, items: [DailyBriefItem]? = nil) -> DailyBriefSnapshot {
        let values = items ?? [item(id: "old-1", source: source)]
        return DailyBriefSnapshot(
            id: DailyBriefIDs.snapshot(createdAt: fixedDate, items: values, sourceCursors: [:]),
            createdAt: fixedDate, items: values)
    }

    private var rss: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel><title>Feed title</title>
          <item>
            <guid>story-1</guid>
            <title>Hello &amp; world</title>
            <link>https://example.com/story-1</link>
            <pubDate>Wed, 28 Oct 2026 10:00:00 GMT</pubDate>
            <description><![CDATA[<p>Summary <b>text</b><script>alert(1)</script></p><!-- hidden -->]]></description>
          </item>
          <item>
            <guid>story-1</guid>
            <title>Hello &amp; world</title>
            <link>https://example.com/story-1</link>
            <pubDate>Wed, 28 Oct 2026 10:00:00 GMT</pubDate>
            <description>Duplicate</description>
          </item>
        </channel></rss>
        """
    }

    func testRSSParsesBoundedPlainTextAndStableIdentity() throws {
        let source = source()
        let items = try DailyBriefParser().parse(Data(rss.utf8), source: source)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].id, items[1].id, "duplicate guid must have one stable identity")
        XCTAssertEqual(items[0].title, "Hello & world")
        XCTAssertEqual(items[0].summary, "Summary text")
        XCTAssertFalse(items[0].summary.contains("script"))
        XCTAssertFalse(items[0].summary.contains("hidden"))
        XCTAssertEqual(items[0].link?.absoluteString, "https://example.com/story-1")
        XCTAssertNotNil(items[0].publishedAt)
    }

    func testAtomParsesAlternateLinkAndUpdatedDate() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom">
          <entry>
            <id>atom-1</id><title>Atom title</title>
            <link rel="self" href="https://feed.test/self" />
            <link rel="alternate" href="https://example.com/atom-1" />
            <updated>2026-10-29T01:02:03Z</updated>
            <summary>Atom summary</summary>
          </entry>
        </feed>
        """
        let items = try DailyBriefParser().parse(Data(xml.utf8), source: source())
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "Atom title")
        XCTAssertEqual(items[0].summary, "Atom summary")
        XCTAssertEqual(items[0].link?.absoluteString, "https://example.com/atom-1")
        XCTAssertNotNil(items[0].publishedAt)
    }

    func testMalformedAndOversizedFeedsFailLoudly() {
        let source = source()
        XCTAssertThrowsError(try DailyBriefParser().parse(Data("<rss>".utf8), source: source))
        XCTAssertThrowsError(try DailyBriefParser().parse(Data(), source: source))
        XCTAssertThrowsError(
            try DailyBriefParser().parse(Data(count: DailyBriefLimits.maximumFeedBytes + 1),
                                         source: source)) { error in
            XCTAssertEqual(error as? DailyBriefError, .responseTooLarge)
        }
    }

    func testSourceValidationRejectsInsecureAndPrivateTargets() throws {
        for value in [
            "http://feed.test/rss",
            "https://localhost/rss",
            "https://127.0.0.1/rss",
            "https://192.168.1.10/rss",
            "https://user:secret@feed.test/rss",
            "https://service.internal/rss",
        ] {
            XCTAssertThrowsError(try DailyBriefSourceValidator.validate(URL(string: value)), value)
        }
        let valid = try DailyBriefSourceValidator.validate(URL(string: "https://feed.test/rss"))
        XCTAssertEqual(valid.host, "feed.test")
        XCTAssertNil(DailyBriefSourceValidator.contentURL(from: "javascript:alert(1)"))
    }

    func testStoreRoundTripSupportsOfflineRead() async throws {
        let root = temporaryRoot()
        let store = try DailyBriefStore(root: root)
        let source = source()
        let state = DailyBriefPersistedState(sources: [source], snapshot: snapshot(source: source))
        try await store.save(state)
        let reloaded = try await DailyBriefStore(root: root).load()
        XCTAssertEqual(reloaded, state)
        XCTAssertTrue(reloaded.snapshot?.shareText.contains("Item old-1") == true)
    }

    func testStoreRejectsUnsupportedSchema() async throws {
        let root = temporaryRoot()
        let directory = root.appendingPathComponent("DailyBrief")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{\"schemaVersion\":999,\"sources\":[]}".utf8)
            .write(to: directory.appendingPathComponent("state.json"))
        let store = try DailyBriefStore(root: root)
        await XCTAssertThrowsErrorAsync(try await store.load())
    }

    func testRefreshPublishesCompleteSnapshotAndDeduplicates() async throws {
        let source = source()
        let transport = DailyBriefTestTransport()
        transport.responses[source.id] = DailyBriefTransportResponse(data: Data(rss.utf8))
        let pipeline = DailyBriefRefreshPipeline(transport: transport, now: { self.fixedDate })
        let outcome = try await pipeline.refresh(sources: [source], previous: nil)
        XCTAssertEqual(outcome.snapshotToPublish?.items.count, 1)
        XCTAssertEqual(outcome.currentSnapshot, outcome.snapshotToPublish)
        XCTAssertEqual(outcome.report.networkBytes, Data(rss.utf8).count)
        XCTAssertEqual(outcome.report.newItemCount, 1)
        XCTAssertTrue(outcome.report.sourceIssues.isEmpty)
    }

    func testAllSourcesFailedKeepsPreviousSnapshotWithoutPublishing() async throws {
        let source = source()
        let previous = snapshot(source: source)
        let transport = DailyBriefTestTransport()
        transport.errors[source.id] = .httpStatus(503)
        let pipeline = DailyBriefRefreshPipeline(transport: transport, now: { self.fixedDate })
        let outcome = try await pipeline.refresh(sources: [source], previous: previous)
        XCTAssertNil(outcome.snapshotToPublish)
        XCTAssertEqual(outcome.currentSnapshot, previous)
        XCTAssertEqual(outcome.report.sourceIssues.count, 1)
    }

    func testPartialFailureKeepsFailedSourceItemsAndAddsSuccessfulSource() async throws {
        let first = source()
        let second = source(id: "source-2", name: "Second", url: "https://feed.test/second")
        let previous = DailyBriefSnapshot(
            id: "previous", createdAt: fixedDate,
            items: [item(id: "old-1", source: first), item(id: "old-2", source: second)])
        let transport = DailyBriefTestTransport()
        transport.errors[first.id] = .httpStatus(503)
        transport.responses[second.id] = DailyBriefTransportResponse(data: Data(rss.utf8))
        let pipeline = DailyBriefRefreshPipeline(transport: transport, now: { self.fixedDate })
        let outcome = try await pipeline.refresh(sources: [first, second], previous: previous)
        XCTAssertEqual(outcome.snapshotToPublish?.items.map(\.sourceID).sorted(),
                       [first.id, second.id].sorted())
        XCTAssertEqual(outcome.report.sourceIssues.count, 1)
    }

    func testSourceCursorSurvivesPublishAndNotModifiedRefresh() async throws {
        var source = source()
        source.eTag = "v1"
        let transport = DailyBriefTestTransport()
        transport.responses[source.id] = DailyBriefTransportResponse(
            data: Data(rss.utf8), eTag: "v2")
        let pipeline = DailyBriefRefreshPipeline(transport: transport, now: { self.fixedDate })
        let published = try await pipeline.refresh(sources: [source], previous: nil)
        XCTAssertEqual(published.sources[0].eTag, "v2")
        XCTAssertEqual(published.snapshotToPublish?.sourceCursors[source.id], "v2")

        transport.responses[source.id] = DailyBriefTransportResponse(
            data: Data(), notModified: true, eTag: "v2")
        let previous = published.snapshotToPublish
        let unchanged = try await pipeline.refresh(sources: published.sources, previous: previous)
        XCTAssertNil(unchanged.snapshotToPublish)
        XCTAssertEqual(unchanged.currentSnapshot, previous)
        XCTAssertEqual(unchanged.sources[0].eTag, "v2")
        XCTAssertEqual(unchanged.currentSnapshot?.sourceCursors[source.id], "v2")
    }

    func testCancellationDoesNotPublishSnapshot() async throws {
        let source = source()
        let transport = DailyBriefTestTransport()
        transport.errors[source.id] = .invalidResponse
        let pipeline = DailyBriefRefreshPipeline(transport: transport, now: { self.fixedDate })
        let task = Task {
            try await pipeline.refresh(sources: [source], previous: snapshot(source: source))
        }
        task.cancel()
        _ = await task.result
        // A second deterministic cancellation at the transport boundary also cannot publish.
        let cancelling = DailyBriefCancellationTransport()
        let cancelledPipeline = DailyBriefRefreshPipeline(transport: cancelling, now: { self.fixedDate })
        await XCTAssertThrowsErrorAsync(
            try await cancelledPipeline.refresh(sources: [source], previous: nil)) { error in
                XCTAssertTrue(error is CancellationError)
            }
    }

    func testLiveFeedWhenURLProvided() async throws {
        guard let raw = ProcessInfo.processInfo.environment["PDSH_DAILY_BRIEF_LIVE_URL"],
              let url = URL(string: raw) else {
            throw XCTSkip("set PDSH_DAILY_BRIEF_LIVE_URL to run the real transport check")
        }
        let source = DailyBriefSource(name: "Live feed", url: url)
        let response = try await DailyBriefURLSessionTransport().fetch(source)
        XCTAssertFalse(response.notModified)
        XCTAssertFalse(response.data.isEmpty)
        let items = try DailyBriefParser().parse(response.data, source: source)
        XCTAssertFalse(items.isEmpty)
        XCTAssertTrue(items.allSatisfy { !$0.title.isEmpty })
    }

    private func temporaryRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DailyBriefTests-\(UUID().uuidString)", isDirectory: true)
        return url
    }

}

private final class DailyBriefTestTransport: DailyBriefTransport, @unchecked Sendable {
    var responses: [String: DailyBriefTransportResponse] = [:]
    var errors: [String: DailyBriefError] = [:]

    func fetch(_ source: DailyBriefSource) async throws -> DailyBriefTransportResponse {
        if let error = errors[source.id] { throw error }
        guard let response = responses[source.id] else { throw DailyBriefError.invalidResponse }
        return response
    }
}

private struct DailyBriefCancellationTransport: DailyBriefTransport {
    func fetch(_ source: DailyBriefSource) async throws -> DailyBriefTransportResponse {
        throw CancellationError()
    }
}

@MainActor
final class DailyBriefModelTests: XCTestCase {
    func testAddRefreshAndOfflineReloadEndToEnd() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DailyBriefModelTests-\(UUID().uuidString)")
        let store = try DailyBriefStore(root: root)
        let transport = DailyBriefTestTransport()
        let source = DailyBriefSource(id: "source-1", name: "Example", url: URL(string: "https://feed.test/rss")!)
        let pipeline = DailyBriefRefreshPipeline(transport: transport)
        let model = DailyBriefModel(store: store, pipeline: pipeline)

        let added = await model.addSource(name: source.name, urlString: source.url.absoluteString)
        XCTAssertTrue(added)
        transport.responses[model.sources[0].id] = DailyBriefTransportResponse(data: Data(rssForModel.utf8))
        await model.refresh()
        XCTAssertEqual(model.snapshot?.items.count, 1)
        XCTAssertNotNil(model.lastReport)
        XCTAssertFalse(model.shareText.isEmpty)

        let reloaded = DailyBriefModel(store: store, pipeline: pipeline)
        await reloaded.load()
        XCTAssertEqual(reloaded.snapshot?.id, model.snapshot?.id)
        XCTAssertEqual(reloaded.snapshot?.items, model.snapshot?.items)
        XCTAssertEqual(reloaded.snapshot?.createdAt.timeIntervalSince1970 ?? 0,
                       model.snapshot?.createdAt.timeIntervalSince1970 ?? 0,
                       accuracy: 0.001)
        XCTAssertEqual(reloaded.shareText, model.shareText)
        XCTAssertTrue(reloaded.shareText.contains("Model story"))
    }

    func testRefreshWithoutSourcesProducesActionableState() async throws {
        let store = try DailyBriefStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("DailyBriefEmptyTests-\(UUID().uuidString)"))
        let model = DailyBriefModel(
            store: store,
            pipeline: DailyBriefRefreshPipeline(transport: DailyBriefTestTransport()))
        await model.refresh()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.snapshot)
        XCTAssertFalse(model.isRefreshing)
    }

    private var rssForModel: String {
        """
        <rss version="2.0"><channel><item>
          <guid>model-1</guid><title>Model story</title>
          <link>https://example.com/model-1</link>
          <description>Model summary</description>
        </item></channel></rss>
        """
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                          _ message: String = "",
                                          file: StaticString = #filePath, line: UInt = #line,
                                          _ handler: ((Error) -> Void)? = nil) async {
    do {
        _ = try await expression()
        XCTFail("expected error \(message)", file: file, line: line)
    } catch {
        handler?(error)
    }
}
