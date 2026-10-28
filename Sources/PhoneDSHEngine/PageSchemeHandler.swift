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

    public init(resolver: PDSHPageResolver) {
        self.resolver = resolver
    }

    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        respond(to: urlSchemeTask)
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func respond(to task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(PDSHPageResolutionError.invalidPath(""))
            return
        }
        guard (task.request.httpMethod ?? "GET").uppercased() == "GET" else {
            task.didReceive(HTTPURLResponse(url: url, statusCode: 405,
                                            httpVersion: "HTTP/1.1",
                                            headerFields: ["Allow": "GET"])!)
            task.didFinish()
            return
        }
        let file: PDSHPageFile
        do {
            file = try resolver.resolve(url)
        } catch {
            task.didFailWithError(error)
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: file.url, options: [.mappedIfSafe])
        } catch {
            task.didFailWithError(error)
            return
        }
        var headers: [String: String] = [
            "Content-Type": PDSHPageScheme.contentType(
                forExtension: file.url.pathExtension),
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-store",
        ]
        if file.isHTML {
            let tier = PDSHPageScheme.declaredTier(
                inHTML: data.prefix(4096))
            headers["Content-Security-Policy"] =
                PDSHPageScheme.contentSecurityPolicy(for: tier)
        }
        let range = PDSHPageScheme.byteRange(
            from: task.request.value(forHTTPHeaderField: "Range"), total: data.count)
        if let range {
            let slice = data.subdata(in: range.start..<(range.end + 1))
            headers["Content-Range"] =
                "bytes \(range.start)-\(range.end)/\(data.count)"
            headers["Content-Length"] = String(slice.count)
            guard let response = HTTPURLResponse(url: url, statusCode: 206,
                                                 httpVersion: "HTTP/1.1",
                                                 headerFields: headers) else {
                task.didFailWithError(PDSHPageResolutionError.invalidPath(url.absoluteString))
                return
            }
            task.didReceive(response)
            task.didReceive(slice)
        } else {
            headers["Content-Length"] = String(data.count)
            guard let response = HTTPURLResponse(url: url, statusCode: 200,
                                                 httpVersion: "HTTP/1.1",
                                                 headerFields: headers) else {
                task.didFailWithError(PDSHPageResolutionError.invalidPath(url.absoluteString))
                return
            }
            task.didReceive(response)
            task.didReceive(data)
        }
        task.didFinish()
    }
}
