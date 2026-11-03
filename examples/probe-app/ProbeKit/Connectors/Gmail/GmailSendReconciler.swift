// SPDX-License-Identifier: MIT

import Foundation

public enum GmailReconcileResult: Sendable, Equatable {
    case reconciled(ProviderReceipt)
    case unknown
    case notApplicable
}

public struct GmailSendReconciler: Sendable {
    private let client: any GmailReading
    private let ledger: any OperationLedger

    public init(client: any GmailReading, ledger: any OperationLedger) {
        self.client = client
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
        guard record.phase == .unknown || record.phase == .committing,
              ["gmail.message.reply", "gmail.message.send", "gmail.message.forward"].contains(record.intent.toolName),
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
            try await ledger.commit(record.id, receipt: receipt)
            return .reconciled(receipt)
        } catch {
            return .unknown
        }
    }
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
