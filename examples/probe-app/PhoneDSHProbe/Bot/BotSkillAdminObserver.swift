// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHBot

/// Host-side bridge for feature-admin's user-dsh skill store. The Remote
/// writes/deletes the real file under `materialized/home/skills`; this observer
/// sees the durable file result and records it through R2's producer. It never
/// parses bash/output and never appends a `skill.changed` event itself.
final class BotSkillAdminObserver: @unchecked Sendable {
    private let root: URL
    private let producer: BotSkillProvenanceProducer
    private let queue = DispatchQueue(label: "bot.skill-admin-observer")
    private var source: DispatchSourceFileSystemObject?
    private var known: [String: Date] = [:]

    init(root: URL, producer: BotSkillProvenanceProducer) {
        self.root = root
        self.producer = producer
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.known = self.snapshot()
            let fd = open(self.root.path, O_EVTONLY)
            guard fd >= 0 else { return }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .rename, .delete],
                queue: self.queue)
            source.setEventHandler { [weak self] in self?.scan() }
            source.setCancelHandler { close(fd) }
            self.source = source
            source.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.source?.cancel()
            self?.source = nil
        }
    }

    private func snapshot() -> [String: Date] {
        let keys: [FileAttributeKey] = [.modificationDate]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) else { return [:] }
        var result: [String: Date] = [:]
        for file in files where file.pathExtension == "md" {
            let values = try? file.resourceValues(forKeys: Set(keys))
            result[file.lastPathComponent] = values?.modificationDate ?? .distantPast
        }
        return result
    }

    private func scan() {
        let current = snapshot()
        for (name, modified) in current where known[name] != modified {
            Task { _ = try? await producer.recordUserDshWrite(fileName: name) }
        }
        for name in known.keys where current[name] == nil {
            Task { _ = try? await producer.recordUserDshDelete(fileName: name) }
        }
        known = current
    }
}
