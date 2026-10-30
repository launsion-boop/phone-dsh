// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import UniformTypeIdentifiers

public actor OfficeArtifactStore {
    public static let shared = OfficeArtifactStore()

    private let root: URL
    private let indexURL: URL
    private var refs: [String: OfficeArtifactRef] = [:]
    private var loaded = false

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask)[0]
            var root = support.appendingPathComponent("OfficeArtifacts", isDirectory: true)
            #if DEBUG
            if let raw = ProcessInfo.processInfo.environment["PDSH_OFFICE_ARTIFACT_NAMESPACE"], !raw.isEmpty {
                let namespace = String(raw.unicodeScalars.filter {
                    CharacterSet.alphanumerics.contains($0) || $0 == "-"
                }.prefix(96))
                if !namespace.isEmpty { root.appendPathComponent(namespace, isDirectory: true) }
            }
            #endif
            self.root = root
        }
        self.indexURL = self.root.appendingPathComponent("index.json")
    }

    public func list(cursor: Int = 0, limit: Int = 20) throws -> OfficeArtifactPage {
        try ensureLoaded()
        guard cursor >= 0, limit > 0, limit <= OfficeLimits.maximumPageItems else {
            throw OfficeToolError.invalidArguments("cursor/limit 超出范围")
        }
        let ordered = refs.values.sorted { $0.artifactID < $1.artifactID }
        let end = min(cursor + limit, ordered.count)
        let items = cursor < ordered.count ? Array(ordered[cursor..<end]) : []
        return OfficeArtifactPage(items: items,
                                  nextCursor: end < ordered.count ? end : nil,
                                  total: ordered.count)
    }

    public func metadata(for artifactID: String) throws -> OfficeArtifactRef {
        try ensureLoaded()
        guard let ref = refs[artifactID] else { throw OfficeToolError.unknownArtifact(artifactID) }
        return ref
    }

    public func importFile(at sourceURL: URL) throws -> OfficeArtifactRef {
        try ensureLoaded()
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw OfficeToolError.unavailable("输入不是普通文件")
        }
        let attributes = try manager.attributesOfItem(atPath: sourceURL.path)
        guard let size = attributes[.size] as? Int, size <= OfficeLimits.maximumImportBytes else {
            throw OfficeToolError.unsupported("文件超过 512 MiB 导入上限")
        }
        let artifactID = "art_\(UUID().uuidString)"
        let directory = root.appendingPathComponent(artifactID, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(Self.safeName(sourceURL.lastPathComponent))
        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = size
        do {
            guard manager.createFile(atPath: destination.path, contents: nil) else {
                throw OfficeToolError.unavailable("无法创建 Artifact 文件")
            }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            while remaining > 0 {
                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: min(OfficeLimits.copyChunkBytes, remaining)) ?? Data()
                guard !chunk.isEmpty else { throw OfficeToolError.unavailable("文件读取提前结束") }
                hasher.update(data: chunk)
                try output.write(contentsOf: chunk)
                remaining -= chunk.count
            }
            try output.synchronize()
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
        let ref = OfficeArtifactRef(
            artifactID: artifactID,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            mediaType: Self.mediaType(for: sourceURL),
            byteCount: size,
            name: destination.lastPathComponent)
        refs[artifactID] = ref
        do {
            try saveIndex()
        } catch {
            refs[artifactID] = nil
            try? manager.removeItem(at: directory)
            throw error
        }
        return ref
    }

    public func read(_ artifactID: String, range: Range<Int>) throws -> Data {
        let ref = try metadata(for: artifactID)
        guard range.lowerBound >= 0, range.upperBound >= range.lowerBound,
              range.upperBound <= ref.byteCount else {
            throw OfficeToolError.invalidRange("0..<\(ref.byteCount)")
        }
        let handle = try FileHandle(forReadingFrom: try fileURL(for: artifactID))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.lowerBound))
        return try handle.read(upToCount: range.count) ?? Data()
    }

    public func fileURL(for artifactID: String) throws -> URL {
        let ref = try metadata(for: artifactID)
        let directory = root.appendingPathComponent(ref.artifactID, isDirectory: true)
        let url = directory.appendingPathComponent(ref.name)
        let resolvedRoot = directory.resolvingSymlinksInPath().standardizedFileURL
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(resolvedRoot.path + "/") else {
            throw OfficeToolError.unavailable("Artifact 路径越界")
        }
        return url
    }

    private func ensureLoaded() throws {
        guard !loaded else { return }
        loaded = true
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        guard manager.fileExists(atPath: indexURL.path) else { return }
        let data = try Data(contentsOf: indexURL)
        let decoded = try JSONDecoder().decode([OfficeArtifactRef].self, from: data)
        refs = Dictionary(uniqueKeysWithValues: decoded.map { ($0.artifactID, $0) })
    }

    private func saveIndex() throws {
        let data = try JSONEncoder().encode(refs.values.sorted { $0.artifactID < $1.artifactID })
        try data.write(to: indexURL, options: .atomic)
    }

    private static func safeName(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.map { scalar -> Character in
            if scalar.value < 32 || scalar.value == 127 || scalar == "/" || scalar == "\\" || scalar == ":" {
                return "_"
            }
            return Character(scalar)
        }
        let name = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "." || name == ".." ? "artifact.bin" : String(name.prefix(180))
    }

    private static func mediaType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}
