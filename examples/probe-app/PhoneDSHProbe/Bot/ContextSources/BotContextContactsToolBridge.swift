// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHBot
import PhoneDSHShell

/// Per-Bot bridge for the existing native `phone contacts.search` tool.
///
/// The botID is bound at construction by the authenticated composition, never
/// read from model arguments. Ordinary assistant hosts keep the old
/// Office/PhoneCapability bridge; only a Bot host selects this bridge. It does
/// not add a model tool, catalog entry, store, or a second contacts path: it
/// calls the Bot context source's consent/subscription-gated read.
@MainActor
public final class BotContextContactsToolBridge: PhoneToolBridge {
    public let supportsContext = false
    public let handles: Set<String> = ["contacts.search"]
    public let botID: String
    private weak var assembly: BotContextSourcesAssembly?

    public init(botID: String, assembly: BotContextSourcesAssembly?) {
        self.botID = botID
        self.assembly = assembly
    }

    public func callTool(name: String, arguments: String) async throws -> String {
        let tool = name.hasPrefix("phone.") ? String(name.dropFirst("phone.".count)) : name
        guard tool == "contacts.search" else {
            return Self.failure(code: "unknown_tool", message: "unknown tool")
        }
        guard let assembly else {
            return Self.failure(code: "unavailable", message: "Bot context sources unavailable")
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any],
              let query = object["query"] as? String else {
            return Self.failure(code: "invalid_arguments", message: "query is required")
        }
        let rawLimit = (object["limit"] as? NSNumber)?.intValue ?? 20
        let limit = min(max(rawLimit, 1), 20)
        do {
            let observation = try await assembly.readContacts(
                botID: botID, query: query, limit: limit)
            guard case .object(let payload) = observation.payload else {
                return Self.failure(code: "invalid_response", message: "contacts observation has no object payload")
            }
            return try Self.response(observation)
        } catch let error as BotContextSourceError {
            switch error {
            case .notAuthorized, .revoked:
                return Self.failure(code: "not_authorized", message: "Bot contacts source is not authorized or subscribed")
            case .invalidRequest:
                return Self.failure(code: "invalid_arguments", message: "invalid contacts query")
            case .staleCallback:
                return Self.failure(code: "not_authorized", message: "contacts generation changed")
            default:
                return Self.failure(code: "unavailable", message: "contacts source unavailable")
            }
        } catch {
            return Self.failure(code: "unavailable", message: "contacts source unavailable")
        }
    }

    static func response(_ observation: BotContextObservation) throws -> String {
        guard case .object(let payload) = observation.payload else {
            throw BotContextSourceError.invalidRequest("contacts observation has no object payload")
        }
        let encoded = try JSONEncoder().encode(payload)
        guard var data = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw BotContextSourceError.invalidRequest("contacts payload is not an object")
        }
        data["source"] = observation.source.rawValue
        data["permissionRevision"] = observation.permissionRevision
        data["masked"] = true
        if let key = observation.resource?.key { data["sourceKey"] = key }
        let response: [String: Any] = [
            "ok": true, "tool": "contacts.search", "egress": false,
            "scope": "contacts.read", "data": data,
        ]
        let bytes = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func failure(code: String, message: String) -> String {
        let object: [String: Any] = [
            "ok": false, "tool": "contacts.search", "egress": false,
            "error": ["code": code, "message": message],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return #"{"ok":false,"tool":"contacts.search","error":{"code":"unavailable"}}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}
