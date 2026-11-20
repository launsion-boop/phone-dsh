// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSH
import PhoneDSHBot
import ProbeKit

/// App-side assembly of the connector incremental scan (PLAN §2.5).
///
/// The pure scanner and the Gmail/GitHub metadata clients live in
/// `PhoneDSHBot` / `ProbeKit`; this file is the only place that knows the App's
/// authorization state. It never prompts: a connector whose token is absent or
/// expired is simply not added, and a revoked/expired token makes its client
/// report `unauthorized`, which the scanner skips silently. No body is ever
/// fetched; the held `connector-update` item carries metadata only.
@MainActor
enum ConnectorSweepWiring {
    static let githubTokenService = "dev.phone-dsh.probe.github"
    static let githubTokenReference = "access-token"

    /// Installs the scan closure and the durable outbox on the composition.
    /// The outbox is installed even when no connector is currently authorized,
    /// so a previously recorded unacknowledged interval still replays.
    static func install(on composition: BotRuntimeComposition) async {
        guard let mainBotID = composition.rosterModel.mainBotID
                ?? composition.rosterModel.selectedBotID else { return }
        let domain = composition.domain
        let inbox = WakeInbox(store: SQLiteWakeInboxStore(domainStore: domain, botId: mainBotID))
        let outbox = ConnectorUpdateOutbox(domain: domain)
        let sink = ConnectorUpdateInboxSink(outbox: outbox, inbox: inbox, botID: mainBotID)
        let cursors = ConnectorCursorFileStore(directory: cursorDirectory())

        var clients: [any ConnectorDeltaClient] = []
        if GmailSignIn.isConfigured {
            clients.append(GmailConnectorDeltaClient(token: {
                // A missing/expired token is reported as unauthorized and
                // skipped; `accessToken` also refreshes when possible.
                try? await GmailSignIn.accessToken()
            }))
        }
        let secrets = KeychainModelProviderSecretStore(service: githubTokenService)
        if let current = try? secrets.secret(for: githubTokenReference),
           GitHubConnectorAPI.isValidToken(current) {
            clients.append(GitHubConnectorDeltaClient(token: {
                guard let stored = try? secrets.secret(for: githubTokenReference),
                      GitHubConnectorAPI.isValidToken(stored) else { return nil }
                return stored
            }))
        }

        guard !clients.isEmpty else {
            composition.installConnectorSweep(nil, outbox: outbox)
            return
        }
        let scanner = ConnectorDeltaScanner(clients: clients, cursors: cursors, sink: sink)
        composition.installConnectorSweep({
            let batch = await scanner.scanBatch()
            return batch.enqueued
        }, outbox: outbox)
    }

    /// One cursor document directory in the App's Application Support. The
    /// file names and the JSON envelope are the connector-cursor contract; the
    /// directory itself is an implementation detail.
    static func cursorDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("phone-dsh/connectors", isDirectory: true)
    }
}
