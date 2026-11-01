// SPDX-License-Identifier: MIT

import PhoneDSHAgentCore
import ProbeKit

enum TonoTeamDeviceConnectorFactory {
    static func makeConnector() -> (any DeviceConnector)? {
        nil
    }
}

@MainActor
struct ChatDeviceSessionProvider: DeviceSessionProviding {
    func openSession(deviceID: String, displayName: String,
                     existingSessionID: String?) async throws -> String {
        let chat = ChatModel.shared
        if !chat.isStarted { await chat.start() }
        if chat.parked { await chat.resumeParkedHost() }
        let transport = try await chat.transportForManagement()
        let harness = DSHRemoteHarness(transport: transport)
        let session = try await harness.openSession(HarnessSessionRequest(
            sessionID: existingSessionID, workspace: "/dsh/workspace"))
        if let existingSessionID, session.id != existingSessionID {
            throw DeviceSessionCoordinatorError.sessionIdentityMismatch(
                expected: existingSessionID, actual: session.id)
        }
        return session.id
    }
}
