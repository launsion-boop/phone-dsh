// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHShell: the C surface.
//
// The Swift provider only ever sees the small surface declared by
// shell/include/xzshell.h: version, capability JSON, start, cancel and
// join. With `PDSH_WITH_XZSHELL` the functions below forward to the Rust static
// library in `shell/dist/PDSHShell.xcframework`; without the switch this file
// compiles the same surface as a pure-Swift stub so `PhoneDSHShell`
// always builds and the provider can fail with `PDSHShellError.notLinked`.

import Foundation

#if PDSH_WITH_XZSHELL
import Darwin
import PDSHShell
#endif

/// One execution handed to the C surface.
internal struct PDSHShellRunSpec: Sendable {
    var argv: [String]
    var cwd: String
    var env: [(String, String)]
    var mounts: [(guest: String, host: String)]
    var timeoutMilliseconds: UInt64
    /// `pdsh_monotonic_nanos()` sampled at the request start, before the C
    /// strings and the Rust request are built. The Rust cancel token uses it
    /// to arm its deadline before parsing, so parse time spends the original
    /// request budget instead of restarting it.
    var requestStartNanos: UInt64
    var maxOutputBytes: Int
    var maxFiles: Int
    var maxFileBytes: UInt64
}

/// Callbacks of one run. The Rust worker thread invokes them synchronously;
/// `callTool` blocks that thread only until the injected async bridge answers,
/// the per-exec deadline expires, or `pdsh_cancel` wakes it.
internal final class PDSHShellCallbackSink: @unchecked Sendable {
    let stdout: (Data) -> Void
    let stderr: (Data) -> Void
    let exit: (Int32) -> Void
    let callTool: (String, String, UnsafeMutablePointer<UInt8>?, Int) -> Int

    init(stdout: @escaping (Data) -> Void,
         stderr: @escaping (Data) -> Void,
         exit: @escaping (Int32) -> Void,
         callTool: @escaping (String, String, UnsafeMutablePointer<UInt8>?, Int) -> Int) {
        self.stdout = stdout
        self.stderr = stderr
        self.exit = exit
        self.callTool = callTool
    }
}

/// Result of starting one command: the positive Rust handle plus the request
/// storage that must outlive `pdsh_join` (xzshell.h, threading and ownership).
internal struct PDSHShellStartResult {
    var handle: Int32
    var retained: AnyObject?
}

#if PDSH_WITH_XZSHELL

/// Thin Swift mirror of the C ABI (shell/include/xzshell.h).
internal enum PDSHShellC {
    /// The Rust library is linked into this build.
    static let linked = true

    /// `pdsh_version()`.
    static var version: String {
        guard let pointer = pdsh_version() else { return "" }
        return String(cString: pointer)
    }

    /// `pdsh_monotonic_nanos()`: the same monotonic clock the FFI uses to arm
    /// its cancel-token deadline. Clamp to 1 because the FFI reserves zero for
    /// "start not supplied"; the very first sample in a process could
    /// otherwise be zero and lose the C-string/parse time from the budget.
    static func monotonicNanos() -> UInt64 {
        max(1, pdsh_monotonic_nanos())
    }

    /// `pdsh_caps_json_with_bridge()`, decoded for this provider's bridge
    /// presence.
    ///
    /// The Rust registry only registers and advertises `phone` / `ctx` when a
    /// host bridge can answer `call_tool`, so the capability JSON the provider
    /// publishes is exactly what it can execute.
    static func caps(hasToolBridge: Bool) -> PDSHShellCaps? {
        let needed = pdsh_caps_json_with_bridge(hasToolBridge ? 1 : 0, nil, 0)
        guard needed > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(needed) + 1)
        let written = buffer.withUnsafeMutableBufferPointer { bytes in
            pdsh_caps_json_with_bridge(hasToolBridge ? 1 : 0, bytes.baseAddress, bytes.count)
        }
        guard written == needed else { return nil }
        let data = Data(buffer.prefix(Int(needed)))
        return try? JSONDecoder().decode(PDSHShellCaps.self, from: data)
    }

    /// `pdsh_run()`. The callbacks race the handle return for fast commands, so
    /// the caller registers its job before calling and attaches the handle
    /// afterwards; the returned storage is retained until `pdsh_join`.
    static func start(_ spec: PDSHShellRunSpec, sink: PDSHShellCallbackSink) -> PDSHShellStartResult {
        let storage = PDSHShellCRequestStorage(spec)
        let user = Unmanaged.passUnretained(sink).toOpaque()
        let callbacks = XzCallbacks(on_stdout: xzShellCStdout,
                                    on_stderr: xzShellCStderr,
                                    on_exit: xzShellCExit,
                                    call_tool: xzShellCCallTool)
        let handle = storage.argvPointers.withUnsafeBufferPointer { argv -> Int32 in
            storage.envPairs.withUnsafeBufferPointer { env -> Int32 in
                storage.mounts.withUnsafeBufferPointer { mounts -> Int32 in
                    var request = XzRequest(argc: argv.count,
                                            argv: argv.baseAddress,
                                            cwd: storage.cwd,
                                            env_count: env.count,
                                            env: env.baseAddress,
                                            mount_count: mounts.count,
                                            mounts: mounts.baseAddress,
                                            limits: storage.limits,
                                            request_start_nanos: spec.requestStartNanos)
                    return withUnsafePointer(to: &request) { requestPointer in
                        withUnsafePointer(to: callbacks) { callbackPointer in
                            pdsh_run(requestPointer, callbackPointer, user)
                        }
                    }
                }
            }
        }
        return PDSHShellStartResult(handle: handle, retained: storage)
    }

    /// `pdsh_cancel()`; answers `false` for an unknown/joined handle.
    static func cancel(_ handle: Int32) -> Bool {
        pdsh_cancel(handle) == 0
    }

    /// `pdsh_join()`; must be called exactly once per handle.
    static func join(_ handle: Int32) -> Int32 {
        pdsh_join(handle)
    }
}

/// Owns every C string and pointer array of one request until `pdsh_join`.
private final class PDSHShellCRequestStorage: @unchecked Sendable {
    let cwd: UnsafeMutablePointer<CChar>
    let argvPointers: [UnsafePointer<CChar>?]
    let envPairs: [XzEnvPair]
    let mounts: [XzMount]
    let limits: XzLimits

    private var allocations: [UnsafeMutablePointer<CChar>] = []

    init(_ spec: PDSHShellRunSpec) {
        func allocate(_ string: String) -> UnsafeMutablePointer<CChar> {
            let pointer = strdup(string)!
            return pointer
        }

        let cwd = allocate(spec.cwd)
        let argvPointers = spec.argv.map { allocate($0) }.map { UnsafePointer<CChar>($0) }
        var envPairs: [XzEnvPair] = []
        envPairs.reserveCapacity(spec.env.count)
        for (key, value) in spec.env {
            envPairs.append(XzEnvPair(key: allocate(key), value: allocate(value)))
        }
        var mounts: [XzMount] = []
        mounts.reserveCapacity(spec.mounts.count)
        for mount in spec.mounts {
            mounts.append(XzMount(guest: allocate(mount.guest), host: allocate(mount.host)))
        }

        // Keep the C string allocations in one place and free them in deinit,
        // i.e. after pdsh_join returns and the handle is invalid.
        let cwdPointer = cwd
        var owned: [UnsafeMutablePointer<CChar>] = [cwdPointer]
        owned.append(contentsOf: argvPointers.map { UnsafeMutablePointer(mutating: $0) })
        for pair in envPairs {
            owned.append(UnsafeMutablePointer(mutating: pair.key))
            owned.append(UnsafeMutablePointer(mutating: pair.value))
        }
        for mount in mounts {
            owned.append(UnsafeMutablePointer(mutating: mount.guest))
            owned.append(UnsafeMutablePointer(mutating: mount.host))
        }

        self.cwd = cwd
        self.argvPointers = argvPointers
        self.envPairs = envPairs
        self.mounts = mounts
        self.limits = XzLimits(timeout_ms: spec.timeoutMilliseconds,
                               max_output_bytes: spec.maxOutputBytes,
                               max_files: spec.maxFiles,
                               max_file_bytes: spec.maxFileBytes)
        self.allocations = owned
    }

    deinit {
        for pointer in allocations {
            free(pointer)
        }
    }
}

private func xzShellCStdout(_ user: UnsafeMutableRawPointer?,
                            _ pointer: UnsafePointer<UInt8>?,
                            _ length: Int) {
    guard let user, let pointer, length > 0 else { return }
    let sink = Unmanaged<PDSHShellCallbackSink>.fromOpaque(user).takeUnretainedValue()
    sink.stdout(Data(bytes: pointer, count: length))
}

private func xzShellCStderr(_ user: UnsafeMutableRawPointer?,
                            _ pointer: UnsafePointer<UInt8>?,
                            _ length: Int) {
    guard let user, let pointer, length > 0 else { return }
    let sink = Unmanaged<PDSHShellCallbackSink>.fromOpaque(user).takeUnretainedValue()
    sink.stderr(Data(bytes: pointer, count: length))
}

private func xzShellCExit(_ user: UnsafeMutableRawPointer?, _ code: Int32) {
    guard let user else { return }
    let sink = Unmanaged<PDSHShellCallbackSink>.fromOpaque(user).takeUnretainedValue()
    sink.exit(code)
}

private func xzShellCCallTool(_ user: UnsafeMutableRawPointer?,
                              _ name: UnsafePointer<CChar>?,
                              _ arguments: UnsafePointer<CChar>?,
                              _ output: UnsafeMutablePointer<UInt8>?,
                              _ capacity: Int) -> Int {
    guard let user, let name, let arguments else { return -1 }
    let sink = Unmanaged<PDSHShellCallbackSink>.fromOpaque(user).takeUnretainedValue()
    return sink.callTool(String(cString: name), String(cString: arguments), output, capacity)
}

#else

/// Pure-Swift stub of the same C surface. It never starts a thread and never
/// claims an accelerator, so a build without `PDSH_WITH_XZSHELL` cannot
/// accidentally behave like the Rust library.
internal enum PDSHShellC {
    static let linked = false
    static let version = "not linked"

    static func monotonicNanos() -> UInt64 { 0 }

    static func caps(hasToolBridge: Bool) -> PDSHShellCaps? { nil }

    static func start(_ spec: PDSHShellRunSpec,
                      sink: PDSHShellCallbackSink) -> PDSHShellStartResult {
        PDSHShellStartResult(handle: -1, retained: nil)
    }

    static func cancel(_ handle: Int32) -> Bool { false }
    static func join(_ handle: Int32) -> Int32 { -1 }
}

#endif
