// SPDX-License-Identifier: MIT
import Foundation
import Darwin
import PhoneDSHAgentCore

/// Binary file transport; pull records are committed by the Worker VFS/WAL.
public final class ADBExecProvider: ExecProvider, @unchecked Sendable {
    private let workspace: URL
    private let transfers: URL
    private let fallback: any ExecProvider
    private let executor: any ADBCommandExecuting
    private let settings: ADBSettings
    private let limit: Int
    private let lock = NSLock()
    private var nativeTransfers = Set<String>()
    private var tasks: [String: Task<Void, Never>] = [:]

    public init(workspace: URL, fallback: any ExecProvider, byteLimit: Int = 32 * 1024 * 1024,
                transfersDirectory: URL? = nil, settings: ADBSettings = .shared, executor: any ADBCommandExecuting = ADBClient()) {
        self.transfers = transfersDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("adb-transfers")
        self.workspace = workspace; self.fallback = fallback; self.settings = settings; self.executor = executor
        self.limit = max(1, min(byteLimit, 128 * 1024 * 1024))
    }
    public var capabilities: ExecCapabilities { fallback.capabilities }

    public func run(_ request: ExecRequest) -> AsyncThrowingStream<ExecEvent, Error> {
        guard request.argv.first == "adb" else { return fallback.run(request) }
        return AsyncThrowingStream { continuation in
            // Hold the lock until registration so a fast task cannot remove itself first.
            lock.lock()
            guard tasks[request.execID] == nil else {
                lock.unlock(); continuation.finish(throwing: ADBFailure("ADB execution already active")); return
            }
            let task = Task {
                defer {
                    _ = self.lock.withLock { self.tasks.removeValue(forKey: request.execID) }
                    continuation.finish()
                }
                var code: Int32 = 0
                do {
                    try Task.checkCancellation()
                    let args = request.argv
                    if args.count == 4, args[1] == "--pdsh-v1", args[2] == "stat" {
                        let status = try self.fileStatus(args[3])
                        continuation.yield(.stdout(seq: 0, data: status))
                        continuation.yield(.exit(code: 0, signal: nil, truncated: false))
                        return
                    }
                    guard args.count == 5, args[1] == "--pdsh-v1", ["push", "pull"].contains(args[2]),
                          request.standardInput?.isEmpty != false else { throw ADBFailure("Use adb push LOCAL REMOTE or adb pull REMOTE [LOCAL] through the Worker shell") }
                    let remote = args[4]
                    guard remote.hasPrefix("/"), !remote.hasSuffix("/"), !remote.utf8.contains(0),
                          remote.utf8.count < 1000 else { throw ADBFailure("Android destination/source must be an absolute file path") }
                    let endpoint = try self.settings.load().endpoint()
                    let native = args[3].hasPrefix("/dsh/transfers/")
                    let timeout = min(native ? 3600 : 120, (request.deadline ?? Date().addingTimeInterval(native ? 3600 : 120)).timeIntervalSinceNow)
                    guard timeout >= 0.1 else { throw ADBFailure("ADB transfer deadline expired") }
                    if native {
                        let count = try await self.transferNative(action: args[2], local: args[3], remote: remote, endpoint: endpoint, timeout: timeout)
                        continuation.yield(.stdout(seq: 0, data: Data("Transferred \(count) bytes: \(args[3])\n".utf8)))
                    } else {
                    let result: ADBShellResult
                    if args[2] == "push" {
                        let data = try ADBWorkspaceAPK.read(path: args[3], root: self.workspace, apk: false, maximumBytes: self.limit)
                        let parent = (remote as NSString).deletingLastPathComponent
                        let destination = ADBTools.quote(remote)
                        let command = "t=$(mktemp " + ADBTools.quote(parent + "/.pdsh-adb-XXXXXX") + ") || exit 1; trap 'rm -f \"$t\"' EXIT; cat >\"$t\" && [ \"$(wc -c <\"$t\")\" -eq \(data.count) ] && [ ! -d \(destination) ] && mv -f \"$t\" \(destination)"
                        result = try await self.executor.shell(endpoint: endpoint, command: command, stdin: data, timeout: timeout, outputLimit: 65536)
                    } else {
                        let source = ADBTools.quote(remote)
                        result = try await self.executor.shell(endpoint: endpoint, command: "[ -f \(source) ] && [ ! -L \(source) ] && cat \(source)", timeout: timeout, outputLimit: self.limit)
                    }
                    guard result.exitCode == 0 else {
                        throw ADBFailure("Android transfer failed (exit \(result.exitCode)): " + String(decoding: result.stderr, as: UTF8.self))
                    }
                    try Task.checkCancellation()
                    if args[2] == "pull" {
                        guard result.stdout.count <= self.limit else { throw ADBFailure("ADB pull exceeds the device file budget") }
                        func record(_ value: [String: Any]) throws {
                            var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]); data.append(10)
                            continuation.yield(.stdout(seq: 0, data: data))
                        }
                        try record(["type": "file", "path": "", "name": (remote as NSString).lastPathComponent, "size": result.stdout.count])
                        for start in stride(from: 0, to: result.stdout.count, by: 32768) {
                            try Task.checkCancellation()
                            try record(["type": "data", "data": result.stdout.subdata(in: start..<min(start + 32768, result.stdout.count)).base64EncodedString()])
                        }
                        try record(["type": "end", "path": ""])
                    }
                    }
                } catch {
                    code = Task.isCancelled ? 130 : 1
                    continuation.yield(.stderr(seq: 0, data: Data(("adb: " + error.localizedDescription + "\nInterrupted transfers have unknown remote outcomes; inspect before retrying.\n").utf8)))
                }
                continuation.yield(.exit(code: code, signal: Task.isCancelled ? 15 : nil, truncated: false))
            }
            tasks[request.execID] = task
            lock.unlock()
            continuation.onTermination = { termination in if case .cancelled = termination { task.cancel() } }
        }
    }
    private func fileStatus(_ path: String) throws -> Data {
        let (parent, name) = try ADBNativeFiles.parent(path: path, root: transfers)
        defer { close(parent) }
        let value: [String: Any]
        if lock.withLock({ nativeTransfers.contains(path) }) {
            value = ["status": "running", "path": path]
        } else {
            let input = try ADBNativeFiles.input(parent: parent, name: name)
            defer { try? input.close() }
            value = ["status": "saved", "path": path, "size": try input.seekToEnd()]
        }
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        data.append(10)
        return data
    }

    private func transferNative(action: String, local: String, remote: String, endpoint: ADBEndpoint, timeout: TimeInterval) async throws -> UInt64 {
        let admitted = lock.withLock { nativeTransfers.insert(local).inserted }
        guard admitted else { throw ADBFailure("A transfer for this path is already running; use adb stat before retrying", kind: .busy) }
        defer { _ = lock.withLock { nativeTransfers.remove(local) } }
        let (parent, name) = try ADBNativeFiles.parent(path: local, root: transfers)
        defer { close(parent) }
        if action == "push" {
            let input = try ADBNativeFiles.input(parent: parent, name: name)
            defer { try? input.close() }
            let size = try input.seekToEnd(); try input.seek(toOffset: 0)
            let destination = ADBTools.quote(remote)
            let directory = (remote as NSString).deletingLastPathComponent
            let command = "t=$(mktemp " + ADBTools.quote(directory + "/.pdsh-adb-XXXXXX") + ") || exit 1; trap 'rm -f \"$t\"' EXIT; cat >\"$t\" && [ \"$(wc -c <\"$t\")\" -eq \(size) ] && [ ! -d \(destination) ] && mv -f \"$t\" \(destination)"
            let result = try await executor.transfer(endpoint: endpoint, command: command, input: input, output: nil, byteLimit: ADBNativeFiles.limit, timeout: timeout)
            guard result.exitCode == 0 else { throw ADBFailure("ADB push failed: " + String(decoding: result.stderr, as: UTF8.self)) }
            return size
        }
        let temporary = ".adb-" + UUID().uuidString + ".partial"
        let output = try ADBNativeFiles.output(parent: parent, name: temporary)
        defer { try? output.close(); unlinkat(parent, temporary, 0) }
        let source = ADBTools.quote(remote)
        let result = try await executor.transfer(endpoint: endpoint, command: "[ -f \(source) ] && [ ! -L \(source) ] && cat \(source)", input: nil, output: output, byteLimit: ADBNativeFiles.limit, timeout: timeout)
        guard result.exitCode == 0 else { throw ADBFailure("ADB pull failed: " + String(decoding: result.stderr, as: UTF8.self)) }
        try Task.checkCancellation()
        let size = try output.offset()
        guard size <= ADBNativeFiles.limit else { throw ADBFailure("ADB pull exceeds 1 GiB") }
        try output.synchronize()
        guard renameat(parent, temporary, parent, name) == 0 else { throw ADBFailure("Cannot commit downloaded file") }
        return size
    }

    public func cancel(execID: String) async {
        if let task = lock.withLock({ tasks[execID] }) { task.cancel(); await task.value }
        else { await fallback.cancel(execID: execID) }
    }
}
