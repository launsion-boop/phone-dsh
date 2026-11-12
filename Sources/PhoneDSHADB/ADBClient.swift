// SPDX-License-Identifier: MIT
import Foundation

public struct ADBEndpoint: Codable, Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public init(host: String, port: UInt16 = 5555) throws {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host.count <= 253, port > 0,
              !host.contains(where: { $0.isWhitespace || "/\\@?#".contains($0) }) else {
            throw ADBFailure("Enter an Android IP address or hostname and a port from 1 to 65535")
        }
        self.host = host; self.port = port
    }
}

public protocol ADBCommandExecuting: Sendable {
    func transfer(endpoint: ADBEndpoint, command: String, input: FileHandle?, output: FileHandle?, byteLimit: Int, timeout: TimeInterval) async throws -> ADBShellResult
    func shell(endpoint: ADBEndpoint, command: String, timeout: TimeInterval, outputLimit: Int) async throws -> ADBShellResult
    func shell(endpoint: ADBEndpoint, command: String, stdin: Data, timeout: TimeInterval, outputLimit: Int) async throws -> ADBShellResult
}

public extension ADBCommandExecuting {
    func transfer(endpoint: ADBEndpoint, command: String, input: FileHandle?, output: FileHandle?, byteLimit: Int, timeout: TimeInterval) async throws -> ADBShellResult {
        throw ADBFailure("This ADB executor does not support streaming file transfers")
    }
    func shell(endpoint: ADBEndpoint, command: String, stdin: Data, timeout: TimeInterval, outputLimit: Int) async throws -> ADBShellResult {
        throw ADBFailure("This ADB executor does not support stdin streaming")
    }
}

/// Each command owns its TCP connection. Cancellation/timeout closes that
/// connection; commands are never retried after OPEN because they may mutate.
public struct ADBClient: ADBCommandExecuting, Sendable {
    public init() {}
    public func transfer(endpoint: ADBEndpoint, command: String, input: FileHandle?, output: FileHandle?, byteLimit: Int, timeout: TimeInterval) async throws -> ADBShellResult {
        let identity = try ADBIdentity.loadOrCreate()
        return try await Self.shell(transport: ADBTCPTransport(host: endpoint.host, port: endpoint.port), identity: identity,
                                    command: command, timeout: timeout, outputLimit: output == nil ? 65536 : byteLimit,
                                    inputFile: input, outputFile: output)
    }
    public func shell(endpoint: ADBEndpoint, command: String, timeout: TimeInterval = 30,
                      outputLimit: Int = 8 * 1024 * 1024) async throws -> ADBShellResult {
        try await shell(endpoint: endpoint, command: command, stdin: Data(), timeout: timeout, outputLimit: outputLimit)
    }

    public func shell(endpoint: ADBEndpoint, command: String, stdin: Data, timeout: TimeInterval,
                      outputLimit: Int) async throws -> ADBShellResult {
        let identity = try ADBIdentity.loadOrCreate()
        return try await Self.shell(transport: ADBTCPTransport(host: endpoint.host, port: endpoint.port),
                                    identity: identity, command: command, stdin: stdin, timeout: timeout, outputLimit: outputLimit)
    }

    static func shell(transport: any ADBTransport, identity: ADBIdentity, command: String, stdin: Data = Data(),
                      timeout: TimeInterval, outputLimit: Int, inputFile: FileHandle? = nil, outputFile: FileHandle? = nil) async throws -> ADBShellResult {
        do {
            return try await runShell(transport: transport, identity: identity, command: command, stdin: stdin,
                                      timeout: timeout, outputLimit: outputLimit, inputFile: inputFile, outputFile: outputFile)
        } catch {
            throw shellFailure(error)
        }
    }

    /// Tags failures that escape the framing layer. Explicit kinds are kept and
    /// existing messages are preserved; cancellation gets a stable description.
    private static func shellFailure(_ error: Error) -> Error {
        if let failure = error as? ADBFailure {
            if failure.kind == .device, Task.isCancelled {
                return ADBFailure(failure.message, kind: .cancelled)
            }
            return failure
        }
        if error is CancellationError || Task.isCancelled {
            return ADBFailure("ADB command cancelled", kind: .cancelled)
        }
        return error
    }

    private static func runShell(transport: any ADBTransport, identity: ADBIdentity, command: String, stdin: Data,
                                 timeout: TimeInterval, outputLimit: Int, inputFile: FileHandle?,
                                 outputFile: FileHandle?) async throws -> ADBShellResult {
        try Task.checkCancellation()
        let inputSize: Int
        if let inputFile {
            let size = try inputFile.seekToEnd()
            guard size <= 1_073_741_824 else { throw ADBFailure("ADB input exceeds 1 GiB") }
            try inputFile.seek(toOffset: 0); inputSize = Int(size)
        } else { inputSize = stdin.count }
        guard !command.utf8.contains(0), command.utf8.count < 3800,
              stdin.count <= 128 * 1024 * 1024,
              timeout.isFinite, (0.1...3600).contains(timeout), (1...1_073_741_824).contains(outputLimit) else {
            throw ADBFailure("Invalid ADB command or execution limits")
        }
        let timer = Task {
            do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)); transport.close() }
            catch {}
        }
        defer { timer.cancel(); transport.close() }
        try await transport.start()
        try await transport.write(ADBPacket(command: ADBPacket.connect, arg0: 0x01000000, arg1: 4096,
                                            payload: Data("host::features=shell_v2;\0".utf8)).encoded)
        var authStep = 0
        while true {
            let packet: ADBPacket
            do {
                packet = try await ADBPacket.read(from: transport)
            } catch let failure as ADBFailure where authStep > 0 && failure.kind == .unreachable && !Task.isCancelled {
                throw ADBFailure(failure.message, kind: .unauthorized)
            }
            if packet.command == ADBPacket.connect {
                let banner = String(decoding: packet.payload, as: UTF8.self)
                let features = banner.components(separatedBy: "features=").dropFirst().first?
                    .split(whereSeparator: { $0 == ";" || $0 == "\0" }).first?
                    .split(separator: ",") ?? []
                guard features.contains("shell_v2") else { throw ADBFailure("Android does not advertise shell_v2 (Android 7+ required)", kind: .protocolViolation) }
                guard packet.arg1 >= 4096 else { throw ADBFailure("Unsupported ADB packet limit", kind: .protocolViolation) }
                break
            }
            if packet.command == ADBPacket.tls {
                throw ADBFailure("TLS wireless-debugging ports are not supported; use the Android TCP/IP ADB port, usually 5555")
            }
            guard packet.command == ADBPacket.auth, packet.arg0 == 1, authStep < 2 else {
                throw ADBFailure("ADB authorization refused; unlock Android and accept this iPhone's debugging key", kind: .unauthorized)
            }
            let data = authStep == 0 ? try identity.sign(packet.payload) : try identity.publicKey()
            try await transport.write(ADBPacket(command: ADBPacket.auth, arg0: authStep == 0 ? 2 : 3, payload: data).encoded)
            authStep += 1
        }
        try Task.checkCancellation()
        try await transport.write(ADBPacket(command: ADBPacket.open, arg0: 1,
                                            payload: Data(("shell,v2,raw:" + command + "\0").utf8)).encoded)
        let opened = try await ADBPacket.read(from: transport)
        guard opened.command == ADBPacket.okay, opened.arg1 == 1, opened.arg0 != 0 else {
            throw ADBFailure("Android refused the shell service")
        }
        let remote = opened.arg0
        // One unacknowledged WRTE at a time. Continue consuming output while
        // uploading: pm can reject an APK before consuming all its bytes.
        var inputOffset = 0
        var inputClosed = false
        func sendInput() async throws {
            var frame: Data
            if inputOffset < inputSize {
                let count = min(4091, inputSize - inputOffset)
                frame = Data([0]); frame.appendLE(UInt32(count))
                let start = stdin.startIndex + inputOffset
                if let inputFile {
                    let bytes = try inputFile.read(upToCount: count) ?? Data()
                    guard bytes.count == count else { throw ADBFailure("Input file changed during upload") }
                    frame.append(bytes)
                } else { frame.append(stdin.subdata(in: start..<(start + count))) }
                inputOffset += count
            } else {
                frame = Data([4]); frame.appendLE(0); inputClosed = true
            }
            try await transport.write(ADBPacket(command: ADBPacket.write, arg0: 1, arg1: remote, payload: frame).encoded)
        }
        try await sendInput()
        var decoder = ADBShellDecoder(limit: outputLimit)
        var outputBytes = 0
        while true {
            try Task.checkCancellation()
            let packet = try await ADBPacket.read(from: transport)
            guard packet.arg0 == remote, packet.arg1 == 1 else { throw ADBFailure("ADB stream identity mismatch", kind: .protocolViolation) }
            switch packet.command {
            case ADBPacket.write:
                try decoder.append(packet.payload)
                if let outputFile {
                    let bytes = decoder.takeStdout()
                    outputBytes += bytes.count
                    guard outputBytes <= outputLimit else { throw ADBFailure("ADB output exceeds transfer limit") }
                    guard decoder.result.stderr.count <= 65536 else { throw ADBFailure("ADB stderr exceeds limit") }
                    try outputFile.write(contentsOf: bytes)
                }
                try await transport.write(ADBPacket(command: ADBPacket.okay, arg0: 1, arg1: remote).encoded)
            case ADBPacket.close:
                try await transport.write(ADBPacket(command: ADBPacket.close, arg0: 1, arg1: remote).encoded)
                let result = try decoder.finish()
                guard result.exitCode != 0 || inputOffset == inputSize else {
                    throw ADBFailure("Android exited before receiving the entire input")
                }
                return result
            case ADBPacket.okay:
                if !inputClosed && !decoder.exited { try await sendInput() }
            default: throw ADBFailure("Unexpected ADB stream packet", kind: .protocolViolation)
            }
        }
    }
}
