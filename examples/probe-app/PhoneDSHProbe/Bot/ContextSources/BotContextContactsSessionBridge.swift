// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHBot
import PhoneDSHShell

/// App-side owner of the frozen `PhoneBotContactsQuerying` seam. The trusted
/// exec session is mapped by Bot composition ownership; model arguments never
/// provide botID. C registers this only on the Bot-scoped host/exec provider.
@MainActor
final class BotContextContactsSessionBridge: PhoneBotContactsQuerying,
                                           PhoneContactsSessionClassifying {
    private weak var composition: BotRuntimeComposition?
    private let verifiedOrdinarySession: @Sendable (String) -> Bool

    init(composition: BotRuntimeComposition,
         verifiedOrdinarySession: @escaping @Sendable (String) -> Bool = { _ in false }) {
        self.composition = composition
        self.verifiedOrdinarySession = verifiedOrdinarySession
    }

    func classifyContactsCaller(callerSessionID: String) async -> PhoneContactsCaller {
        guard !callerSessionID.isEmpty else {
            return .invalid(reason: "missing tool-call session")
        }
        if let composition,
           let botID = await composition.botID(forToolSession: callerSessionID) {
            return .bot(botID: botID)
        }
        if verifiedOrdinarySession(callerSessionID) { return .ordinary }
        return .invalid(reason: "unrecognized tool-call session")
    }

    func runContactsCommand(arguments: [String],
                                   callerSessionID: String) async -> PhoneRecordCommandResult {
        guard let composition,
              let botID = await composition.botID(forToolSession: callerSessionID),
              let assembly = composition.contextSourcesAssembly else {
            return Self.result(code: "not_authorized",
                               message: "trusted Bot session is not recognized")
        }
        let raw = arguments.joined(separator: " ")
        guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let query = object["query"] as? String else {
            return Self.result(code: "invalid_arguments", message: "query is required")
        }
        let rawLimit = (object["limit"] as? NSNumber)?.intValue ?? 20
        let limit = min(max(rawLimit, 1), 20)
        do {
            let observation = try await assembly.readContacts(
                botID: botID, query: query, limit: limit)
            return PhoneRecordCommandResult(
                stdout: try BotContextContactsToolBridge.response(observation), exitCode: 0)
        } catch let error as BotContextSourceError {
            switch error {
            case .notAuthorized, .revoked:
                return Self.result(code: "not_authorized",
                                   message: "Bot contacts source is not authorized or subscribed")
            case .invalidRequest:
                return Self.result(code: "invalid_arguments", message: "invalid contacts query")
            case .staleCallback:
                return Self.result(code: "not_authorized", message: "contacts generation changed")
            default:
                return Self.result(code: "unavailable", message: "contacts source unavailable")
            }
        } catch {
            return Self.result(code: "unavailable", message: "contacts source unavailable")
        }
    }

    private static func result(code: String, message: String) -> PhoneRecordCommandResult {
        let json: [String: Any] = [
            "ok": false, "tool": "contacts.search", "egress": false,
            "error": ["code": code, "message": message],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
        return PhoneRecordCommandResult(stdout: String(decoding: data, as: UTF8.self), exitCode: 0)
    }
}
