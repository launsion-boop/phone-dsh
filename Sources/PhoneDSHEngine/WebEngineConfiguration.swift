// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHEngine: boot configuration.
//
// PLAN §2.1/§2.3/§2.5 and D22. The page and the Worker run from one loopback
// origin. This configuration builds the boot page URL: the per-start token
// travels in the query string exactly once, so the page's relative `boot.js`
// and `worker-entry.js` requests authenticate with the launch cookie the
// loopback page response sets (no query rewriting by the App). Every boot gets
// a fresh overlay URL derived from `boot_id`, so a reload after a WebContent
// termination replays a new overlay instead of a stale cached one. The
// loopback origin itself is the only place the token is accepted; the engine
// never logs it.

import Foundation

/// Execution-authority hint the page forwards to the Worker in its init frame.
///
/// This is a boot input only. The authoritative fence lives in the host
/// controller (PLAN §2.4/§2.5); the engine copies the value the caller supplies
/// so the Worker's first HELLO carries the matching generation.
public struct WebEngineFence: Equatable, Sendable {
    public var owner: String
    public var generation: UInt64
    public var walSeq: UInt64

    public init(owner: String = "phone", generation: UInt64 = 0, walSeq: UInt64 = 0) {
        self.owner = owner
        self.generation = generation
        self.walSeq = walSeq
    }

    /// The `{owner, generation, wal_seq}` JSON the page forwards unchanged.
    var jsonString: String {
        let object: [String: Any] = [
            "owner": owner,
            "generation": generation,
            "wal_seq": walSeq,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}

/// WKWebView boot configuration.
public struct WebEngineConfiguration: Equatable, Sendable {
    /// Minimum visible attachment area, in points. Documented requirement:
    /// the web view must be in a window and not fully clipped while the worker
    /// runs, even when the UI shows a placeholder.
    public static let requiredVisibleAreaPoints: Double = 1

    /// The initial page path callers get when they do not configure one.
    ///
    /// ``PhoneDSHHost`` treats this value as "the caller did not select a
    /// page" and resolves it to the historical bootstrap
    /// `/static/index.html`. A complete-Web caller selects
    /// `/static/web/index.html` explicitly; any other value is served as the
    /// caller set it.
    public static let defaultPagePath = "/index.html"

    /// Loopback origin the page and Worker load from.
    public var origin: URL
    /// Page path served by the loopback origin.
    public var pagePath: String
    /// Worker entry path served by the loopback origin.
    ///
    /// The page loads the Worker relative to itself (`worker-entry.js`); this
    /// value documents the expected path and is available to callers that
    /// arrange the static directory themselves.
    public var workerPath: String
    /// Boot overlay path (`vfs-image.tar.gz`) served by the loopback origin.
    public var imagePath: String
    /// Visible attachment area provided by the host UI, in points.
    public var visibleAreaPoints: Double
    /// Keep WKWebView's Lockdown Mode on when the user enabled it system-wide.
    ///
    /// The engine always reports the actual system flag in
    /// ``WebEngineCapabilities/lockdownModeEnabled``; this value is a policy
    /// hint for callers that can operate a Lockdown-compatible page and is not
    /// used to mask the flag.
    public var allowsLockdownMode: Bool
    /// Per-start loopback bearer token, appended to the boot page URL.
    ///
    /// Credentials never reach the Worker; the token only authenticates
    /// same-origin loopback requests and the ordered channel. Empty means the
    /// caller must pass an explicit page URL to ``WebEngine/load(_:)``.
    public var token: String
    /// Ordered-channel path on the loopback origin.
    public var channelPath: String
    /// Boot identifier. `nil` asks the engine to generate a fresh 32-character
    /// lowercase hexadecimal id for each boot.
    public var bootID: String?
    /// Host session incarnation forwarded to the Worker.
    public var sessionEpoch: UInt64?
    /// Additional overlay paths applied after the base image, in order.
    public var overlays: [String]
    /// Environment entries forwarded to the Worker init frame.
    public var environment: [String: String]
    /// Execution-authority hint forwarded to the Worker init frame.
    public var fence: WebEngineFence?
    /// Time budget for the navigation and for the boot-ready message.
    public var bootTimeout: TimeInterval
    /// Use the persistent `WKWebsiteDataStore.default()` instead of an
    /// in-memory store.
    ///
    /// The native page leaves this `false`: its transcript lives in the
    /// workspace, not in the browser. A complete DSH Web surface sets it so
    /// the client's localStorage (`dsh.sessions.current`) and the rest of its
    /// browser state survive the WKWebView recreation that a park/resume
    /// performs. Persistence is only useful together with a stable origin;
    /// the caller owns that part of the configuration.
    public var usesPersistentWebsiteDataStore: Bool
    /// Optional stored JIT-probe baseline in milliseconds.
    ///
    /// The probe is informational only; when this is `nil` the engine stores
    /// the first measurement in memory as its process-lifetime baseline and
    /// reports a ratio on later runs.
    public var jitBaselineMilliseconds: Double?

    public init(origin: URL, pagePath: String = WebEngineConfiguration.defaultPagePath,
                workerPath: String = "/worker.js",
                imagePath: String = "/vfs-image.tar.gz",
                visibleAreaPoints: Double = WebEngineConfiguration.requiredVisibleAreaPoints,
                allowsLockdownMode: Bool = true,
                token: String = "",
                channelPath: String = "/channel",
                bootID: String? = nil,
                sessionEpoch: UInt64? = nil,
                overlays: [String] = [],
                environment: [String: String] = [:],
                fence: WebEngineFence? = nil,
                bootTimeout: TimeInterval = 30,
                usesPersistentWebsiteDataStore: Bool = false,
                jitBaselineMilliseconds: Double? = nil) {
        self.origin = origin
        self.pagePath = pagePath
        self.workerPath = workerPath
        self.imagePath = imagePath
        self.visibleAreaPoints = visibleAreaPoints
        self.allowsLockdownMode = allowsLockdownMode
        self.token = token
        self.channelPath = channelPath
        self.bootID = bootID
        self.sessionEpoch = sessionEpoch
        self.overlays = overlays
        self.environment = environment
        self.fence = fence
        self.bootTimeout = bootTimeout
        self.usesPersistentWebsiteDataStore = usesPersistentWebsiteDataStore
        self.jitBaselineMilliseconds = jitBaselineMilliseconds
    }

    /// Whether `value` is a 32-character lowercase hexadecimal boot id (D6).
    public static func isValidBootID(_ value: String) -> Bool {
        guard value.count == 32 else { return false }
        return value.allSatisfy { character in
            ("0"..."9").contains(character) || ("a"..."f").contains(character)
        }
    }

    /// Builds the boot page URL for `bootID`.
    ///
    /// The URL carries the loopback token in its query string exactly once
    /// (D22; the page forwards it to the Worker in the init frame and never
    /// writes it into the markup), the packed image and overlay URLs, the
    /// ordered-channel URL and the optional fence/environment/epoch boot
    /// inputs.
    ///
    /// - Parameter bootID: A 32-character lowercase hexadecimal id. `nil` uses
    ///   ``bootID`` and generates a fresh one when that is also `nil`.
    public func makePageURL(bootID requestedBootID: String? = nil) throws -> URL {
        guard token.isEmpty == false else {
            throw WebEngineError.invalidConfiguration("the loopback token is missing")
        }
        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false else {
            throw WebEngineError.invalidOrigin(origin.absoluteString)
        }
        let resolvedBootID = requestedBootID ?? bootID ?? WebEngineBootID.make()
        guard Self.isValidBootID(resolvedBootID) else {
            throw WebEngineError.invalidConfiguration(
                "boot_id must be 32 lowercase hexadecimal characters")
        }

        let base = originString()
        func absolute(_ path: String) -> String {
            if let url = URL(string: path), url.scheme != nil {
                return path
            }
            if path.hasPrefix("/") {
                return base + path
            }
            return base + "/" + path
        }
        // The image and overlay fetches happen inside the Worker, not from the
        // page, so they do not inherit the page URL's query. The loopback
        // origin authenticates every request, therefore these URLs carry the
        // same per-start token that the page carries.
        func tokenized(_ raw: String) -> String {
            guard var components = URLComponents(string: raw) else { return raw }
            var items = components.queryItems ?? []
            if items.contains(where: { $0.name == "token" }) == false {
                items.append(URLQueryItem(name: "token", value: token))
            }
            components.queryItems = items
            return components.string ?? raw
        }

        components.path = pagePath.hasPrefix("/") ? pagePath : "/" + pagePath
        var items: [URLQueryItem] = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "image", value: tokenized(absolute(imagePath))),
            URLQueryItem(name: "channel", value: absolute(channelPath)),
            URLQueryItem(name: "boot_id", value: resolvedBootID),
            // PLAN §2.3 / D21: the loopback serves a fresh gzip-compressed
            // overlay per boot id, so the boot sequence is idempotent across
            // reloads.
            URLQueryItem(name: "overlay",
                         value: tokenized(absolute("/image/overlay/\(resolvedBootID).tar"))),
        ]
        if let sessionEpoch {
            items.append(URLQueryItem(name: "session_epoch", value: String(sessionEpoch)))
        }
        if let fence {
            items.append(URLQueryItem(name: "fence", value: fence.jsonString))
        }
        if environment.isEmpty == false {
            items.append(URLQueryItem(name: "env", value: Self.encode(environment)))
        }
        for overlay in overlays {
            items.append(URLQueryItem(name: "overlay", value: tokenized(absolute(overlay))))
        }
        components.queryItems = items

        guard let url = components.url else {
            throw WebEngineError.invalidConfiguration("the boot page URL could not be built")
        }
        return url
    }

    private func originString() -> String {
        var text = origin.absoluteString
        while text.hasSuffix("/") {
            text.removeLast()
        }
        return text
    }

    private static func encode(_ environment: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: environment,
                                                     options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
