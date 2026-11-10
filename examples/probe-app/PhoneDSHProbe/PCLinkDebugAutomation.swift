// SPDX-License-Identifier: MIT
// DEBUG-only command file driver for the unattended D2 simulator E2E.
//
// `PDSH_PCLINK_AUTOMATION=1` makes the App poll
// `Documents/pclink-d2-automation.json` and execute one new `id` at a time,
// writing the outcome to `Documents/pclink-d2-automation-result.json`. It
// calls the same models the UI calls (newSession/send/respond/unpair), so the
// exercised paths are the production ones; it is not compiled into release.

#if DEBUG
import Foundation
import PhoneDSHAgentCore
import PhoneDSHPCLink
import ProbeKit
import SwiftUI
import UIKit

@MainActor
@Observable
final class PCLinkDebugAutomation {
    static let shared = PCLinkDebugAutomation()

    private var task: Task<Void, Never>?
    private var lastExecutedID: Int = 0
    private weak var models: WorkspaceModels?

    func start(models: WorkspaceModels) {
        guard ProcessInfo.processInfo.environment["PDSH_PCLINK_AUTOMATION"] == "1",
              task == nil else { return }
        self.models = models
        lastExecutedID = readResult()?["id"] as? Int ?? 0
        debugNote("automation started last=\(lastExecutedID)")
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    private var documents: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    private var commandURL: URL? {
        documents?.appendingPathComponent("pclink-d2-automation.json")
    }

    private var resultURL: URL? {
        documents?.appendingPathComponent("pclink-d2-automation-result.json")
    }

    private func readResult() -> [String: Any]? {
        guard let resultURL, let data = try? Data(contentsOf: resultURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func pollOnce() async {
        guard let models, let commandURL else { return }
        // The command file is written by `simctl spawn ... /bin/sh` in the
        // simulator harness; the app container accepts no host-side file write.
        var root: [String: Any]?
        if let data = try? Data(contentsOf: commandURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = object
        }
        guard let root, let id = root["id"] as? Int, id > lastExecutedID else {
            debugNote("poll: no new command (root=\(root != nil))")
            return
        }
        lastExecutedID = id
        let result = await execute(root, models: models)
        var payload = result
        payload["id"] = id
        payload["at"] = ISO8601DateFormatter().string(from: Date())
        if let resultURL,
           let encoded = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
            try? encoded.write(to: resultURL, options: .atomic)
        }
    }

    private func execute(_ command: [String: Any], models: WorkspaceModels) async -> [String: Any] {
        let action = command["action"] as? String ?? ""
        switch action {
        case "selectBackend":
            let raw = command["backend"] as? String ?? "phone"
            guard let value = DrawerBackendSetting(rawValue: raw) else {
                return ["ok": false, "detail": "bad backend"]
            }
            models.select(value)
            return ["ok": true, "detail": raw]

        case "pair":
            guard let uri = command["uri"] as? String else {
                return ["ok": false, "detail": "missing uri"]
            }
            let flow = PCPairingFlow(client: models.pcLink.client)
            // v1.6: the flow submits pair.auth and waits for the authenticated
            // confirm; scanning is the approval, so no second confirm call.
            await flow.begin(qrURI: uri)
            let outcome = result(for: flow.state)
            if outcome["ok"] as? Bool == true {
                // Same automatic hand-off the pairing page performs.
                models.select(.pc)
            }
            return outcome

        case "newSession":
            guard let chat = models.currentChat else { return ["ok": false, "detail": "no current model"] }
            await chat.newSession()
            let id = chat.currentSessionID ?? ""
            return ["ok": !id.isEmpty, "detail": id]

        case "send":
            guard let chat = models.currentChat, let text = command["text"] as? String else {
                return ["ok": false, "detail": "no current model or text"]
            }
            let sent = await chat.send(text)
            return ["ok": sent, "detail": sent ? "sent" : (chat.userFacingError ?? "not sent")]

        case "approve", "deny":
            guard let chat = models.currentChat, let permission = chat.pendingPermission else {
                return ["ok": false, "detail": "no pending permission"]
            }
            let decision: PermissionDecision = action == "approve" ? .allowOnce : .deny
            await chat.respond(to: permission, decision: decision)
            return ["ok": true, "detail": permission.tool]

        case "accessModes":
            guard let chat = models.currentChat else { return ["ok": false, "detail": "no current model"] }
            let modes = chat.availableAccessModes.map(\.id)
            return ["ok": true, "detail": chat.currentAccessMode ?? "", "modes": modes]

        case "setAccessMode":
            guard let chat = models.currentChat, let mode = command["mode"] as? String else {
                return ["ok": false, "detail": "no current model or mode"]
            }
            let ok = await chat.selectAccessMode(mode)
            return ["ok": ok, "detail": chat.currentAccessMode ?? chat.accessModeError ?? ""]

        case "retry":
            await models.pcLink.retry()
            return ["ok": true, "detail": String(describing: models.pcLink.connection)]

        case "unpairAck":
            do {
                try await models.pcLink.acknowledgePCUnpair()
                return ["ok": true, "detail": "acknowledged"]
            } catch {
                return ["ok": false, "detail": error.localizedDescription]
            }

        case "unpair":
            do {
                try await models.pcLink.unpair()
                return ["ok": true, "detail": "unpaired"]
            } catch {
                return ["ok": false, "detail": error.localizedDescription]
            }

        case "status":
            let chat = models.currentChat
            return [
                "ok": true,
                "detail": String(describing: models.pcLink.connection),
                "online": models.pcLink.isOnline,
                "backend": models.selected.rawValue,
                "session": chat?.currentSessionID ?? "",
                "turnRunning": chat?.turnRunning ?? false,
                "transcriptReady": chat?.isTranscriptReady ?? false,
                "canSend": chat?.canSend ?? false,
                "busy": chat?.busy ?? false,
                "harness": chat?.hasHarness ?? false,
                "eventStreamRecovering": chat?.eventStreamRecovering ?? false,
                "pendingPermission": chat?.pendingPermission?.tool ?? "",
                "userFacingError": chat?.userFacingError ?? "",
                "unpairedPrompt": models.pcLink.status.pcUnpairedPrompt?.code ?? "",
                "paired": models.pcLink.record != nil,
                "peerDshVersion": models.pcLink.pcDSHVersion ?? "",
                "peerAppName": models.pcLink.pcAppName ?? "",
                "peerAppVersion": models.pcLink.pcAppVersion ?? "",
                "versionWarning": models.pcLink.versionWarning?.dshVersion ?? "",
            ]

        default:
            return ["ok": false, "detail": "unknown action \(action)"]
        }
    }

    private func debugNote(_ text: String) {
        guard let documents else { return }
        let url = documents.appendingPathComponent("pclink-d2-automation-debug.txt")
        let line = ISO8601DateFormatter().string(from: Date()) + " " + text + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func result(for state: PCPairingPageState) -> [String: Any] {
        switch state {
        case .paired(let record):
            return ["ok": true, "detail": record.peerName]
        case .failed(let message):
            return ["ok": false, "detail": message]
        default:
            return ["ok": false, "detail": "pairing ended in \(String(describing: state))"]
        }
    }
}
#endif
