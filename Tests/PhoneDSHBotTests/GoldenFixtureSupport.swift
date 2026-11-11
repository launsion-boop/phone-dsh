// SPDX-License-Identifier: MIT

import Foundation

/// Loads a Bot golden plus its same-name `.phone.json` overlay.
///
/// The upstream file is the untouched `export-vectors.mjs` batch. The overlay
/// may add cases or replace a case with the same identity (`name`, `id`,
/// `nonce`, `action.nonce`), but it can never remove an upstream case. Object
/// containers merge by key, array containers append/replace by identity, and
/// overlay metadata (`vector`, `source`, `upstream`, `delta`) stays
/// documentation only. `spec/bot/v1/README.md` §8 and
/// `spec/bot/v2/README.md` §4 are the normative prose.
enum BotGoldenFixture {
    struct FixtureError: Error, CustomStringConvertible {
        let description: String
    }

    private static let metadataKeys: Set<String> = [
        "schemaVersion", "vector", "source", "upstream", "delta",
    ]

    /// Vectors moved to the phoneDSH-owned v2 tree at the 2026-11-10 handover.
    /// Everything else is still the untouched dsh-bot export under v1.
    private static let v2GoldenNames: Set<String> = [
        "memory-fact", "memory-injection", "memory-recall",
        "wake-routine", "held-inbox", "routine-document", "routine-notification",
    ]

    private static func goldenDirectory(for name: String) -> String {
        let base = name.hasSuffix(".phone") ? String(name.dropLast(".phone".count)) : name
        return v2GoldenNames.contains(base) ? "spec/bot/v2/golden" : "spec/bot/v1/golden"
    }

    static func repositoryRoot(filePath: String = #filePath) throws -> URL {
        var candidate = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            let marker = candidate.appendingPathComponent("spec/bot/v1/golden", isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        throw FixtureError(description: "cannot locate spec/bot/v1/golden from #filePath")
    }

    static func rawObject(_ name: String) throws -> [String: Any] {
        let url = try repositoryRoot().appendingPathComponent("\(goldenDirectory(for: name))/\(name).json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let dictionary = object as? [String: Any] else {
            throw FixtureError(description: "\(name).json is not an object")
        }
        return dictionary
    }

    static func rawData(_ name: String) throws -> Data {
        let url = try repositoryRoot().appendingPathComponent("\(goldenDirectory(for: name))/\(name).json")
        return try Data(contentsOf: url)
    }

    /// Load `name.json` and merge `name.phone.json` when present.
    static func mergedObject(_ name: String) throws -> [String: Any] {
        let upstream = try rawObject(name)
        let root = try repositoryRoot()
        let overlayURL = root.appendingPathComponent("\(goldenDirectory(for: name))/\(name).phone.json")
        guard FileManager.default.fileExists(atPath: overlayURL.path) else { return upstream }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: overlayURL))
        guard let overlay = object as? [String: Any] else {
            throw FixtureError(description: "\(name).phone.json is not an object")
        }
        return merge(upstream: upstream, overlay: overlay)
    }

    static func mergedData(_ name: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: mergedObject(name), options: [.sortedKeys])
    }

    static func merge(upstream: [String: Any], overlay: [String: Any]) -> [String: Any] {
        mergeObject(upstream, overlay)
    }

    private static func mergeObject(_ upstream: [String: Any], _ overlay: [String: Any]) -> [String: Any] {
        var merged = upstream
        for (key, value) in overlay where !metadataKeys.contains(key) {
            if let current = merged[key] {
                merged[key] = mergeValue(current, value)
            } else {
                merged[key] = value
            }
        }
        return merged
    }

    private static func mergeValue(_ upstream: Any, _ overlay: Any) -> Any {
        if let upstreamObject = upstream as? [String: Any],
           let overlayObject = overlay as? [String: Any] {
            return mergeObject(upstreamObject, overlayObject)
        }
        if let upstreamArray = upstream as? [Any],
           let overlayArray = overlay as? [Any] {
            return mergeArray(upstreamArray, overlayArray)
        }
        return overlay
    }

    private static func mergeArray(_ upstream: [Any], _ overlay: [Any]) -> [Any] {
        var merged = upstream
        var positions: [String: Int] = [:]
        for (index, item) in merged.enumerated() {
            if let identifier = identity(item) { positions[identifier] = index }
        }
        var seen = Set(merged.map(canonical))
        for item in overlay {
            let identifier = identity(item)
            if let identifier, let position = positions[identifier] {
                merged[position] = item
                continue
            }
            let text = canonical(item)
            if identifier == nil && seen.contains(text) { continue }
            if let identifier { positions[identifier] = merged.count }
            seen.insert(text)
            merged.append(item)
        }
        return merged
    }

    private static func identity(_ value: Any) -> String? {
        guard let object = value as? [String: Any] else { return nil }
        for key in ["name", "id", "nonce"] {
            if let value = object[key] as? String { return "\(key):\(value)" }
        }
        if let action = object["action"] as? [String: Any],
           let nonce = action["nonce"] as? String {
            return "action.nonce:\(nonce)"
        }
        return nil
    }

    private static func canonical(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
