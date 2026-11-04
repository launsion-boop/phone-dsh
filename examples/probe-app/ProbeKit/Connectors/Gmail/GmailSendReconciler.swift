// SPDX-License-Identifier: MIT

import Foundation

public enum GmailReconcileResult: Sendable, Equatable {
    case reconciled(ProviderReceipt)
    case unknown
    case notApplicable
}

public struct GmailSendReconciler: Sendable {
    private let client: any GmailReading
    private let draftsClient: GmailClient?
    private let ledger: any OperationLedger

    public init(client: any GmailReading, ledger: any OperationLedger) {
        self.client = client
        self.draftsClient = client as? GmailClient
        self.ledger = ledger
    }

    public func reconcilePending() async -> [UUID: GmailReconcileResult] {
        let pending = await ledger.pending()
        var results: [UUID: GmailReconcileResult] = [:]
        for record in pending {
            results[record.id] = await reconcile(record)
        }
        return results
    }

    public func reconcile(_ record: OperationRecord) async -> GmailReconcileResult {
        guard record.phase == .unknown || record.phase == .committing else { return .notApplicable }
        if ["gmail.draft.create", "gmail.draft.update"].contains(record.intent.toolName) {
            return await reconcileDraft(record)
        }
        guard ["gmail.message.reply", "gmail.message.send", "gmail.message.forward"].contains(record.intent.toolName),
              let arguments = try? GmailJSON.decoder.decode(ReconcileSendArguments.self,
                                                             from: Data(record.intent.argumentsJSON.utf8)) else {
            return .notApplicable
        }
        let input = arguments.input
        let messageID = "<\(record.id.uuidString.lowercased())@phone-dsh.invalid>"
        do {
            let result = try await client.search(GmailSearchQuery(
                since: record.createdAt.addingTimeInterval(-300), until: record.createdAt.addingTimeInterval(86_400),
                sentOnly: true, rfc822MessageID: messageID, limit: 10))
            let matches = result.messages.filter { message in
                message.operationID?.lowercased() == record.id.uuidString.lowercased() &&
                message.requestDigest == input.digest &&
                (input.draft.threadID == nil || message.threadID == input.draft.threadID)
            }
            guard matches.count == 1, let message = matches.first else { return .unknown }
            let raw = String(decoding: (try JSONSerialization.data(withJSONObject: [
                "id": message.id, "threadID": message.threadID, "reconciled": true,
            ], options: [.sortedKeys])), as: UTF8.self)
            let receipt = ProviderReceipt(providerObjectID: message.id, url: message.link.absoluteString, rawJSON: raw)
            _ = try await ledger.reconcile(record.id, receipt: receipt)
            return .reconciled(receipt)
        } catch {
            return .unknown
        }
    }

    private func reconcileDraft(_ record: OperationRecord) async -> GmailReconcileResult {
        guard let draftsClient else { return .unknown }
        do {
            let input: GmailDraftInput
            if record.intent.toolName == "gmail.draft.update" {
                input = try GmailJSON.decoder.decode(ReconcileDraftUpdateArguments.self,
                                                     from: Data(record.intent.argumentsJSON.utf8)).draft.input
            } else {
                input = try GmailJSON.decoder.decode(ReconcileDraftArguments.self,
                                                     from: Data(record.intent.argumentsJSON.utf8)).input
            }
            let expectedRaw = GmailMIME.rawMessage(input: input, operationID: nil, digest: nil)
            let matches = try await draftsClient.recentDrafts().filter { $0.raw == expectedRaw }
            guard matches.count == 1, let draft = matches.first else { return .unknown }
            let raw = String(decoding: try JSONSerialization.data(withJSONObject: [
                "id": draft.id, "messageID": draft.messageID, "reconciled": true,
            ], options: [.sortedKeys]), as: UTF8.self)
            let receipt = ProviderReceipt(providerObjectID: draft.id,
                                          url: "https://mail.google.com/mail/#all/\(draft.id)", rawJSON: raw)
            _ = try await ledger.reconcile(record.id, receipt: receipt)
            return .reconciled(receipt)
        } catch {
            return .unknown
        }
    }
}

private struct ReconcileDraftUpdateArguments: Decodable {
    let draftID: String
    let draft: ReconcileDraftArguments
}

private struct ReconcileSendArguments: Decodable {
    let kind: GmailSendKind
    let draft: ReconcileDraftArguments

    var input: GmailSendInput { GmailSendInput(kind: kind, draft: draft.input) }
}

private struct ReconcileDraftArguments: Decodable {
    let recipients: [String]
    let cc: [String]?
    let bcc: [String]?
    let subject: String
    let body: String
    let threadID: String?
    let inReplyTo: String?
    let references: String?
    let evidenceRefs: [String]?

    var input: GmailDraftInput {
        GmailDraftInput(recipients: recipients, cc: cc ?? [], bcc: bcc ?? [], subject: subject, body: body,
                        threadID: threadID, inReplyTo: inReplyTo, references: references,
                        evidenceRefs: evidenceRefs ?? [])
    }
}
