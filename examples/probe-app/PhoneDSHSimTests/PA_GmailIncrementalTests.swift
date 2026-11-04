// SPDX-License-Identifier: MIT

import Foundation
@testable import ProbeKit
import XCTest

private actor PA_GmailMemoryIncrementalStore: GmailIncrementalStoring {
    private var value = GmailIncrementalState()
    func state() throws -> GmailIncrementalState { value }
    func save(_ state: GmailIncrementalState) throws { value = state }
}

final class PA_GmailIncrementalTests: XCTestCase {
    func testSecondOpenDoesNotRepeatAndHistoryFindsNewMessage() async throws {
        let first = PA_GmailMessage(id: "m1", historyID: "10")
        let second = PA_GmailMessage(id: "m2", historyID: "11")
        let reading = PA_GmailReadingMock()
        await reading.setInitial(search: GmailSearchResult(messages: [first], nextPageToken: nil),
                                 messages: [first.id: first, second.id: second])
        await reading.enqueueHistory(.success(GmailHistoryChange(messagesAdded: [], historyID: "10")))
        await reading.enqueueHistory(.success(GmailHistoryChange(messagesAdded: ["m2"], historyID: "11")))
        let store = PA_GmailMemoryIncrementalStore()
        let synchronizer = GmailIncrementalSynchronizer(client: reading, store: store)

        let initial = try await synchronizer.synchronize()
        XCTAssertEqual(initial.newMessages.map(\.id), ["m1"])
        let reopened = try await GmailIncrementalSynchronizer(client: reading, store: store).synchronize()
        XCTAssertTrue(reopened.newMessages.isEmpty)
        let changed = try await synchronizer.synchronize()
        XCTAssertEqual(changed.newMessages.map(\.id), ["m2"])
        XCTAssertEqual(changed.state.historyID, "11")
        XCTAssertNil(changed.newMessages[0].body)
    }

    func testDailyBriefPublishesOnlyRealChanges() async throws {
        let message = PA_GmailMessage(id: "m1")
        let reading = PA_GmailReadingMock()
        await reading.setInitial(search: GmailSearchResult(messages: [message], nextPageToken: nil),
                                 messages: [message.id: message])
        let store = PA_GmailMemoryIncrementalStore()
        let source = GmailDailyBriefSource(synchronizer: GmailIncrementalSynchronizer(client: reading, store: store))
        let batch = try await source.refresh()
        XCTAssertEqual(batch?.items.map(\.id), ["m1"])
        XCTAssertNotNil(batch?.expiresAt)
        let unchanged = try await source.refresh()
        XCTAssertNil(unchanged)
    }

    func testFollowUpReportsOnlyNewThreadReplies() async throws {
        let reading = PA_GmailReadingMock()
        let first = PA_GmailMessage(id: "m1")
        let second = PA_GmailMessage(id: "m2", historyID: "11")
        let link = URL(string: "https://mail.google.com/mail/#all/thread1")!
        await reading.setThread(GmailThread(id: "thread1", historyID: "10", messages: [first], link: link))
        let checker = GmailFollowUpChecker(
            client: reading, incremental: GmailIncrementalSynchronizer(client: reading,
                                                                       store: PA_GmailMemoryIncrementalStore()))
        let followUp = FollowUp(goal: "watch", target: FollowUpTarget(kind: .gmailThread, threadID: "thread1"),
                                nextCheckCondition: CheckCondition(expression: "threadReply"),
                                stopCondition: StopCondition(expression: "done"))
        let baseline = await checker.check(followUp, since: nil)
        XCTAssertFalse(baseline.changed)
        await reading.setThread(GmailThread(id: "thread1", historyID: "11", messages: [first, second], link: link))
        let changed = await checker.check(followUp, since: baseline.cursor)
        XCTAssertTrue(changed.changed)
        XCTAssertEqual(changed.summary, "指定 Gmail 线程有 1 条新回复")
        let repeated = await checker.check(followUp, since: changed.cursor)
        XCTAssertFalse(repeated.changed)
    }

    func testHistoryBatchDoesNotDropMessagesBeyondDisplayLimit() async throws {
        let initial = PA_GmailMessage(id: "initial", historyID: "10")
        let added = (0..<25).map { PA_GmailMessage(id: "new\($0)", historyID: "11") }
        let reading = PA_GmailReadingMock()
        await reading.setInitial(search: GmailSearchResult(messages: [initial], nextPageToken: nil),
                                 messages: Dictionary(uniqueKeysWithValues: (added + [initial]).map { ($0.id, $0) }))
        await reading.enqueueHistory(.success(GmailHistoryChange(messagesAdded: added.map(\.id), historyID: "11")))
        let synchronizer = GmailIncrementalSynchronizer(client: reading, store: PA_GmailMemoryIncrementalStore(),
                                                        resultLimit: 20)
        _ = try await synchronizer.synchronize()
        let changed = try await synchronizer.synchronize()
        XCTAssertEqual(changed.newMessages.count, 25)
        XCTAssertEqual(changed.state.historyID, "11")
    }

    func testNewMailBatchFansOutToEveryScopedFollowUp() async throws {
        let first = PA_GmailMessage(id: "m1", historyID: "10")
        let reading = PA_GmailReadingMock()
        await reading.setInitial(search: GmailSearchResult(messages: [first], nextPageToken: nil),
                                 messages: [first.id: first])
        let synchronizer = GmailIncrementalSynchronizer(client: reading,
                                                        store: PA_GmailMemoryIncrementalStore())
        let checker = GmailFollowUpChecker(client: reading, incremental: synchronizer)
        let domain = try SQLiteDomainStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("PA-GmailFanOut-\(UUID().uuidString)/domain.sqlite"))
        let store = FollowUpStore(domain: domain)
        try await store.prepare()
        for index in 0..<2 {
            _ = try await store.create(FollowUp(
                goal: "watch \(index)", target: FollowUpTarget(kind: .gmailThread, threadID: "thread-\(index)"),
                nextCheckCondition: CheckCondition(expression: "newMail"),
                stopCondition: StopCondition(expression: "done")), principal: "owner", accountScope: "local")
        }
        _ = try await store.create(FollowUp(
            goal: "other", target: FollowUpTarget(kind: .gmailThread, threadID: "other"),
            nextCheckCondition: CheckCondition(expression: "newMail"),
            stopCondition: StopCondition(expression: "done")), principal: "other", accountScope: "local")
        let coordinator = FollowUpCoordinator(store: store, checkers: [checker],
                                             notifier: PA_GmailFollowUpNotifier(),
                                             principal: "owner", accountScope: "local")
        let outcomes = try await coordinator.checkAll()
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertTrue(outcomes.allSatisfy { $0.record.lastChangeSummary == "Gmail 有 1 封新邮件" })
    }
}

private actor PA_GmailFollowUpNotifier: FollowUpNotificationDelivering {
    func deliver(_ notification: PersonalNotification) async throws {}
}

private extension PA_GmailReadingMock {
    func setInitial(search: GmailSearchResult, messages: [String: GmailMessage]) {
        searchResults = [search]
        self.messages = messages
    }
}
