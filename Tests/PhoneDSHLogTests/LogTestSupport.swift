// SPDX-License-Identifier: MIT
// Shared fixtures for PhoneDSHLogTests. No absolute repository path is
// stored: the spec golden directory is found from #filePath at run time.

import Foundation
import XCTest
@testable import PhoneDSHLog
import PhoneDSHWire

enum LogTestSupport {
    struct FixtureError: Error, CustomStringConvertible {
        let description: String
    }

    static func root(for test: XCTestCase, name: String = "workspace") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-phone-log-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        test.addTeardownBlock {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        return url
    }

    static func bootID(_ value: UInt8 = 0x11) -> Data {
        Data(repeating: value, count: 16)
    }

    static func configuration(root: URL,
                              segmentRollBytes: Int = WorkspaceLogConfiguration.defaultSegmentRollBytes,
                              walQuotaBytes: Int = WorkspaceLogConfiguration.defaultWALQuotaBytes,
                              journalQuotaBytes: Int = WorkspaceLogConfiguration.defaultJournalQuotaBytes,
                              singleFileLimitBytes: Int = WorkspaceLogConfiguration.defaultSingleFileLimitBytes,
                              groupCommitDelay: TimeInterval = WorkspaceLogConfiguration.defaultGroupCommitDelaySeconds) -> WorkspaceLogConfiguration {
        WorkspaceLogConfiguration(root: root,
                                  walQuotaBytes: walQuotaBytes,
                                  journalQuotaBytes: journalQuotaBytes,
                                  segmentRollBytes: segmentRollBytes,
                                  singleFileLimitBytes: singleFileLimitBytes,
                                  groupCommitDelay: groupCommitDelay)
    }

    static func write(_ path: String, data: String,
                      mode: UInt32 = 0o644) -> VfsMutationBody {
        VfsMutationBody(op: .write, mode: mode, path: path, data: Data(data.utf8))
    }

    static func write(_ path: String, bytes: Data,
                      mode: UInt32 = 0o644) -> VfsMutationBody {
        VfsMutationBody(op: .write, mode: mode, path: path, data: bytes)
    }

    static func append(_ path: String, from: UInt64, data: String,
                       mode: UInt32 = 0o644) -> VfsMutationBody {
        VfsMutationBody(op: .write, mode: mode,
                        mflags: .appended, appendFrom: from,
                        path: path, data: Data(data.utf8))
    }

    static func mkdir(_ path: String, mode: UInt32 = 0o755) -> VfsMutationBody {
        VfsMutationBody(op: .mkdir, mode: mode, path: path)
    }

    static func remove(_ path: String) -> VfsMutationBody {
        VfsMutationBody(op: .remove, mode: 0, path: path)
    }

    static func chmod(_ path: String, mode: UInt32) -> VfsMutationBody {
        VfsMutationBody(op: .chmod, mode: mode, path: path)
    }

    static func walDirectory(_ root: URL) -> URL {
        WorkspacePaths(root: root).walDirectory
    }

    static func records(in root: URL, from mseq: UInt64 = 1) throws -> [WALRecord] {
        try WALReader.records(directory: walDirectory(root), fromMseq: mseq)
    }

    static func segments(in root: URL) throws -> [WALSegmentFile] {
        try WALReader.scan(directory: walDirectory(root)).segments
    }

    static func data(hex: String) throws -> Data {
        let bytes = Array(hex.utf8)
        guard bytes.count % 2 == 0 else {
            throw FixtureError(description: "odd hex length")
        }
        var result = Data(capacity: bytes.count / 2)
        var index = 0
        while index < bytes.count {
            guard let high = nibble(bytes[index]),
                  let low = nibble(bytes[index + 1]) else {
                throw FixtureError(description: "invalid hex")
            }
            result.append(high << 4 | low)
            index += 2
        }
        return result
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func repoRoot() throws -> URL {
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let marker = candidate.appendingPathComponent("spec/v1/golden/wal")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        throw FixtureError(description: "cannot locate the repository root")
    }

    static func goldenWALDirectory() throws -> URL {
        try repoRoot().appendingPathComponent("spec/v1/golden/wal")
    }

    static func loadJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FixtureError(description: "golden file is not a JSON object")
        }
        return object
    }

    static func string(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String else {
            throw FixtureError(description: "missing string \(key)")
        }
        return value
    }

    static func uint64(_ value: Any?, _ key: String) throws -> UInt64 {
        if let number = value as? NSNumber {
            return number.uint64Value
        }
        if let string = value as? String, let parsed = UInt64(string) {
            return parsed
        }
        throw FixtureError(description: "missing integer \(key)")
    }

    static func dictionary(_ object: [String: Any], _ key: String) throws -> [String: Any] {
        guard let value = object[key] as? [String: Any] else {
            throw FixtureError(description: "missing object \(key)")
        }
        return value
    }

    /// A golden WAL segment dropped into a fresh `wal/` directory.
    static func installGoldenSegment(_ name: String, in root: URL) throws -> [String: Any] {
        let fixture = try loadJSON(try goldenWALDirectory().appendingPathComponent(name))
        let file = try data(hex: try string(fixture, "file_hex"))
        let directory = walDirectory(root)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        try file.write(to: directory.appendingPathComponent("00000001.000000.xlwal"))
        return fixture
    }
}

/// A small lock-protected collection for observations made on another thread.
final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    init(_ initial: [Value] = []) {
        storage = initial
    }

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Collects an asynchronous ack stream and lets a test wait for a count.
final class AckCollector<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<Element>) {
        task = Task { [weak self] in
            for await element in stream {
                self?.append(element)
            }
        }
    }

    deinit {
        task?.cancel()
    }

    var values: [Element] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ element: Element) {
        lock.lock()
        storage.append(element)
        lock.unlock()
    }

    func waitForCount(_ count: Int, timeout: TimeInterval = 3) async -> [Element] {
        let deadline = Date().addingValue(timeout)
        while Date() < deadline {
            let snapshot = values
            if snapshot.count >= count {
                return snapshot
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return values
    }
}

private extension Date {
    func addingValue(_ seconds: TimeInterval) -> Date {
        addingTimeInterval(seconds)
    }
}

private func nibble(_ byte: UInt8) -> UInt8? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"):
        return byte - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"):
        return byte - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"):
        return byte - UInt8(ascii: "A") + 10
    default:
        return nil
    }
}
