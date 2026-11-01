// SPDX-License-Identifier: MIT
// Lightweight persistence for user-granted folders. The full capability stack
// uses security-scoped bookmarks; the session baseline only needs the phone
// permission center to remember a picked folder across launches.

import Foundation

enum PhoneFolderBookmarkStore {
    struct Restored {
        let roots: [PhoneFolderRoot]
        let error: String?
    }

    private struct Record: Codable {
        let id: String
        let name: String
        let kind: String
        let path: String
    }

    private static let key = "phone-dsh.folder-grants.v1"

    static func load(defaults: UserDefaults) -> Restored {
        guard let data = defaults.data(forKey: key) else { return Restored(roots: [], error: nil) }
        do {
            let records = try JSONDecoder().decode([Record].self, from: data)
            let roots = records.map { record in
                PhoneFolderRoot(id: record.id, name: record.name, kind: record.kind,
                                url: URL(fileURLWithPath: record.path))
            }
            return Restored(roots: roots, error: nil)
        } catch {
            return Restored(roots: [], error: error.localizedDescription)
        }
    }

    static func save(_ root: PhoneFolderRoot, existing: [PhoneFolderRoot], defaults: UserDefaults) throws {
        var roots = existing.filter { $0.id != root.id }
        roots.append(root)
        let records = roots.compactMap { root -> Record? in
            guard let url = root.url else { return nil }
            return Record(id: root.id, name: root.name, kind: root.kind, path: url.path)
        }
        defaults.set(try JSONEncoder().encode(records), forKey: key)
    }

    static func isAccessible(_ root: PhoneFolderRoot) -> Bool {
        guard let url = root.url else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func metadata(for root: PhoneFolderRoot) -> [String: Any] {
        var result: [String: Any] = ["id": root.id, "name": root.name, "kind": root.kind]
        if let url = root.url { result["path"] = url.path }
        return result
    }
}
