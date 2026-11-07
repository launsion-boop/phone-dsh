// SPDX-License-Identifier: MIT

import Foundation

enum DurableEventSnapshots {
    static func data<T: Encodable>(for snapshot: T, botId: String) throws -> BotJSONValue {
        let encoded = try JSONEncoder().encode(snapshot)
        return .object([
            "botId": .string(botId),
            "document": try BotJSONValue.parse(encoded),
        ])
    }

    static func decode<T: Decodable>(_ type: T.Type, from event: BotEvent, botId: String) throws -> T? {
        guard case let .object(root) = event.data,
              case let .string(eventBotId)? = root["botId"], eventBotId == botId,
              let document = root["document"] else { return nil }
        return try JSONDecoder().decode(T.self, from: try document.encoded())
    }

}
