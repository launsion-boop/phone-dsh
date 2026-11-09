// SPDX-License-Identifier: MIT
// A resumed Worker must identify as a new process (D6) and a suspended old
// Worker's late HELLO must not become the replacement connection.

import Foundation
import XCTest
@testable import PhoneDSH
import PhoneDSHController
import PhoneDSHLoopback
import PhoneDSHWire

private final class SilentChannelSocket: ChannelSocket, @unchecked Sendable {
    func receiveChannelMessage() async throws -> Data? { nil }
    func sendChannelMessage(_ data: Data) async throws {}
    func closeChannel(code: Int) async {}
}

final class PhoneDSHWorkerBootIdentityTests: XCTestCase {
    private func hello(bootID: String, generation: UInt64 = 2) throws -> HelloPayload {
        try HelloPayload(role: .worker,
                         bootID: bootID,
                         sessionEpoch: 1,
                         fence: Fence(owner: "phone", generation: generation, walSeq: 0),
                         caps: ["channel/1", "vfs-sink/1", "journal/1", "api/1"],
                         lastMseq: 0)
    }

    private func connection(_ coordinator: PhoneDSHChannelCoordinator) -> PhoneDSHConnection {
        let server = ChannelServer(socket: SilentChannelSocket(),
                                   state: ChannelHostState(
                                       bootID: String(repeating: "0", count: 32),
                                       sessionEpoch: 1,
                                       fence: Fence(owner: "phone", generation: 2, walSeq: 0)))
        return PhoneDSHConnection(id: UUID(), server: server, coordinator: coordinator)
    }

    func testStaleWorkerHelloIsRejectedAndTheReplacementIsAccepted() async throws {
        let coordinator = PhoneDSHChannelCoordinator(eventBus: PhoneDSHEventBus())
        let old = connection(coordinator)
        await coordinator.register(old)
        try await coordinator.helloReceived(
            connection: old,
            payload: hello(bootID: String(repeating: "a", count: 32)))

        let newBootID = String(repeating: "b", count: 32)
        await coordinator.beginWorkerBoot(
            expectedBootID: newBootID,
            retiring: [String(repeating: "a", count: 32)],
            sessionEpoch: 1,
            fence: Fence(owner: "phone", generation: 2, walSeq: 0))

        let stale = connection(coordinator)
        await coordinator.register(stale)
        do {
            try await coordinator.helloReceived(
                connection: stale,
                payload: hello(bootID: String(repeating: "a", count: 32)))
            XCTFail("a retired Worker boot id must be refused")
        } catch let error as PhoneWireError {
            XCTAssertEqual(error.code, .fenceStale)
        }

        let replacement = connection(coordinator)
        await coordinator.register(replacement)
        try await coordinator.helloReceived(
            connection: replacement,
            payload: hello(bootID: newBootID))
        let helloResult = try await coordinator.waitForHello(
            after: 0, expecting: newBootID, timeout: 0.2)
        XCTAssertEqual(helloResult.hello.bootID, newBootID)
        await coordinator.finishWorkerBoot()
    }
}
