// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSH
import PhoneDSHBot
import ProbeKit

/// Process-local authorization result for the cadence gate. A connector whose
/// token was reported unauthorized keeps its demand removed (contract §10.3.2),
/// and must not be treated as "never scanned, baseline due" on every following
/// wake. A fresh launch clears it and retries once.
private final class ConnectorRuntimeState {
    var unavailable = Set<String>()
}

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

        let authorized = Set(clients.map(\.connector.rawValue))
        let runtime = ConnectorRuntimeState()
        // A connector may have been authorised in an earlier run; its demand
        // must not survive a sign-out. Remove it before scheduling anything
        // (the sink is installed before this wiring by `BotRuntimeComposition`).
        for connector in ConnectorKind.allCases where !authorized.contains(connector.rawValue) {
            await composition.wakeDemandSink?.remove(
                source: BotWakeDemand.connectorScanSource,
                key: connector.rawValue)
        }
        guard !clients.isEmpty else {
            composition.installConnectorSweep(nil, outbox: outbox)
            composition.connectorScanDue = nil
            // No authorized connector: remove any leftover recurring demand so
            // the host does not schedule wakes for a scan that cannot run.
            if let demands = composition.wakeDemandSink {
                await demands.removeAll(source: BotWakeDemand.connectorScanSource)
            }
            return
        }
        // The demand table (§10.3.2) is the cadence. Without this gate every
        // wake scans every authorised connector, and a failed scan leaves an
        // overdue demand that the resident timer would retry at zero delay.
        composition.connectorScanDue = {
            let demands = await EngineLaunchOrchestrator.shared.wakeDemands()
            return ConnectorScanCadence.hasDueWork(
                authorized: authorized.subtracting(runtime.unavailable),
                demands: demands,
                nowMs: WakeDemandLedger.nowMs())
        }
        let scanner = ConnectorDeltaScanner(clients: clients, cursors: cursors, sink: sink)
        composition.installConnectorSweep({
            let batch = await scanner.scanBatch()
            // PLAN §2.9 I2: each completed scan schedules the connector's next
            // due time with the frozen minimum interval; an unauthorized
            // connector removes its demand instead of prompting.
            if let demands = composition.wakeDemandSink,
               let interval = composition.connectorScanDemandIntervalMs {
                let now = botProductionNowMilliseconds()
                for result in batch.results {
                    switch result.outcome {
                    case .skipped(let reason) where reason == "unauthorized":
                        // Revoked/expired authorization: no next scan until the
                        // user reconnects or the next launch; never prompt from
                        // a wake. The process-local marker also stops the
                        // "no demand => baseline" rule from re-scanning every
                        // wake while the token stays invalid.
                        runtime.unavailable.insert(result.connector.rawValue)
                        await demands.remove(source: BotWakeDemand.connectorScanSource,
                                             key: result.connector.rawValue)
                    case .skipped, .failed:
                        // Gated (data protection) or failed: keep the existing
                        // demand untouched; the next wake retries the scan.
                        break
                    case .baselineEstablished, .noNewItems, .enqueued,
                         .duplicate, .reset:
                        runtime.unavailable.remove(result.connector.rawValue)
                        await demands.upsert(BotWakeDemand(
                            source: BotWakeDemand.connectorScanSource,
                            key: result.connector.rawValue,
                            dueAtMs: now + interval,
                            kind: .recurring,
                            userVisible: false))
                    }
                }
            }
            return ConnectorSweepResult(results: batch.results, enqueued: batch.enqueued)
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
