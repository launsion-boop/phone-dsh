// SPDX-License-Identifier: MIT
// The App-side timing seam for the Bot MCP listener.
//
// The listener is owned by the Bot composition, not by a Worker incarnation,
// so the three paths that can start or continue a Worker must heal it first:
// foreground return, resume, and a cold start/rebuild. Keeping those three
// entry points together also gives the simulator suite a fake-listener seam
// without constructing ChatModel or a real Worker.

import Foundation
import PhoneDSHBot

/// What a Bot composition must expose to the App supervisor.
@MainActor
protocol BotMCPListenerEnsuring: AnyObject {
    var url: URL? { get }
    func ensureListening() async -> BotMCPListenerRecovery
}

/// The three lifecycle moments that are allowed to continue a Worker. A
/// listener rebound to a different port invalidates the URL captured by the
/// Host that is already running, so the App must rebuild rather than resume.
enum BotMCPListenerTrigger: String, CaseIterable, Sendable, Equatable {
    case foreground
    case resume
    case engineStart
}

@MainActor
final class BotMCPListenerSupervisor {
    private let listener: any BotMCPListenerEnsuring
    private(set) var endpoint: URL?
    /// The endpoint captured when the current Host was built. `nil` means no
    /// Host has been built since the supervisor was created.
    private(set) var hostEndpoint: URL?
    /// Observable by tests and useful in a diagnostic: one entry per trigger.
    private(set) var triggers: [BotMCPListenerTrigger] = []

    init(listener: any BotMCPListenerEnsuring) {
        self.listener = listener
        endpoint = listener.url
    }

    @discardableResult
    func foregroundBecameActive() async -> BotMCPListenerRecovery {
        await ensure(.foreground)
    }

    @discardableResult
    func willResumeHost() async -> BotMCPListenerRecovery {
        await ensure(.resume)
    }

    @discardableResult
    func willStartEngine() async -> BotMCPListenerRecovery {
        await ensure(.engineStart)
    }

    @discardableResult
    func ensure(_ trigger: BotMCPListenerTrigger) async -> BotMCPListenerRecovery {
        triggers.append(trigger)
        let result = await listener.ensureListening()
        if let url = result.url {
            endpoint = url
        }
        return result
    }

    /// Records the endpoint a freshly built Host received. A later resume may
    /// continue that Host only while this is still the live endpoint.
    func recordHostBuild() {
        hostEndpoint = endpoint ?? listener.url
    }

    /// `true` when the running Host was built with the current listener URL.
    var hostEndpointIsCurrent: Bool {
        guard let hostEndpoint else { return true }
        return hostEndpoint == endpoint
    }
}
