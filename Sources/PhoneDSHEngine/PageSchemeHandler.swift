// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHEngine: the `pdsh-page:` scheme for PAGE
// previews (spec-render-media-v1 §B).
//
// The preview used to load HTML with `loadHTMLString(baseURL: about:blank)`,
// which has no origin: relative scripts, `fetch()` and WebGL asset loads all
// fail. A PAGE surface instead gives the page a real origin, served by this
// `WKURLSchemeHandler`:
//
//   pdsh-page://<sessionID>/<relative-path>   the session's workspace (read-only)
//   pdsh-page://lib/<relative-path>           the app's bundled Web3DLib (read-only)
//
// Contract:
// - Only GET (with an optional single `Range`) is served; writes, HEAD bodies,
//   proxying and the host bridge are absent by construction: this handler
//   never touches the network or any script message channel.
// - Each URL segment is validated on its own: the `..` / `.` / backslash
//   components are rejected before any file access, and the resolved file is
//   re-checked with `resolvingSymlinksInPath` against its root, so a symlink
//   cannot escape the workspace or the library. `lib` is reserved.
// - HTML responses carry a host-injected `Content-Security-Policy` header.
//   The page declares its tier with
//   `<meta name="pdsh-csp" content="sandbox|local|online">`; the header is
//   built here, never taken from the page, so a page cannot widen its own
//   policy beyond the declared tier.
// - Unknown extensions use `application/octet-stream`.

import Foundation
import WebKit

/// The CSP tier a page declares (spec-render-media-v1 §B.4).
public enum PDSHCSPSandboxTier: String, CaseIterable, Sendable {
    case sandbox
    case local
    case online
}

/// A file resolved from a `pdsh-page:` URL.
public struct PDSHPageFile: Equatable, Sendable {
    public let url: URL
    public let isHTML: Bool

    public init(url: URL, isHTML: Bool) {
        self.url = url
        self.isHTML = isHTML
    }
}

/// Resolution and validation of `pdsh-page:` URLs. Pure and testable; the
/// `WKURLSchemeHandler` adapter only reads the file and answers the task.
public struct PDSHPageResolver: Sendable {
    /// The app's bundled Web3DLib directory (`pdsh-page://lib/...`).
    public let libraryRoot: URL
    /// Session id → the session's materialized workspace directory.
    public let workspaceRoot: @Sendable (String) -> URL?

    public init(libraryRoot: URL,
                workspaceRoot: @escaping @Sendable (String) -> URL?) {
        self.libraryRoot = libraryRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.workspaceRoot = workspaceRoot
    }

    /// Resolves `pdsh-page://<host>/<path>` to a validated file.
    ///
    /// - Throws: ``PDSHPageResolutionError``.
    public func resolve(_ url: URL) throws -> PDSHPageFile {
        guard url.scheme?.lowercased() == PDSHPageScheme.name else {
            throw PDSHPageResolutionError.invalidScheme(url.scheme ?? "")
        }
        guard let host = url.host, !host.isEmpty else {
            throw PDSHPageResolutionError.invalidPath(url.absoluteString)
        }
        let relative = try Self.validatedRelativePath(url.path)
        let root: URL
        if host == PDSHPageScheme.libraryHost {
            root = libraryRoot
        } else {
            guard let workspace = workspaceRoot(host) else {
                throw PDSHPageResolutionError.unknownSession(host)
            }
            root = workspace.standardizedFileURL.resolvingSymlinksInPath()
        }
        let candidate = root.appendingPathComponent(relative)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPath) else {
            throw PDSHPageResolutionError.pathEscapesRoot(relative)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path,
                                             isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw PDSHPageResolutionError.notFound(relative)
        }
        return PDSHPageFile(
            url: candidate,
            isHTML: candidate.pathExtension.lowercased() == "html"
                || candidate.pathExtension.lowercased() == "htm")
    }

    /// Rejects empty paths, absolute traversal components and Windows-style
    /// separators before any file system call.
    static func validatedRelativePath(_ path: String) throws -> String {
        let decoded = path.removingPercentEncoding ?? path
        let components = decoded.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else {
            throw PDSHPageResolutionError.invalidPath(path)
        }
        for component in components {
            guard component != "." , component != "..", !component.contains("\\"),
                  !component.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw PDSHPageResolutionError.invalidPath(path)
            }
        }
        return components.joined(separator: "/")
    }
}

/// Maps the host's workspaces to the directories a page origin serves.
public enum PDSHPageWorkspaceMap {
    /// VFS prefix every workspace directory lives under.
    public static let vfsWorkspacePrefix = "/dsh/workspace"

    /// Finds the workspace owning `relativePath` (relative to
    /// `/dsh/workspace`) and the path inside that workspace. The longest
    /// workspace directory wins; a workspace registered at `/dsh/workspace`
    /// owns every path; a path outside every workspace has no owner.
    ///
    /// - Parameters:
    ///   - relativePath: path relative to `/dsh/workspace`.
    ///   - workspaces: `(path, sessionIDs)` records from `workspace/follow`.
    /// - Returns: a session of the owning workspace and its workspace-relative
    ///   path, or `nil` when no workspace contains the path.
    public static func owner(
        relativePath: String,
        workspaces: [(path: String, sessionIDs: [String])]
    ) -> (sessionID: String, relativePath: String)? {
        var best: (directory: String, sessionID: String)?
        let path = relativePath.hasPrefix("/")
            ? String(relativePath.dropFirst())
            : relativePath
        for workspace in workspaces {
            guard let sessionID = workspace.sessionIDs.first else { continue }
            let trimmed = workspace.path.hasPrefix(vfsWorkspacePrefix)
                ? String(workspace.path.dropFirst(vfsWorkspacePrefix.count))
                : ""
            let directory = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if directory.isEmpty {
                if best == nil { best = ("", sessionID) }
                continue
            }
            guard path == directory || path.hasPrefix(directory + "/") else { continue }
            if best == nil || directory.count > best!.directory.count {
                best = (directory, sessionID)
            }
        }
        guard let best else { return nil }
        let relative = best.directory.isEmpty
            ? relativePath
            : String(relativePath.dropFirst(best.directory.count + 1))
        return (best.sessionID, relative)
    }

    /// Builds `sessionID → directory` from the host's workspace records.
    ///
    /// Each record's `path` is the session cwd (`/dsh/workspace/<rel>`); two
    /// workspaces with different cwds therefore serve different directories,
    /// and a record whose path is exactly `/dsh/workspace` serves the root.
    /// A path outside the prefix is treated as the root (the host's single
    /// VFS tree is the only thing the browser can see).
    ///
    /// - Parameters:
    ///   - root: the materialized `/dsh/workspace` directory.
    ///   - workspaces: `(path, sessionIDs)` records from `workspace/follow`.
    /// - Returns: session id to the directory its `pdsh-page:` origin serves.
    public static func directories(
        root: URL,
        workspaces: [(path: String, sessionIDs: [String])]
    ) -> [String: URL] {
        var map: [String: URL] = [:]
        for workspace in workspaces {
            let trimmed = workspace.path.hasPrefix(vfsWorkspacePrefix)
                ? String(workspace.path.dropFirst(vfsWorkspacePrefix.count))
                : ""
            let relative = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let directory = relative.isEmpty
                ? root
                : root.appendingPathComponent(relative, isDirectory: true)
            for sessionID in workspace.sessionIDs { map[sessionID] = directory }
        }
        return map
    }
}

/// The `pdsh-page:` contract constants.
public enum PDSHPageScheme {
    public static let name = "pdsh-page"
    /// Reserved host segment served from the app bundle, never a session id.
    public static let libraryHost = "lib"

    /// `Content-Type` for a served file.
    public static func contentType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "glb": return "model/gltf-binary"
        case "gltf": return "model/gltf+json"
        case "bin": return "application/octet-stream"
        case "wasm": return "application/wasm"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "ttf", "otf": return "font/otf"
        case "woff2": return "font/woff2"
        case "txt", "md": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }

    /// The tier a page declares in its first bytes; `sandbox` is the default.
    public static func declaredTier(inHTML prefix: Data) -> PDSHCSPSandboxTier {
        let text = String(decoding: prefix, as: UTF8.self).lowercased()
        for tier in [PDSHCSPSandboxTier.online, .local, .sandbox] {
            if text.contains("name=\"pdsh-csp\"" ) || text.contains("name='pdsh-csp'") {
                if text.contains("content=\"\(tier.rawValue)\"")
                    || text.contains("content='\(tier.rawValue)'") {
                    return tier
                }
            }
        }
        return .sandbox
    }

    /// The host-enforced policy of a tier (spec-render-media-v1 §B.4).
    ///
    /// The `pdsh-page:` origin is where the page and the bundled library live,
    /// so every tier allows it for scripts, styles, images, fonts and media.
    /// `local` adds `fetch()` to the page's own origin; `online` adds `https:`
    /// to network-capable directives. All tiers forbid `file:`, external
    /// frames, plugins and the host bridge (no script message handler exists).
    public static func contentSecurityPolicy(for tier: PDSHCSPSandboxTier) -> String {
        let origin = "\(name):"
        let network = tier == .online ? " https:" : ""
        let connect = tier == .sandbox ? "'none'" : "\(origin)\(network)"
        return [
            "default-src 'none'",
            "script-src 'unsafe-inline' blob: \(origin)",
            "style-src 'unsafe-inline' \(origin)",
            "img-src data: blob: \(origin)\(network)",
            "font-src data: \(origin)\(network)",
            "media-src \(origin)\(network)",
            "connect-src \(connect)",
            "frame-src 'none'",
            "worker-src blob: \(origin)",
            "object-src 'none'",
            "base-uri 'none'",
            "form-action 'none'",
        ].joined(separator: "; ")
    }

    /// Parses one `Range: bytes=start-end` header against `total`.
    /// Returns `nil` for an unsatisfiable or malformed range (200 is served).
    public static func byteRange(from header: String?, total: Int) -> (start: Int, end: Int)? {
        guard let header, total > 0 else { return nil }
        let value = header.trimmingCharacters(in: .whitespaces)
        guard value.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = value.dropFirst("bytes=".count)
        guard !spec.contains(",") else { return nil }
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let startText = parts[0].trimmingCharacters(in: .whitespaces)
        let endText = parts[1].trimmingCharacters(in: .whitespaces)
        if startText.isEmpty {
            guard let suffix = Int(endText), suffix > 0 else { return nil }
            let start = max(0, total - suffix)
            return (start, total - 1)
        }
        guard let start = Int(startText), start >= 0, start < total else { return nil }
        let end = endText.isEmpty ? total - 1 : (Int(endText) ?? total - 1)
        guard end >= start else { return nil }
        return (start, min(end, total - 1))
    }
}

/// Why a `pdsh-page:` URL did not resolve.
public enum PDSHPageResolutionError: Error, Equatable, Sendable {
    case invalidScheme(String)
    case invalidPath(String)
    case unknownSession(String)
    case pathEscapesRoot(String)
    case notFound(String)
}

/// `WKURLSchemeHandler` for `pdsh-page:`. Reads the resolved file (with an
/// optional single range) and answers the task; it holds no transport, no
/// credentials and no script bridge.
public final class PDSHPageSchemeHandler: NSObject, WKURLSchemeHandler {
    public let resolver: PDSHPageResolver

    /// File reads and chunk production run here; the WebKit delegate methods
    /// stay on the main thread and return immediately (task 2).
    private let queue = DispatchQueue(label: "dev.phone-dsh.page-scheme",
                                      qos: .userInitiated)
    /// Everything handed to the task runs on this queue in order; production
    /// uses the main thread, tests inject a private serial queue.
    private let deliveryQueue: DispatchQueue
    private let lock = NSLock()
    /// Tasks WebKit stopped. Delivering to one of them raises an internal
    /// consistency exception, so a delivery is gated on this set (task 1).
    private var stopped: Set<ObjectIdentifier> = []

    public init(resolver: PDSHPageResolver,
                deliveryQueue: DispatchQueue = .main) {
        self.resolver = resolver
        self.deliveryQueue = deliveryQueue
        super.init()
    }

    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        start(urlSchemeTask)
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        stop(urlSchemeTask)
    }

    /// Testable entry points; the WKURLSchemeHandler methods only forward.
    func start(_ task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task as AnyObject)
        lock.lock()
        stopped.remove(id)   // a reused address must not inherit an old stop
        lock.unlock()
        queue.async { [weak self] in self?.respond(to: task, id: id) }
    }

    func stop(_ task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task as AnyObject)
        lock.lock()
        stopped.insert(id)
        lock.unlock()
    }

    private func isStopped(_ id: ObjectIdentifier) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped.contains(id)
    }

    private func clearRegistration(_ id: ObjectIdentifier) {
        lock.lock()
        stopped.remove(id)
        lock.unlock()
    }

    /// Runs `body` on the delivery queue only when the task is still live. The
    /// check sits inside the block so it is serialized with `stop` on the
    /// delivery thread (main in production).
    private func deliverIfRunning(_ id: ObjectIdentifier,
                                  _ body: () -> Void) -> Bool {
        var delivered = false
        deliveryQueue.sync {
            guard !isStopped(id) else { return }
            body()
            delivered = true
        }
        return delivered
    }

    /// Chunk size of one `didReceive(_:)`; a 1 MiB window keeps peak memory
    /// independent of the file size (a 200 MB `.glb` is never fully mapped).
    static let chunkBytes = 1024 * 1024

    private func respond(to task: WKURLSchemeTask, id: ObjectIdentifier) {
        guard let url = task.request.url else {
            fail(id, task, PDSHPageResolutionError.invalidPath(""))
            return
        }
        guard (task.request.httpMethod ?? "GET").uppercased() == "GET" else {
            _ = deliverIfRunning(id) {
                task.didReceive(HTTPURLResponse(url: url, statusCode: 405,
                                                httpVersion: "HTTP/1.1",
                                                headerFields: ["Allow": "GET"])!)
            }
            finish(id, task)
            return
        }
        let file: PDSHPageFile
        do {
            file = try resolver.resolve(url)
        } catch {
            fail(id, task, error)
            return
        }

        // Open and read the first chunk *before* the response head: a file
        // that vanished or is unreadable must fail the task, never produce a
        // 200 head followed by a broken body.
        var openedHandle: FileHandle?
        let total: Int
        var firstChunk: Data
        do {
            let handle = try FileHandle(forReadingFrom: file.url)
            openedHandle = handle
            total = Int(try handle.seekToEnd())
            let requestedRange = task.request.value(forHTTPHeaderField: "Range")
            let range = PDSHPageScheme.byteRange(from: requestedRange, total: total)
            if requestedRange != nil, range == nil, total > 0 {
                // Satisfiable-range protocol: an out-of-bounds or malformed
                // Range answers 416 with the current length, not the whole
                // file (task 5).
                _ = deliverIfRunning(id) {
                    task.didReceive(HTTPURLResponse(
                        url: url, statusCode: 416, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Range": "bytes */\(total)",
                                       "Accept-Ranges": "bytes"])!)
                }
                try? handle.close()
                finish(id, task)
                return
            }
            let start = range?.start ?? 0
            let end = range?.end ?? max(total - 1, 0)
            try handle.seek(toOffset: UInt64(start))
            firstChunk = try readChunk(from: handle,
                                       limit: min(Self.chunkBytes, max(end - start + 1, 0)))
            guard !isStopped(id) else {
                try? handle.close()
                return
            }
            var headers: [String: String] = [
                "Content-Type": PDSHPageScheme.contentType(
                    forExtension: file.url.pathExtension),
                "Accept-Ranges": "bytes",
                "Cache-Control": "no-store",
            ]
            let bodyLength = range.map { $0.end - $0.start + 1 } ?? total
            if let range {
                headers["Content-Range"] = "bytes \(range.start)-\(range.end)/\(total)"
            }
            headers["Content-Length"] = String(bodyLength)
            if file.isHTML {
                let tier = PDSHPageScheme.declaredTier(inHTML: firstChunk.prefix(4096))
                headers["Content-Security-Policy"] =
                    PDSHPageScheme.contentSecurityPolicy(for: tier)
            }
            guard let response = HTTPURLResponse(url: url,
                                                 statusCode: range == nil ? 200 : 206,
                                                 httpVersion: "HTTP/1.1",
                                                 headerFields: headers) else {
                throw PDSHPageResolutionError.invalidPath(url.absoluteString)
            }
            guard deliverIfRunning(id, { task.didReceive(response) }) else {
                try? handle.close()
                return
            }
            var sent = 0
            while true {
                let remaining = bodyLength - sent
                guard remaining > 0 else { break }
                let chunk = firstChunk.isEmpty
                    ? try readChunk(from: handle, limit: min(Self.chunkBytes, remaining))
                    : firstChunk
                if chunk.isEmpty { break }
                guard deliverIfRunning(id, { task.didReceive(chunk) }) else {
                    try? handle.close()
                    return
                }
                sent += chunk.count
                firstChunk = Data()
                if chunk.count > remaining { break }
            }
            try? handle.close()
            finish(id, task)
        } catch {
            try? openedHandle?.close()
            fail(id, task, error)
        }
    }

    private func finish(_ id: ObjectIdentifier, _ task: WKURLSchemeTask) {
        _ = deliverIfRunning(id) { task.didFinish() }
        clearRegistration(id)
    }

    private func fail(_ id: ObjectIdentifier, _ task: WKURLSchemeTask, _ error: Error) {
        _ = deliverIfRunning(id) { task.didFailWithError(error) }
        clearRegistration(id)
    }

    /// Reads at most `limit` bytes; an empty result means EOF.
    private func readChunk(from handle: FileHandle, limit: Int) throws -> Data {
        guard limit > 0 else { return Data() }
        return try handle.read(upToCount: limit) ?? Data()
    }
}
