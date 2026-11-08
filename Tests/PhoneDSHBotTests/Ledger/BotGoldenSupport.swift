// SPDX-License-Identifier: MIT

import Foundation
@testable import PhoneDSHBot

func botRepositoryRoot(filePath: String = #filePath) -> URL {
    URL(fileURLWithPath: filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

func botGolden(_ name: String) throws -> [String: Any] {
    let url = botRepositoryRoot().appendingPathComponent("spec/bot/v1/golden/\(name).json")
    return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
}

func botJSONData(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value)
}

func botJSONValue(_ value: Any) throws -> BotJSONValue {
    try BotJSONValue.parse(botJSONData(value))
}

func botDecode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
    try JSONDecoder().decode(type, from: botJSONData(value))
}

func botJSONObject<T: Encodable>(_ value: T) throws -> Any {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try JSONSerialization.jsonObject(with: encoder.encode(value))
}
