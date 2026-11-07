// SPDX-License-Identifier: MIT
import Darwin
import Foundation

/// Observed local evidence is never an authenticated or consistent snapshot.
public struct DeviceTaskLegacyInspection: Sendable, Equatable {
    public enum Status: String, Sendable { case busy, incomplete }
    public enum Reason: String, Sendable {
        case rootMissing, rootUnreadable, rootUnsupported, entryBudget, byteBudget, ioError, cancelled
    }
    public struct Entry: Identifiable, Sendable, Equatable {
        public enum Kind: String, Sendable { case observed, unparsed, unreadable, symlink, nonRegular, unexamined }
        public struct Claims: Sendable, Equatable {
            public let deviceID: String?
            public let taskID: String?
            public let phase: String?
            public let outcomeKind: String?
            public init(deviceID: String?, taskID: String?, phase: String?, outcomeKind: String?) {
                self.deviceID = deviceID; self.taskID = taskID; self.phase = phase; self.outcomeKind = outcomeKind
            }
        }
        public let id: String
        public let label: String
        public let kind: Kind
        public let claims: Claims?
        public init(id: String, label: String, kind: Kind, claims: Claims?) {
            self.id = id; self.label = label; self.kind = kind; self.claims = claims
        }
    }
    public let status: Status
    public let entries: [Entry]
    public let cancelled: Bool
    public let reasons: [Reason]
    public init(status: Status, entries: [Entry], cancelled: Bool, reasons: [Reason]) {
        self.status = status; self.entries = entries; self.cancelled = cancelled; self.reasons = reasons
    }
}

public enum DeviceTaskLegacyInspector {
    #if DEBUG
    static var testAfterReservation: (() -> Void)?
    static var testAfterStat: ((String) -> Void)?
    static var testFileOpened: ((Int32) -> Void)?
    static var testDirectoryOpened: ((Int32) -> Void)?
    static var testBeforeRelease: (() -> Void)?
    #endif
    /// Observes only this app's existing Application Support journal. It does
    /// not create storage, open the lock file, or start device tasks.
    public static func inspect() async -> DeviceTaskLegacyInspection {
        guard !Task.isCancelled else { return .init(status: .incomplete, entries: [], cancelled: true, reasons: [.cancelled]) }
        return await inspect(applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
    }

    /// The injected ancestor/target entry points are internal for isolated
    /// filesystem tests; callers outside this module cannot choose a root.
    static func inspect(applicationSupport: URL?) async -> DeviceTaskLegacyInspection {
        guard !Task.isCancelled else { return .init(status: .incomplete, entries: [], cancelled: true, reasons: [.cancelled]) }
        guard let applicationSupport else { return .init(status: .incomplete, entries: [], cancelled: false, reasons: [.rootUnreadable]) }
        return await inspect(directory: applicationSupport.appendingPathComponent("device-task-journal", isDirectory: true))
    }

    static func inspect(directory: URL) async -> DeviceTaskLegacyInspection {
        guard !Task.isCancelled else { return .init(status: .incomplete, entries: [], cancelled: true, reasons: [.cancelled]) }
        guard DeviceTaskJournal.reserveInspection() else {
            if Task.isCancelled { return .init(status: .incomplete, entries: [], cancelled: true, reasons: [.cancelled]) }
            return .init(status: .busy, entries: [], cancelled: false, reasons: [])
        }
        defer {
            #if DEBUG
            testBeforeRelease?()
            #endif
            DeviceTaskJournal.releaseInspection()
        }
        #if DEBUG
        testAfterReservation?()
        #endif
        guard !Task.isCancelled else { return .init(status: .incomplete, entries: [], cancelled: true, reasons: [.cancelled]) }
        return scan(directory: directory)
    }

    // This canonical mapping is shared by path and claim display. Path callers
    // separately validate that components cannot contain NUL or slash.
    static func escape(_ bytes: [UInt8]) -> String {
        let hex = Array("0123456789ABCDEF".utf8)
        var result = [UInt8]()
        result.reserveCapacity(bytes.count)
        for byte in bytes {
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 46 || byte == 95 {
                result.append(byte)
            } else {
                result.append(37); result.append(hex[Int(byte >> 4)]); result.append(hex[Int(byte & 15)])
            }
        }
        return String(decoding: result, as: UTF8.self)
    }

    static func escapedPath(_ components: [[UInt8]]) -> String? {
        guard !components.isEmpty, components.allSatisfy({ component in
            !component.isEmpty && component != [46] && component != [46, 46] && !component.contains(0) && !component.contains(47)
        }) else { return nil }
        return components.map(escape).joined(separator: "/")
    }

    private static func escapedClaim(_ raw: Data?) -> String? {
        guard let raw, let value = try? JSONDecoder().decode(String.self, from: raw) else { return nil }
        let bytes = Array(value.utf8)
        guard bytes.count <= 256, !bytes.contains(0) else { return nil }
        return escape(bytes)
    }

    /// Relevant members are checked against the original bytes before JSON
    /// object parsing can discard a duplicate spelling.
    static func claims(_ data: Data, isIntent: Bool) -> (parsed: Bool, value: DeviceTaskLegacyInspection.Entry.Claims?) {
        let names: Set<String> = isIntent ? ["device_id", "task_id"] : ["device_id", "task", "phase", "outcome"]
        var raw = UniqueJSONKeys(data)
        guard let members = raw.rawRootMembers(capturing: names, enforcingUnique: names) else { return (false, nil) }
        func member(_ data: Data?, key: String) -> (valid: Bool, value: Data?) {
            guard let data else { return (true, nil) }
            // The owning raw parser has already validated this complete JSON
            // value. A non-object cannot contain the requested member.
            guard data.first(where: { ![9, 10, 13, 32].contains($0) }) == 123 else { return (true, nil) }
            var nested = UniqueJSONKeys(data)
            guard let values = nested.rawRootMembers(capturing: [key], enforcingUnique: [key]) else { return (false, nil) }
            return (true, values[key])
        }
        let task = isIntent ? (true, members["task_id"]) : member(members["task"], key: "id")
        let outcome = isIntent ? (true, nil) : member(members["outcome"], key: "kind")
        guard task.0 && outcome.0 else { return (false, nil) }
        let result = DeviceTaskLegacyInspection.Entry.Claims(
            deviceID: escapedClaim(members["device_id"]),
            taskID: escapedClaim(task.1),
            phase: isIntent ? nil : escapedClaim(members["phase"]),
            outcomeKind: isIntent ? nil : escapedClaim(outcome.1))
        if result.deviceID == nil && result.taskID == nil && result.phase == nil && result.outcomeKind == nil { return (true, nil) }
        return (true, result)
    }

    private static func scan(directory: URL) -> DeviceTaskLegacyInspection {
        var scanner = Scanner()
        guard let path = checkedRootPath(directory) else { return .init(status: .incomplete, entries: [], cancelled: false, reasons: [.rootUnsupported]) }
        let fd = path.withUnsafeBufferPointer { Darwin.open($0.baseAddress!, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
        guard fd >= 0 else {
            if Task.isCancelled { return .init(status: .incomplete, entries: [], cancelled: true, reasons: [.cancelled]) }
            let code = errno
            let reason: DeviceTaskLegacyInspection.Reason
            if code == ENOENT { reason = .rootMissing }
            else if code == ELOOP || code == ENOTDIR { reason = .rootUnsupported }
            else { reason = .rootUnreadable }
            return .init(status: .incomplete, entries: [], cancelled: false, reasons: [reason])
        }
        #if DEBUG
        testDirectoryOpened?(fd)
        #endif
        defer { Darwin.close(fd) }
        scanner.enumerate(directoryFD: fd, components: [], root: true)
        if Task.isCancelled { scanner.addReason(.cancelled) }
        return .init(status: .incomplete, entries: scanner.entries, cancelled: Task.isCancelled,
                     reasons: scanner.reasons)
    }

    /// Validate the actual decoded filesystem representation without resolving
    /// dot components. Only the final component is opened with O_NOFOLLOW;
    /// system-managed symlinks in trusted ancestors remain usable.
    private static func checkedRootPath(_ directory: URL) -> [CChar]? {
        guard directory.isFileURL, directory.host?.isEmpty != false,
              directory.user == nil, directory.password == nil, directory.port == nil,
              directory.query == nil, directory.fragment == nil else { return nil }
        return directory.withUnsafeFileSystemRepresentation { path -> [CChar]? in
            guard let path else { return nil }
            var bytes = Array(UnsafeBufferPointer(start: UnsafeRawPointer(path).assumingMemoryBound(to: UInt8.self), count: strlen(path)))
            guard bytes.first == 47 else { return nil }
            while bytes.count > 1 && bytes.last == 47 { bytes.removeLast() }
            let components = bytes.split(separator: 47, omittingEmptySubsequences: true)
            guard !components.isEmpty, components.allSatisfy({ $0 != [46] && $0 != [46, 46] }) else { return nil }
            var result = bytes.map { CChar(bitPattern: $0) }; result.append(0)
            return result
        }
    }

    private struct Scanner {
        static let maxEntries = 16_385
        static let maxTotal = 4_194_304
        static let maxFile = 65_536
        var entries: [DeviceTaskLegacyInspection.Entry] = []
        var reasons: [DeviceTaskLegacyInspection.Reason] = []
        var count = 0
        var bytesRead = 0

        mutating func addReason(_ reason: DeviceTaskLegacyInspection.Reason) {
            if !reasons.contains(reason) { reasons.append(reason) }
        }
        mutating func add(_ parts: [[UInt8]], _ kind: DeviceTaskLegacyInspection.Entry.Kind,
                          _ claims: DeviceTaskLegacyInspection.Entry.Claims? = nil) {
            guard let label = DeviceTaskLegacyInspector.escapedPath(parts) else { addReason(.ioError); return }
            entries.append(.init(id: label, label: label, kind: kind, claims: claims))
        }
        private func withName<T>(_ bytes: [UInt8], _ body: (UnsafePointer<CChar>) -> T) -> T {
            var name = bytes.map { CChar(bitPattern: $0) }; name.append(0)
            return name.withUnsafeBufferPointer { body($0.baseAddress!) }
        }
        private func sameFile(_ a: stat, _ b: stat) -> Bool {
            a.st_dev == b.st_dev && a.st_ino == b.st_ino && (a.st_mode & S_IFMT) == (b.st_mode & S_IFMT)
        }
        mutating func enumerate(directoryFD: Int32, components: [[UInt8]], root: Bool) {
            let streamFD = Darwin.openat(directoryFD, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard streamFD >= 0 else { addReason(.ioError); return }
            #if DEBUG
            DeviceTaskLegacyInspector.testDirectoryOpened?(streamFD)
            #endif
            guard let stream = Darwin.fdopendir(streamFD) else { Darwin.close(streamFD); addReason(.ioError); return }
            defer { Darwin.closedir(stream) }
            while !Task.isCancelled {
                errno = 0
                guard let entry = Darwin.readdir(stream) else { if errno != 0 { addReason(.ioError) }; break }
                let length = Int(entry.pointee.d_namlen)
                let bytes = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: UInt8.self, capacity: length) { Array(UnsafeBufferPointer(start: $0, count: length)) }
                }
                if bytes == [46] || bytes == [46, 46] { continue }
                if count >= Self.maxEntries { addReason(.entryBudget); break }
                count += 1
                if bytes == Array(".lock".utf8) { continue }
                let parts = components + [bytes]
                guard DeviceTaskLegacyInspector.escapedPath(parts) != nil else { addReason(.ioError); continue }
                var before = stat()
                let statResult = withName(bytes) { Darwin.fstatat(directoryFD, $0, &before, AT_SYMLINK_NOFOLLOW) }
                guard statResult == 0 else { add(parts, .unreadable); addReason(.ioError); continue }
                #if DEBUG
                DeviceTaskLegacyInspector.testAfterStat?(DeviceTaskLegacyInspector.escapedPath(parts) ?? "")
                #endif
                let type = before.st_mode & S_IFMT
                if type == S_IFLNK { add(parts, .symlink); continue }
                if root && bytes == Array("ble-ops".utf8) && type == S_IFDIR {
                    let child = withName(bytes) { Darwin.openat(directoryFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
                    guard child >= 0 else { add(parts, .unreadable); addReason(.ioError); continue }
                    #if DEBUG
                    DeviceTaskLegacyInspector.testDirectoryOpened?(child)
                    #endif
                    var after = stat()
                    guard Darwin.fstat(child, &after) == 0, sameFile(before, after) else {
                        Darwin.close(child); add(parts, .unreadable); addReason(.ioError); continue
                    }
                    enumerate(directoryFD: child, components: parts, root: false)
                    Darwin.close(child)
                    continue
                }
                guard type == S_IFREG else { add(parts, .nonRegular); continue }
                guard before.st_nlink == 1 else { add(parts, .unexamined); continue }
                guard before.st_size >= 0, before.st_size <= Self.maxFile,
                      bytesRead + Int(before.st_size) < Self.maxTotal else {
                    add(parts, .unexamined); addReason(.byteBudget); continue
                }
                let file = withName(bytes) { Darwin.openat(directoryFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
                guard file >= 0 else { add(parts, .unreadable); addReason(.ioError); continue }
                #if DEBUG
                DeviceTaskLegacyInspector.testFileOpened?(file)
                #endif
                var actual = stat()
                guard Darwin.fstat(file, &actual) == 0, sameFile(before, actual), actual.st_nlink == 1,
                      actual.st_size == before.st_size else {
                    Darwin.close(file); add(parts, .unreadable); addReason(.ioError); continue
                }
                var data = Data(); var readError = false; var reachedEOF = false
                while data.count <= Self.maxFile && bytesRead < Self.maxTotal && !Task.isCancelled {
                    var buffer = [UInt8](repeating: 0, count: min(4096, Self.maxFile + 1 - data.count, Self.maxTotal - bytesRead))
                    let n = Darwin.read(file, &buffer, buffer.count)
                    if n < 0 { if errno == EINTR { continue }; readError = true; break }
                    if n == 0 { reachedEOF = true; break }
                    bytesRead += n; data.append(contentsOf: buffer.prefix(n))
                }
                var final = stat()
                let stable = Darwin.fstat(file, &final) == 0 && sameFile(actual, final) && final.st_size == actual.st_size
                Darwin.close(file)
                if Task.isCancelled { add(parts, .unexamined); addReason(.cancelled); break }
                guard !readError && stable else { add(parts, .unreadable); addReason(.ioError); continue }
                guard reachedEOF && data.count <= Self.maxFile && data.count == Int(actual.st_size) else {
                    add(parts, .unexamined); addReason(.byteBudget); continue
                }
                let result = DeviceTaskLegacyInspector.claims(data, isIntent: !root)
                add(parts, result.parsed ? .observed : .unparsed, result.value)
            }
            if Task.isCancelled { addReason(.cancelled) }
        }
    }
}
