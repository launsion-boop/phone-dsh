// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — ProbeKit: the App's complete-Web host assembly.
//
// The production Web surface (`WebHostModel`) and the simulator full-Web E2E
// must boot the same host, not two near-copies. This file owns the values that
// make the App's Web surface work across a park/resume:
//
//   * the explicit complete-page route (`/static/web/index.html`), so the
//     native default (`/static/index.html`) is never changed globally;
//   * one pinned loopback port for the page origin, so DSH's
//     `dsh.sessions.current` localStorage selection survives the WKWebView
//     recreation;
//   * the persistent `WKWebsiteDataStore` engine factory;
//   * the linked `PDSHShellProvider` exec provider and the accelerator names
//     this build can actually execute (never a capability it cannot run).
//
// `ChatHostConfiguration.make` still owns the shared workspace, model gateway
// and Worker environment. This assembly only adds the complete-Web surface's
// transport/capability configuration on top of it, so a suite that uses this
// factory exercises the production host path instead of a parallel host.

import Darwin
import Foundation
import PhoneDSH
import PhoneDSHAgentCore
import PhoneDSHEngine
import PhoneDSHShell

/// Host assembly shared by the App's Web surface and the full-Web E2E suite.
public enum WebHostConfiguration {
    /// Integration contract: the complete DSH Web page served by the bundle.
    public static let pagePath = "/static/web/index.html"
    /// UserDefaults key the App uses to keep one loopback port across launches.
    public static let loopbackPortDefaultsKey = "web.dsh.loopbackPort"

    /// The values a caller needs to boot and audit the Web host.
    public struct Assembly {
        /// Host configuration including the complete-page path and shell caps.
        public let configuration: PhoneDSHConfiguration
        /// The linked read-only provider the host advertises/executes.
        public let shellProvider: PDSHShellProvider

        public init(configuration: PhoneDSHConfiguration,
                    shellProvider: PDSHShellProvider) {
            self.configuration = configuration
            self.shellProvider = shellProvider
        }
    }

    /// Builds the complete-Web configuration on top of the shared chat host.
    ///
    /// - Parameters:
    ///   - workspaceRoot: the same `Documents/chat-host` workspace the native
    ///     page uses.
    ///   - bundle: the packed Worker assets.
    ///   - modelURL: the model upstream; its host becomes the gateway allow
    ///     rule. `nil` (a first launch with no selected provider) leaves the
    ///     caller-supplied `allowedModelHosts` in force and the page still
    ///     boots, so the native configuration sheet is reachable.
    ///   - modelName: `PDSH_MODEL_NAME` forwarded to the Worker.
    ///   - credentialProvider: host-side credentials; never reaches the
    ///     Worker.
    ///   - egressHosts: additional `/v1/http` hosts (empty for the suite).
    ///   - loopbackPort: pinned origin port; `0` asks the host for an
    ///     ephemeral port (only for callers that do not need park/resume).
    ///   - allowedModelHosts: the launch plan's exact gateway allow-list.
    ///     `nil` derives it from `modelURL`; an empty set deliberately keeps
    ///     the gateway closed while the page remains reachable.
    ///   - environment: the launch plan's complete non-secret Worker
    ///     environment. `nil` derives the suite/default environment.
    ///   - workerPlaceholderKey: placeholder the Worker sees instead of the
    ///     real model key.
    ///   - pagePath: the complete page route; tests may override to prove an
    ///     explicit request is honoured, but production uses ``pagePath``.
    public static func make(workspaceRoot: URL,
                            bundle: PhoneDSHBundleLocation,
                            modelURL: URL? = nil,
                            modelName: String = "",
                            credentialProvider: any CredentialProvider,
                            egressHosts: Set<String>,
                            loopbackPort: UInt16,
                            allowedModelHosts: Set<String>? = nil,
                            egressAuthorizer: (any EgressHostAuthorizing)? = nil,
                            environment: [String: String]? = nil,
                            workerPlaceholderKey: String =
                                ChatHostConfiguration.workerPlaceholderKey,
                            pagePath: String = WebHostConfiguration.pagePath,
                            drainDeadline: TimeInterval =
                                ChatHostConfiguration.defaultDrainDeadline,
                            helloTimeout: TimeInterval =
                                ChatHostConfiguration.defaultHelloTimeout)
        -> Assembly {
        // The chat assembly needs a concrete URL only to derive its default
        // host rule and environment. A caller that supplies the launch plan
        // (the App's WebHostModel) overrides both below; the loopback
        // placeholder never becomes a reachable model route.
        let modelBaseURL = modelURL ?? URL(string: "http://127.0.0.1:1")!
        var configuration = ChatHostConfiguration.make(
            workspaceRoot: workspaceRoot,
            bundle: bundle,
            modelBaseURL: modelBaseURL,
            modelName: modelName,
            credentialProvider: credentialProvider,
            egressHosts: egressHosts,
            workerPlaceholderKey: workerPlaceholderKey,
            drainDeadline: drainDeadline,
            helloTimeout: helloTimeout)
        if let allowedModelHosts {
            configuration.allowedModelHosts = allowedModelHosts
        }
        configuration.egressAuthorizer = egressAuthorizer
        if let environment {
            configuration.engine.environment = environment
        }
        // The provider reads the WAL-owned materialized mounts derived from
        // this same workspace root; App and E2E therefore execute the same
        // read-only accelerator surface, never a host path outside the WAL.
        let shellProvider = PDSHShellProvider(workspaceRoot: workspaceRoot)
        configuration.accelerators = shellProvider
        configuration.execProvider = shellProvider
        if !shellProvider.acceleratorNames.isEmpty {
            let names = shellProvider.channelAcceleratorNames
            if !names.isEmpty {
                configuration.acceleratorNames = names
            }
        }
        configuration.engine.bootTimeout = ChatHostConfiguration.defaultBootTimeout
        // One origin for the whole Web-surface lifetime. park() stops the
        // listener and resume() binds it again; an ephemeral port would move
        // the origin and lose the Web client's session selection.
        configuration.loopback.port = loopbackPort
        // The complete Web client stores `dsh.sessions.current` in browser
        // storage. The native page leaves this false.
        configuration.engine.usesPersistentWebsiteDataStore = true
        configuration.engine.pagePath = pagePath
        return Assembly(configuration: configuration, shellProvider: shellProvider)
    }

    /// Engine factory that creates every engine from the host's *final*
    /// configuration (bound origin/token, persistent store), attaches it to
    /// the visible anchor and lets the caller publish/prepare the instance.
    ///
    /// The persistent data store is applied when `WebEngine` is constructed.
    /// Creating an engine from a placeholder configuration before `start()`
    /// would freeze a non-persistent store for the whole host, so callers must
    /// use this factory for the real boot.
    @MainActor
    public static func engineFactory(
        anchor: VisibleEngineAnchor,
        prepare: (@MainActor @Sendable (WebEngine) -> Void)? = nil)
        -> PhoneDSHEngineFactory {
        return { configuration in
            await MainActor.run {
                let engine = anchor.makeEngine(configuration)
                prepare?(engine)
                return engine as any WebEngineControlling
            }
        }
    }

    /// Reserves a currently free loopback port and releases it before the
    /// listener binds it. A suite uses this so its fixed-origin assertion does
    /// not collide with an unrelated process.
    public static func freeLoopbackPort() -> UInt16 {
        guard let descriptor = boundLoopbackSocket(port: 0) else { return 0 }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard result == 0 else { return 0 }
        return UInt16(bigEndian: address.sin_port)
    }

    private static func boundLoopbackSocket(port: UInt16) -> Int32? {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var reuse: Int32 = 1
        _ = Darwin.setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse,
                              socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        return descriptor
    }
}
