// SPDX-License-Identifier: MIT

import Foundation

#if DEBUG
public enum OfficeFixtureInstaller {
    private actor Gate {
        func install(store: OfficeArtifactStore) async {
            let environment = ProcessInfo.processInfo.environment
            guard let raw = environment["PDSH_OFFICE_FIXTURE_DIR"], !raw.isEmpty else { return }
            let namespace = environment["PDSH_OFFICE_ARTIFACT_NAMESPACE"] ?? ""
            let key = "pdsh.office.fixtures.\(namespace).\(raw)"
            let defaults = UserDefaults.standard
            guard !defaults.bool(forKey: key) else { return }
            let directory = URL(fileURLWithPath: raw, isDirectory: true)
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
            for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where url.pathExtension.lowercased() != "json" {
                _ = try? await store.importFile(at: url)
            }
            defaults.set(true, forKey: key)
        }
    }

    private static let gate = Gate()

    public static func installIfNeeded(store: OfficeArtifactStore) async {
        await gate.install(store: store)
    }
}
#endif
