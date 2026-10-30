// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHEngine: native iPhone Files directory import.
//
// One import at a time: the user picks a directory in the system Files picker,
// the App takes a security-scoped read grant, scans and copies the tree into a
// bounded Caches staging directory, then streams 1 MiB chunks to the Worker's
// existing workspace through the sink protocol. The Worker publishes the final
// tree under `imports/<name>`; this file never writes the materialized
// workspace, creates a session/workspace, or talks to a remote PC.
//
// File enumeration is ours, not `FileManager.enumerator`: hidden entries stay
// in, symbolic links and non-regular files are refused, and path/parent rules
// are checked before any bytes are copied. The source directory is read-only.
//
// NOT_VERIFIED on a real iPhone: the system Files picker, security-scoped book
// marks and the WKWebView message handler are exercised by the host app on a
// Mac/Simulator; this module only defines the native contract.

import Foundation
import WebKit

#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
#endif

/// Caps for one directory import. The Worker service mirrors these defaults.
public struct WebEngineDirectoryImportLimits: Sendable, Equatable {
    /// Maximum regular files in one import.
    public let maxFiles: Int
    /// Maximum child directories (the selected root is not counted).
    public let maxDirectories: Int
    /// Maximum sum of all file sizes: 128 MiB, below the 8 GiB `budgets.md`
    /// workspace row and its 160 MiB single-import VFS budget.
    public let maxTotalBytes: Int
    /// Maximum size of one file: 64 MiB, matching `DEFAULT_SINGLE_FILE_LIMIT`.
    public let maxFileBytes: Int
    /// Bytes per VFS write: 1 MiB, matching `DEFAULT_VFS_FRAME_BYTES`.
    public let chunkBytes: Int
    /// Maximum UTF-8 bytes of one relative path.
    public let maxPathBytes: Int
    /// Maximum UTF-8 bytes of one directory/file name.
    public let maxEntryNameLength: Int

    public init(maxFiles: Int = 500,
                maxDirectories: Int = 2_000,
                maxTotalBytes: Int = 128 * 1024 * 1024,
                maxFileBytes: Int = 64 * 1024 * 1024,
                chunkBytes: Int = 1024 * 1024,
                maxPathBytes: Int = 1024,
                maxEntryNameLength: Int = 128) {
        self.maxFiles = maxFiles
        self.maxDirectories = maxDirectories
        self.maxTotalBytes = maxTotalBytes
        self.maxFileBytes = maxFileBytes
        self.chunkBytes = chunkBytes
        self.maxPathBytes = maxPathBytes
        self.maxEntryNameLength = maxEntryNameLength
    }

    /// The phone defaults shared with `plugins/phone-directory-import/src/types.ts`.
    public static let `default` = WebEngineDirectoryImportLimits()
}

/// One regular file in a staged directory manifest.
public struct WebEngineDirectoryImportFile: Sendable, Equatable {
    /// `/`-separated path relative to the selected directory.
    public let path: String
    /// Byte size copied to staging.
    public let size: Int

    public init(path: String, size: Int) {
        self.path = path
        self.size = size
    }
}

/// The Worker-side description of one staged import.
public struct WebEngineDirectoryImportManifest: Sendable, Equatable {
    public let sessionID: String
    /// Existing workspace directory that receives `imports/<entryName>`.
    public let targetDirectory: String
    /// Final directory name (the selected directory's name).
    public let entryName: String
    /// Relative child directories, including empty ones.
    public let directories: [String]
    public let files: [WebEngineDirectoryImportFile]
    public let totalBytes: Int

    public init(sessionID: String,
                targetDirectory: String,
                entryName: String,
                directories: [String],
                files: [WebEngineDirectoryImportFile],
                totalBytes: Int) {
        self.sessionID = sessionID
        self.targetDirectory = targetDirectory
        self.entryName = entryName
        self.directories = directories
        self.files = files
        self.totalBytes = totalBytes
    }
}

/// Visible phase of one import.
public enum WebEngineDirectoryImportPhase: String, Sendable, Equatable {
    case scanning
    case staging
    case uploading
    case committing
}

/// Progress dispatched to the page and reported by the importer.
public struct WebEngineDirectoryImportProgress: Sendable, Equatable {
    public let phase: WebEngineDirectoryImportPhase
    public let filesDone: Int
    public let filesTotal: Int
    public let bytesDone: Int
    public let bytesTotal: Int
    /// Current relative path, or an empty string between files.
    public let currentPath: String

    public init(phase: WebEngineDirectoryImportPhase,
                filesDone: Int,
                filesTotal: Int,
                bytesDone: Int,
                bytesTotal: Int,
                currentPath: String) {
        self.phase = phase
        self.filesDone = filesDone
        self.filesTotal = filesTotal
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.currentPath = currentPath
    }
}

/// Final result of a committed import.
public struct WebEngineDirectoryImportResult: Sendable, Equatable {
    /// Path relative to the session workspace root, for example `imports/notes`.
    public let workspacePath: String
    /// Absolute path in the Worker VFS.
    public let absolutePath: String
    public let fileCount: Int
    public let totalBytes: Int

    public init(workspacePath: String, absolutePath: String, fileCount: Int, totalBytes: Int) {
        self.workspacePath = workspacePath
        self.absolutePath = absolutePath
        self.fileCount = fileCount
        self.totalBytes = totalBytes
    }
}

/// A typed failure the page can display; no import is reported as successful.
public enum WebEngineDirectoryImportError: Error, Equatable, Sendable {
    case cancelled
    case securityScopeDenied
    case notAFolder
    case symlink(String)
    case notRegularFile(String)
    case limit(String)
    case unsafePath(String)
    case copyFailed(String)
    case busy
    case sinkFailed(String)
    case presenterUnavailable
    case invalidMessage(String)
    case internalFailure(String)

    /// Stable code in the page's failure event.
    public var code: String {
        switch self {
        case .cancelled: return "cancelled"
        case .securityScopeDenied: return "security-scope-denied"
        case .notAFolder: return "not-a-folder"
        case .symlink: return "symlink"
        case .notRegularFile: return "not-regular-file"
        case .limit: return "limit-exceeded"
        case .unsafePath: return "unsafe-path"
        case .copyFailed: return "copy-failed"
        case .busy: return "busy"
        case .sinkFailed: return "sink-failed"
        case .presenterUnavailable: return "presenter-unavailable"
        case .invalidMessage: return "invalid-message"
        case .internalFailure: return "internal"
        }
    }
}

extension WebEngineDirectoryImportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cancelled: return "The import was cancelled."
        case .securityScopeDenied: return "The selected folder did not grant read access."
        case .notAFolder: return "The selected item is not a folder."
        case .symlink(let path): return "Symbolic links are not imported: \(path)"
        case .notRegularFile(let path): return "The entry is not a regular file: \(path)"
        case .limit(let reason): return "The folder exceeds the import limit: \(reason)"
        case .unsafePath(let path): return "The folder contains an unsafe path: \(path)"
        case .copyFailed(let reason): return "Copying the folder failed: \(reason)"
        case .busy: return "Another folder import is already running."
        case .sinkFailed(let reason): return "Writing the import to the workspace failed: \(reason)"
        case .presenterUnavailable: return "The system folder picker is unavailable."
        case .invalidMessage(let reason): return "The import request is invalid: \(reason)"
        case .internalFailure(let reason): return "The import failed: \(reason)"
        }
    }
}

/// A fully copied directory in the Caches staging area.
public struct StagedDirectory: Sendable {
    public let root: URL
    public let entryName: String
    /// Relative child directories, including empty ones.
    public let directories: [String]
    public let files: [WebEngineDirectoryImportFile]
    public let totalBytes: Int

    init(root: URL, entryName: String, directories: [String],
         files: [WebEngineDirectoryImportFile], totalBytes: Int) {
        self.root = root
        self.entryName = entryName
        self.directories = directories
        self.files = files
        self.totalBytes = totalBytes
    }

    /// Remove this import's Caches staging tree. Never touches the source.
    public func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// Copy the selected directory into a bounded Caches staging tree.
///
/// The call is synchronous by design so the caller can run it on a background
/// task; `WebEngineDirectoryImport` does exactly that. Every read is bounded by
/// `min(limits.chunkBytes, 1 MiB)`, and the source is only ever read.
public enum WebEngineDirectoryImporter {
    /// Scan `source` and copy its regular files into a fresh directory under
    /// `stagingRoot`. Empty directories are preserved.
    ///
    /// - Parameters:
    ///   - source: directory URL already covered by a security-scoped grant.
    ///   - stagingRoot: Caches parent; a fresh UUID child is created.
    ///   - limits: deployment caps; defaults mirror the Worker service.
    ///   - fileManager: injectable for tests; defaults to `.default`.
    ///   - isCancelled: cooperative cancellation, polled between entries and
    ///     between chunks.
    ///   - progress: called on the calling (background) thread.
    /// - Returns: the staged tree. The caller removes it after commit/failure.
    public static func stageDirectory(
        source: URL,
        stagingRoot: URL,
        limits: WebEngineDirectoryImportLimits = .default,
        fileManager: FileManager = .default,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        progress: @escaping @Sendable (WebEngineDirectoryImportProgress) -> Void = { _ in }
    ) throws -> StagedDirectory {
        let source = source.standardizedFileURL
        let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values?.isSymbolicLink == true { throw WebEngineDirectoryImportError.symlink(source.lastPathComponent) }
        guard values?.isDirectory == true else { throw WebEngineDirectoryImportError.notAFolder }
        let entryName = source.lastPathComponent
        try WebEngineDirectoryImportPath.validateEntryName(entryName, limits: limits)

        do {
            try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        } catch {
            throw WebEngineDirectoryImportError.copyFailed("could not create the staging root: \(error.localizedDescription)")
        }
        let root = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        } catch {
            throw WebEngineDirectoryImportError.copyFailed("could not create the staging directory: \(error.localizedDescription)")
        }

        do {
            progress(WebEngineDirectoryImportProgress(
                phase: .scanning, filesDone: 0, filesTotal: 0,
                bytesDone: 0, bytesTotal: 0, currentPath: ""))
            var directories: [String] = []
            var files: [SourceFile] = []
            var totalBytes = 0
            try scan(directory: source, relative: "", limits: limits, fileManager: fileManager,
                     isCancelled: isCancelled, directories: &directories, files: &files,
                     totalBytes: &totalBytes)
            if isCancelled() { throw WebEngineDirectoryImportError.cancelled }
            progress(WebEngineDirectoryImportProgress(
                phase: .scanning, filesDone: 0, filesTotal: files.count,
                bytesDone: 0, bytesTotal: totalBytes, currentPath: ""))

            for directory in directories {
                let target = root.appendingPathComponent(directory, isDirectory: true)
                do {
                    try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                } catch {
                    throw WebEngineDirectoryImportError.copyFailed("could not create \(directory): \(error.localizedDescription)")
                }
            }

            var bytesDone = 0
            for (index, file) in files.enumerated() {
                if isCancelled() { throw WebEngineDirectoryImportError.cancelled }
                let destination = root.appendingPathComponent(file.path)
                let copied = try copyFile(
                    from: file.url, to: destination, limits: limits,
                    isCancelled: isCancelled,
                    didRead: { _ in },
                    fileManager: fileManager)
                guard copied == file.size else {
                    throw WebEngineDirectoryImportError.copyFailed("\(file.path) changed size while copying")
                }
                bytesDone += copied
                progress(WebEngineDirectoryImportProgress(
                    phase: .staging, filesDone: index + 1, filesTotal: files.count,
                    bytesDone: bytesDone, bytesTotal: totalBytes, currentPath: file.path))
            }
            if isCancelled() { throw WebEngineDirectoryImportError.cancelled }
            let manifestFiles = files.map { WebEngineDirectoryImportFile(path: $0.path, size: $0.size) }
            return StagedDirectory(root: root, entryName: entryName, directories: directories,
                                   files: manifestFiles, totalBytes: totalBytes)
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
    }

    // MARK: - Scanning

    private struct SourceFile {
        let url: URL
        let path: String
        let size: Int
    }

    private static func scan(
        directory: URL,
        relative: String,
        limits: WebEngineDirectoryImportLimits,
        fileManager: FileManager,
        isCancelled: () -> Bool,
        directories: inout [String],
        files: inout [SourceFile],
        totalBytes: inout Int
    ) throws {
        if isCancelled() { throw WebEngineDirectoryImportError.cancelled }
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [])
        } catch {
            throw WebEngineDirectoryImportError.copyFailed(
                "could not read \(relative.isEmpty ? "." : relative): \(error.localizedDescription)")
        }
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if isCancelled() { throw WebEngineDirectoryImportError.cancelled }
            let name = child.lastPathComponent
            try WebEngineDirectoryImportPath.validateEntryName(name, limits: limits)
            let path = relative.isEmpty ? name : "\(relative)/\(name)"
            try WebEngineDirectoryImportPath.validateRelative(path, limits: limits)
            let values = try? child.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values?.isSymbolicLink == true { throw WebEngineDirectoryImportError.symlink(path) }
            if values?.isDirectory == true {
                directories.append(path)
                if directories.count > limits.maxDirectories {
                    throw WebEngineDirectoryImportError.limit("more than \(limits.maxDirectories) directories")
                }
                try scan(directory: child, relative: path, limits: limits, fileManager: fileManager,
                         isCancelled: isCancelled, directories: &directories, files: &files,
                         totalBytes: &totalBytes)
                continue
            }
            guard values?.isRegularFile == true else {
                throw WebEngineDirectoryImportError.notRegularFile(path)
            }
            let size = values?.fileSize ?? 0
            guard size >= 0 else { throw WebEngineDirectoryImportError.copyFailed("\(path) has no readable size") }
            if size > limits.maxFileBytes {
                throw WebEngineDirectoryImportError.limit("\(path) exceeds \(limits.maxFileBytes) bytes")
            }
            totalBytes += size
            if totalBytes > limits.maxTotalBytes {
                throw WebEngineDirectoryImportError.limit("the folder exceeds \(limits.maxTotalBytes) bytes")
            }
            files.append(SourceFile(url: child, path: path, size: size))
            if files.count > limits.maxFiles {
                throw WebEngineDirectoryImportError.limit("more than \(limits.maxFiles) files")
            }
        }
    }

    // MARK: - Copying

    /// Copy one file with bounded reads. Internal so the native tests can prove
    /// every read is at most 1 MiB and the concatenation is byte-identical.
    static func copyFile(
        from source: URL,
        to destination: URL,
        limits: WebEngineDirectoryImportLimits,
        isCancelled: () -> Bool,
        didRead: (Int) -> Void,
        fileManager: FileManager = .default
    ) throws -> Int {
        let parent = destination.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw WebEngineDirectoryImportError.copyFailed("could not create \(parent.path): \(error.localizedDescription)")
        }
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw WebEngineDirectoryImportError.copyFailed("could not create \(destination.path)")
        }
        let input: FileHandle
        do {
            input = try FileHandle(forReadingFrom: source)
        } catch {
            throw WebEngineDirectoryImportError.copyFailed("could not open \(source.path): \(error.localizedDescription)")
        }
        defer { try? input.close() }
        let output: FileHandle
        do {
            output = try FileHandle(forWritingTo: destination)
        } catch {
            throw WebEngineDirectoryImportError.copyFailed("could not write \(destination.path): \(error.localizedDescription)")
        }
        defer { try? output.close() }

        let chunk = max(1, min(limits.chunkBytes, 1 << 20))
        var copied = 0
        while true {
            if isCancelled() { throw WebEngineDirectoryImportError.cancelled }
            let data: Data?
            do {
                data = try input.read(upToCount: chunk)
            } catch {
                throw WebEngineDirectoryImportError.copyFailed("reading \(source.path) failed: \(error.localizedDescription)")
            }
            guard let data, !data.isEmpty else { break }
            if copied + data.count > limits.maxFileBytes {
                throw WebEngineDirectoryImportError.limit("a file grew beyond \(limits.maxFileBytes) bytes while copying")
            }
            do {
                try output.write(contentsOf: data)
            } catch {
                throw WebEngineDirectoryImportError.copyFailed("writing \(destination.path) failed: \(error.localizedDescription)")
            }
            copied += data.count
            didRead(data.count)
        }
        return copied
    }
}

/// Path rules shared by scanning and the tests.
enum WebEngineDirectoryImportPath {
    static func validateEntryName(_ name: String, limits: WebEngineDirectoryImportLimits) throws {
        if name.isEmpty || name == "." || name == ".." || name.contains("/") || name.contains("\0") {
            throw WebEngineDirectoryImportError.unsafePath(name)
        }
        if name.utf8.count > limits.maxEntryNameLength {
            throw WebEngineDirectoryImportError.limit("a name exceeds \(limits.maxEntryNameLength) bytes")
        }
    }

    static func validateRelative(_ path: String, limits: WebEngineDirectoryImportLimits) throws {
        if path.isEmpty || path.contains("\0") || path.hasPrefix("/") {
            throw WebEngineDirectoryImportError.unsafePath(path)
        }
        if path.utf8.count > limits.maxPathBytes {
            throw WebEngineDirectoryImportError.limit("a path exceeds \(limits.maxPathBytes) bytes")
        }
        for segment in path.split(separator: "/", omittingEmptySubsequences: false) {
            if segment.isEmpty || segment == "." || segment == ".." {
                throw WebEngineDirectoryImportError.unsafePath(path)
            }
        }
    }
}

/// The Worker bridge used by ``WebEngineDirectoryImport``.
public protocol WebEngineDirectoryImportSink: Sendable {
    /// Start a Worker-side import; returns its import id.
    func begin(_ manifest: WebEngineDirectoryImportManifest) async throws -> String
    /// Append one chunk at `offset`.
    func write(importID: String, path: String, offset: Int, data: Data) async throws
    /// Publish the staged tree and return the observed final paths.
    func commit(importID: String) async throws -> WebEngineDirectoryImportResult
    /// Discard only this import's Worker staging.
    func abort(importID: String) async
}

/// Injectable system folder picker; production uses the UIKit Files sheet.
@WebEngineUIActor
public protocol WebEngineDirectoryImportPresenting: AnyObject {
    /// Present the picker and call `completion` exactly once.
    func present(completion: @escaping (Result<URL, WebEngineDirectoryImportError>) -> Void)
}

/// Coordinates one exclusive import from a WKWebView page.
@WebEngineUIActor
public final class WebEngineDirectoryImport {
    /// Page-to-native script-message handler name.
    public static let messageHandlerName = "pdshDirectoryImport"
    /// Native-to-page `CustomEvent` name.
    public static let eventName = "pdsh-directory-import"

    // Weak: WKUserContentController strongly retains the script handler, which
    // retains this coordinator. A strong back-reference would keep the whole
    // WebView/engine alive after the host removes every other owner.
    private weak var webView: WKWebView?
    private let sink: any WebEngineDirectoryImportSink
    private let limits: WebEngineDirectoryImportLimits
    private let fileManager: FileManager
    private let stagingRoot: URL
    private let presenter: (any WebEngineDirectoryImportPresenting)?

    private var currentTask: Task<Void, Never>?
    private var currentID: String?
    private var cancellation: DirectoryImportCancellation?

    /// - Parameters:
    ///   - webView: the page that receives `pdsh-directory-import` events.
    ///   - sink: the Worker wire adapter.
    ///   - limits: deployment caps; defaults match the Worker service.
    ///   - fileManager: injectable for tests.
    ///   - stagingRoot: Caches parent; defaults to `Caches/PhoneDSHImport`.
    ///   - presenter: injectable picker; the UIKit Files sheet by default.
    public init(webView: WKWebView,
                sink: any WebEngineDirectoryImportSink,
                limits: WebEngineDirectoryImportLimits = .default,
                fileManager: FileManager = .default,
                stagingRoot: URL? = nil,
                presenter: (any WebEngineDirectoryImportPresenting)? = nil) {
        self.webView = webView
        self.sink = sink
        self.limits = limits
        self.fileManager = fileManager
        self.stagingRoot = stagingRoot ?? Self.defaultStagingRoot(fileManager: fileManager)
        #if canImport(UIKit)
        self.presenter = presenter ?? WebEngineDirectoryImportDocumentPicker(webView: webView)
        #else
        self.presenter = presenter
        #endif
    }

    /// Start one import. A second start while one is active publishes `busy`.
    public func start(id: String, sessionID: String, targetDirectory: String) {
        guard currentTask == nil else {
            publishResultFailure(id: id, error: .busy)
            return
        }
        guard !id.isEmpty, !sessionID.isEmpty, targetDirectory.hasPrefix("/"), !targetDirectory.contains("\0") else {
            publishResultFailure(id: id, error: .invalidMessage("id, sessionId and an absolute targetDirectory are required"))
            return
        }
        guard let presenter = self.presenter else {
            publishResultFailure(id: id, error: .presenterUnavailable)
            return
        }
        let cancellation = DirectoryImportCancellation()
        self.cancellation = cancellation
        currentID = id
        currentTask = Task { [weak self] in
            await self?.run(id: id, sessionID: sessionID, targetDirectory: targetDirectory,
                            presenter: presenter, cancellation: cancellation)
        }
    }

    /// Cooperatively cancel the import with this id.
    ///
    /// Cancellation stops the import only before the point of no return. Once
    /// the upload has finished and `commit` has begun, the Worker is publishing
    /// an atomic final directory, so a late cancel is ignored and the import
    /// reports the real commit result instead of a cancellation that cannot be
    /// rolled back.
    public func cancel(id: String) {
        guard id == currentID, let cancellation else { return }
        guard cancellation.cancel() else { return }
        currentTask?.cancel()
    }

    // MARK: - Import

    private func run(id: String,
                     sessionID: String,
                     targetDirectory: String,
                     presenter: any WebEngineDirectoryImportPresenting,
                     cancellation: DirectoryImportCancellation) async {
        var staged: StagedDirectory?
        var importID: String?
        // Once `beginCommit()` wins, the Worker owns an atomic publish. A
        // failed commit must not race it with `abort`: the Worker's commit
        // rolls its own final/staging tree back, while an abort could delete
        // the staging it is still verifying or the directory it just renamed.
        var commitStarted = false
        defer {
            if currentID == id {
                currentID = nil
                currentTask = nil
                self.cancellation = nil
            }
        }
        do {
            let source = try await chooseDirectory(presenter)
            if cancellation.isCancelled { throw WebEngineDirectoryImportError.cancelled }
            let scoped = source.startAccessingSecurityScopedResource()
            guard scoped else { throw WebEngineDirectoryImportError.securityScopeDenied }
            defer { source.stopAccessingSecurityScopedResource() }
            try validateSource(source)
            publishProgress(WebEngineDirectoryImportProgress(
                phase: .scanning, filesDone: 0, filesTotal: 0,
                bytesDone: 0, bytesTotal: 0, currentPath: ""), id: id)

            let limits = self.limits
            let stagingRoot = self.stagingRoot
            let stageProgress = StageProgressGate()
            let relay: @Sendable (WebEngineDirectoryImportProgress) -> Void = { [weak self] progress in
                Task { @WebEngineUIActor [weak self] in
                    guard stageProgress.isOpen else { return }
                    self?.publishProgress(progress, id: id)
                }
            }
            let sourceURL = source
            staged = try await Task.detached(priority: .utility) {
                try WebEngineDirectoryImporter.stageDirectory(
                    source: sourceURL,
                    stagingRoot: stagingRoot,
                    limits: limits,
                    isCancelled: { cancellation.isCancelled },
                    progress: relay)
            }.value
            stageProgress.close()
            await Task.yield()
            if cancellation.isCancelled { throw WebEngineDirectoryImportError.cancelled }
            guard let stagedDirectory = staged else {
                throw WebEngineDirectoryImportError.internalFailure("staging produced no directory")
            }
            publishProgress(WebEngineDirectoryImportProgress(
                phase: .staging, filesDone: stagedDirectory.files.count, filesTotal: stagedDirectory.files.count,
                bytesDone: stagedDirectory.totalBytes, bytesTotal: stagedDirectory.totalBytes, currentPath: ""), id: id)

            let manifest = WebEngineDirectoryImportManifest(
                sessionID: sessionID,
                targetDirectory: targetDirectory,
                entryName: stagedDirectory.entryName,
                directories: stagedDirectory.directories,
                files: stagedDirectory.files,
                totalBytes: stagedDirectory.totalBytes)
            let workerImportID: String
            do {
                workerImportID = try await sink.begin(manifest)
            } catch {
                throw WebEngineDirectoryImportError.sinkFailed(error.localizedDescription)
            }
            guard !workerImportID.isEmpty else {
                throw WebEngineDirectoryImportError.sinkFailed("begin returned no import id")
            }
            importID = workerImportID
            if cancellation.isCancelled { throw WebEngineDirectoryImportError.cancelled }

            let chunk = max(1, min(limits.chunkBytes, 1 << 20))
            var bytesDone = 0
            var filesDone = 0
            for file in stagedDirectory.files {
                if cancellation.isCancelled { throw WebEngineDirectoryImportError.cancelled }
                let url = stagedDirectory.root.appendingPathComponent(file.path)
                let handle: FileHandle
                do {
                    handle = try FileHandle(forReadingFrom: url)
                } catch {
                    throw WebEngineDirectoryImportError.copyFailed(
                        "could not open staged \(file.path): \(error.localizedDescription)")
                }
                defer { try? handle.close() }
                var offset = 0
                while true {
                    if cancellation.isCancelled { throw WebEngineDirectoryImportError.cancelled }
                    let data: Data?
                    do {
                        data = try handle.read(upToCount: chunk)
                    } catch {
                        throw WebEngineDirectoryImportError.copyFailed(
                            "reading staged \(file.path) failed: \(error.localizedDescription)")
                    }
                    guard let data, !data.isEmpty else { break }
                    do {
                        try await sink.write(importID: workerImportID, path: file.path, offset: offset, data: data)
                    } catch {
                        throw WebEngineDirectoryImportError.sinkFailed(error.localizedDescription)
                    }
                    offset += data.count
                    bytesDone += data.count
                    publishProgress(WebEngineDirectoryImportProgress(
                        phase: .uploading, filesDone: filesDone, filesTotal: stagedDirectory.files.count,
                        bytesDone: bytesDone, bytesTotal: stagedDirectory.totalBytes, currentPath: file.path), id: id)
                }
                guard offset == file.size else {
                    throw WebEngineDirectoryImportError.copyFailed(
                        "staged \(file.path) is \(offset) bytes, expected \(file.size)")
                }
                filesDone += 1
            }

            // The upload loop's last check can be a whole 1 MiB chunk behind a
            // cancel that arrived after the final write. Check once more, then
            // atomically seal cancellation before announcing `committing`: from
            // this point on `sink.commit` owns the atomic publish and a late
            // cancel must neither cancel the task nor be reported as cancelled.
            if cancellation.isCancelled { throw WebEngineDirectoryImportError.cancelled }
            guard cancellation.beginCommit() else { throw WebEngineDirectoryImportError.cancelled }
            commitStarted = true
            publishProgress(WebEngineDirectoryImportProgress(
                phase: .committing, filesDone: filesDone, filesTotal: stagedDirectory.files.count,
                bytesDone: stagedDirectory.totalBytes, bytesTotal: stagedDirectory.totalBytes, currentPath: ""), id: id)
            let result: WebEngineDirectoryImportResult
            do {
                result = try await sink.commit(importID: workerImportID)
            } catch {
                throw WebEngineDirectoryImportError.sinkFailed(error.localizedDescription)
            }
            stagedDirectory.remove()
            staged = nil
            publishResultSuccess(result, id: id)
        } catch {
            // After the point of no return the Worker commit is the only owner
            // of the staging/final tree. It either publishes the real result
            // (the ordered channel retries a lost response) or rolls its own
            // directory back; an abort here could delete the tree mid-commit
            // and make a published import look like a failure.
            if let importID, !commitStarted {
                await sink.abort(importID: importID)
            }
            staged?.remove()
            let reported: WebEngineDirectoryImportError
            if let typed = error as? WebEngineDirectoryImportError {
                reported = typed
            } else if commitStarted && (error is CancellationError || cancellation.isCancelled) {
                // A commit is never reported as cancelled once it started.
                reported = .sinkFailed("the import commit was interrupted")
            } else if error is CancellationError || cancellation.isCancelled {
                reported = .cancelled
            } else {
                reported = .internalFailure(error.localizedDescription)
            }
            publishResultFailure(id: id, error: reported)
        }
    }

    private func chooseDirectory(_ presenter: any WebEngineDirectoryImportPresenting) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            presenter.present { result in
                switch result {
                case .success(let url): continuation.resume(returning: url)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }

    private func validateSource(_ url: URL) throws {
        guard url.isFileURL else { throw WebEngineDirectoryImportError.notAFolder }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values?.isSymbolicLink == true { throw WebEngineDirectoryImportError.symlink(url.lastPathComponent) }
        guard values?.isDirectory == true else { throw WebEngineDirectoryImportError.notAFolder }
    }

    private static func defaultStagingRoot(fileManager: FileManager) -> URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return caches.appendingPathComponent("PhoneDSHImport", isDirectory: true)
    }

    // MARK: - Page events

    private func publishProgress(_ progress: WebEngineDirectoryImportProgress, id: String) {
        publish([
            "v": 1,
            "id": id,
            "type": "progress",
            "phase": progress.phase.rawValue,
            "filesDone": progress.filesDone,
            "filesTotal": progress.filesTotal,
            "bytesDone": progress.bytesDone,
            "bytesTotal": progress.bytesTotal,
            "currentPath": progress.currentPath,
        ])
    }

    private func publishResultSuccess(_ result: WebEngineDirectoryImportResult, id: String) {
        publish([
            "v": 1,
            "id": id,
            "type": "result",
            "ok": true,
            "workspacePath": result.workspacePath,
            "absolutePath": result.absolutePath,
            "fileCount": result.fileCount,
            "totalBytes": result.totalBytes,
        ])
    }

    private func publishResultFailure(id: String, error: WebEngineDirectoryImportError) {
        publish([
            "v": 1,
            "id": id,
            "type": "result",
            "ok": false,
            "code": error.code,
            "message": error.localizedDescription,
        ])
    }

    private func publish(_ detail: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(detail),
              let data = try? JSONSerialization.data(withJSONObject: detail, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        // The only text interpolated into JS is JSONSerialization output and a
        // compile-time event name; file names stay data.
        let script = "window.dispatchEvent(new CustomEvent('\(Self.eventName)', { detail: \(json) }));"
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }
}

/// Drops queued staging-progress events once staging has finished, so no late
/// event can move the page backwards after the upload phase begins.
private final class StageProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return open
    }

    func close() {
        lock.lock()
        open = false
        lock.unlock()
    }
}

/// Thread-safe cooperative cancellation shared with the detached staging task.
///
/// The state transition is the import's point of no return: `beginCommit()`
/// either wins and makes every later `cancel()` a no-op, or loses to a cancel
/// and refuses to commit. There is no window where both a cancel is accepted
/// and a commit is started.
private final class DirectoryImportCancellation: @unchecked Sendable {
    private enum Phase {
        case running
        case committing
        case cancelled
    }

    private let lock = NSLock()
    private var phase: Phase = .running

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return phase == .cancelled
    }

    /// Accepts cancellation only while the import is still running. Returns
    /// `false` once the atomic commit has started.
    @discardableResult
    func cancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .running else { return false }
        phase = .cancelled
        return true
    }

    /// Seals cancellation and enters the commit phase. Returns `false` when a
    /// cancel already won (the caller must abort instead of committing).
    func beginCommit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .running else { return false }
        phase = .committing
        return true
    }
}

/// Parse page messages and forward them to one importer. The host registers it
/// with `WKUserContentController` using
/// ``WebEngineDirectoryImport/messageHandlerName``; this class never registers
/// itself.
@WebEngineUIActor
public final class WebEngineDirectoryImportScriptHandler: NSObject, WKScriptMessageHandlerWithReply {
    private let importer: WebEngineDirectoryImport

    public init(importer: WebEngineDirectoryImport) {
        self.importer = importer
        super.init()
    }

    public func userContentController(_ userContentController: WKUserContentController,
                                      didReceive message: WKScriptMessage,
                                      replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any] else {
            replyHandler(nil, "directory import message must be an object")
            return
        }
        guard (body["v"] as? NSNumber)?.intValue == 1 else {
            replyHandler(nil, "directory import message v must be 1")
            return
        }
        guard let id = body["id"] as? String, !id.isEmpty else {
            replyHandler(nil, "directory import message id must be a non-empty string")
            return
        }
        switch body["action"] as? String {
        case "pick":
            guard let sessionID = body["sessionId"] as? String, !sessionID.isEmpty,
                  let targetDirectory = body["targetDirectory"] as? String, targetDirectory.hasPrefix("/") else {
                replyHandler(nil, "pick requires sessionId and an absolute targetDirectory")
                return
            }
            let importer = self.importer
            Task { @WebEngineUIActor in
                importer.start(id: id, sessionID: sessionID, targetDirectory: targetDirectory)
            }
            replyHandler(["ok": true], nil)
        case "cancel":
            let importer = self.importer
            Task { @WebEngineUIActor in importer.cancel(id: id) }
            replyHandler(["ok": true], nil)
        default:
            replyHandler(nil, "directory import action must be pick or cancel")
        }
    }
}

#if canImport(UIKit)
/// The system `UIDocumentPickerViewController` folder sheet. It is the only
/// UI this module presents; no Safari toolbar or app-specific chrome exists.
@WebEngineUIActor
public final class WebEngineDirectoryImportDocumentPicker: NSObject,
    WebEngineDirectoryImportPresenting, UIDocumentPickerDelegate {
    private weak var webView: WKWebView?
    private var pending: ((Result<URL, WebEngineDirectoryImportError>) -> Void)?

    public init(webView: WKWebView) {
        self.webView = webView
        super.init()
    }

    public func present(completion: @escaping (Result<URL, WebEngineDirectoryImportError>) -> Void) {
        guard pending == nil else {
            completion(.failure(.busy))
            return
        }
        guard let host = Self.topViewController(webView?.window?.rootViewController) else {
            completion(.failure(.presenterUnavailable))
            return
        }
        pending = completion
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        picker.modalPresentationStyle = .formSheet
        host.present(picker, animated: true)
    }

    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else {
            finish(.failure(.notAFolder))
            return
        }
        finish(.success(url))
    }

    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish(.failure(.cancelled))
    }

    private func finish(_ result: Result<URL, WebEngineDirectoryImportError>) {
        guard let pending = self.pending else { return }
        self.pending = nil
        pending(result)
    }

    private static func topViewController(_ controller: UIViewController?) -> UIViewController? {
        guard let controller else { return nil }
        if let presented = controller.presentedViewController {
            return topViewController(presented)
        }
        if let navigation = controller as? UINavigationController {
            return topViewController(navigation.visibleViewController) ?? navigation
        }
        if let tabs = controller as? UITabBarController {
            return topViewController(tabs.selectedViewController) ?? tabs
        }
        return controller
    }
}
#endif
