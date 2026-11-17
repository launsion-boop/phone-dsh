// SPDX-License-Identifier: MIT

import Foundation

/// One flat skill file's observable filesystem stamp. The producer re-reads and
/// hashes final bytes; this stamp only decides that a mutation happened.
public struct BotSkillFileStamp: Sendable, Equatable {
    public var name: String
    public var size: Int
    public var modifiedAtMS: Int64

    public init(name: String, size: Int, modifiedAtMS: Int64) {
        self.name = name
        self.size = size
        self.modifiedAtMS = modifiedAtMS
    }
}

/// One successful directory read. `missing` is ENOENT for the watched root;
/// `unreadable` is a permission/IO failure and must never be interpreted as
/// "every file was deleted".
public enum BotSkillDirectorySnapshot: Sendable, Equatable {
    case present([String: BotSkillFileStamp])
    case missing
    case unreadable
}

public enum BotSkillDirectoryChange: Sendable, Equatable {
    case written(String)
    case deleted(String)
}

public enum BotSkillDirectoryReconciler {
    public static func snapshot(_ root: URL) -> BotSkillDirectorySnapshot {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            .contentModificationDateKey,
        ]
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles])
        } catch let error as NSError {
            if error.code == NSFileReadNoSuchFileError
                || error.code == NSFileNoSuchFileError {
                return .missing
            }
            return .unreadable
        }
        var result: [String: BotSkillFileStamp] = [:]
        for file in files {
            guard file.pathExtension == "md",
                  let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let size = values.fileSize else { continue }
            let name = file.lastPathComponent
            guard !name.contains("/"), !name.contains("\\") else { continue }
            let modified = values.contentModificationDate
                .map { Int64(($0.timeIntervalSince1970 * 1_000).rounded()) } ?? 0
            result[name] = BotSkillFileStamp(
                name: name, size: size, modifiedAtMS: max(0, modified))
        }
        return .present(result)
    }

    /// `previous == nil` is the initial snapshot and emits nothing.
    public static func changes(
        previous: [String: BotSkillFileStamp]?,
        current: BotSkillDirectorySnapshot
    ) -> [BotSkillDirectoryChange] {
        guard let previous else { return [] }
        switch current {
        case .unreadable:
            // A permission/IO error is not an observed deletion.
            return []
        case .missing:
            // The watched root is gone: every previously visible file is gone
            // too (ENOENT), never a read failure.
            return previous.keys.sorted().map { .deleted($0) }
        case .present(let now):
            var result: [BotSkillDirectoryChange] = []
            for (name, stamp) in now.sorted(by: { $0.key < $1.key }) {
                if previous[name] != stamp { result.append(.written(name)) }
            }
            for name in previous.keys.sorted() where now[name] == nil {
                result.append(.deleted(name))
            }
            return result
        }
    }
}

/// Watches one skill root and reports real filesystem mutations to the caller.
/// The observer owns no skill state beyond the last stamp map; producers read
/// and hash the final bytes and record through L.
public final class BotSkillDirectoryObserver: @unchecked Sendable {
    public typealias Handler = @Sendable (String) -> Void

    private let root: URL
    private let queue: DispatchQueue
    private let onWritten: Handler?
    private let onDeleted: Handler?
    private let createRoot: Bool
    private var source: DispatchSourceFileSystemObject?
    private var previous: [String: BotSkillFileStamp]?
    private var started = false

    public init(root: URL,
                label: String = "bot.skill-directory-observer",
                createRoot: Bool = false,
                onWritten: Handler? = nil,
                onDeleted: Handler? = nil) {
        self.root = root
        self.queue = DispatchQueue(label: label)
        self.createRoot = createRoot
        self.onWritten = onWritten
        self.onDeleted = onDeleted
    }

    /// Returns false when the root cannot be opened; no callback is emitted.
    @discardableResult
    public func start() -> Bool {
        var didStart = false
        queue.sync {
            guard !started else { didStart = true; return }
            if createRoot {
                try? FileManager.default.createDirectory(
                    at: root, withIntermediateDirectories: true)
            }
            let initial = BotSkillDirectoryReconciler.snapshot(root)
            if case .unreadable = initial { return }
            previous = {
                if case .present(let files) = initial { return files }
                return [:]
            }()
            let fd = open(root.path, O_EVTONLY)
            guard fd >= 0 else { return }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete, .attrib],
                queue: queue)
            source.setEventHandler { [weak self] in self?.scan() }
            source.setCancelHandler { close(fd) }
            self.source = source
            source.resume()
            started = true
            didStart = true
            NSLog("[BOT_SKILL_OBSERVER] start root=%@", root.path)
        }
        return didStart
    }

    public func stop() {
        queue.sync {
            source?.cancel()
            source = nil
            started = false
        }
    }

    func scan() {
        guard started else { return }
        let current = BotSkillDirectoryReconciler.snapshot(root)
        let changes = BotSkillDirectoryReconciler.changes(
            previous: previous, current: current)
        if case .present(let files) = current { previous = files }
        if case .missing = current { previous = [:] }
        for change in changes {
            switch change {
            case .written(let name):
                NSLog("[BOT_SKILL_OBSERVER] written name=%@", name)
                onWritten?(name)
            case .deleted(let name):
                NSLog("[BOT_SKILL_OBSERVER] deleted name=%@", name)
                onDeleted?(name)
            }
        }
    }
}
