// SPDX-License-Identifier: MIT

import Foundation

@MainActor
enum PhoneFolderBookmarkStore {
    private static let key = "phone-dsh.folder-grants.v1"

    private struct Record: Codable {
        let id: String
        let name: String
        let bookmark: Data
    }

    static func load(defaults: UserDefaults) -> (roots: [PhoneFolderRoot], error: String?) {
        guard let data = defaults.data(forKey: key) else { return ([], nil) }
        do {
            let records = try JSONDecoder().decode([Record].self, from: data)
            var roots: [PhoneFolderRoot] = []
            var skipped = 0
            for record in records {
                do {
                    var stale = false
                    let url = try URL(resolvingBookmarkData: record.bookmark,
                                      options: [], relativeTo: nil,
                                      bookmarkDataIsStale: &stale)
                    if stale { skipped += 1; continue }
                    roots.append(PhoneFolderRoot(id: record.id, name: record.name,
                                                 kind: "security-scoped", url: url))
                } catch {
                    skipped += 1
                }
            }
            return (roots, skipped > 0 ? "有 \(skipped) 个文件夹授权需要重新选择" : nil)
        } catch {
            return ([], "无法读取已保存的文件夹授权")
        }
    }

    static func save(_ root: PhoneFolderRoot, existing: [PhoneFolderRoot],
                     defaults: UserDefaults) throws {
        guard let url = root.url else { throw PhoneToolError.invalidArguments("文件夹授权缺少 URL") }
        var roots = existing.filter { $0.id != root.id }
        roots.append(root)
        guard roots.count <= 9 else { throw PhoneToolError.invalidArguments("最多保存 9 个授权文件夹") }
        let records = try roots.map { root -> Record in
            guard let url = root.url else { throw PhoneToolError.invalidArguments("文件夹授权缺少 URL") }
            return try Record(id: root.id, name: root.name,
                              bookmark: url.bookmarkData(options: []))
        }
        defaults.set(try JSONEncoder().encode(records), forKey: key)
    }

    static func isAccessible(_ root: PhoneFolderRoot) -> Bool {
        guard let url = root.url else { return false }
        let accessing = url.startAccessingSecurityScopedResource()
        if accessing { url.stopAccessingSecurityScopedResource() }
        return accessing
    }

    static func metadata(for root: PhoneFolderRoot) -> [String: Any] {
        var result: [String: Any] = [
            "rootId": root.id,
            "id": root.id,
            "name": root.name,
            "kind": root.kind,
            "persistent": true,
        ]
        guard let url = root.url else {
            result["available"] = true
            return result
        }
        let accessing = url.startAccessingSecurityScopedResource()
        guard accessing else {
            result["available"] = false
            return result
        }
        defer { url.stopAccessingSecurityScopedResource() }
        var count = 0
        var truncated = false
        if let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let child as URL in enumerator {
                guard let values = try? child.resourceValues(forKeys: [.isRegularFileKey]),
                      values.isRegularFile == true else { continue }
                count += 1
                if count >= 10_000 {
                    truncated = true
                    break
                }
            }
        }
        result["available"] = true
        result["fileCount"] = count
        result["truncated"] = truncated
        result["lastScanAt"] = PhoneToolEnvelope.iso8601(Date())
        return result
    }
}
