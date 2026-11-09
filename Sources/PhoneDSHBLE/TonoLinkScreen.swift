// SPDX-License-Identifier: MIT
// APV1 viewer and decoder ported from xiaozhi-link 2b1babc
// phone-agent/ios/Packages/Capture (AirPlayWire / AirPlayVideoDecoder / AirPlayReceiver / BigStack).
//
// The iPhone mirrors its screen to the board (Control Center → Screen Mirroring → the board's
// USB receiver); the board passes the decrypted H.264/HEVC stream back over USB NCM on
// 192.168.247.1:8769 as APV1 records. This viewer decodes it on the phone itself, so the agent
// sees the real screen with no computer in the loop.
//
// - Handshake: "APVA" + SHA-256(LAN token)[0..<16]; builds without LAN auth accept 16 zero bytes.
// - iOS sends a keyframe only when mirroring starts (and when a viewer rejoins, the board replays
//   its cached GOP), so the viewer stays connected for the life of the app and reconnects on its own.
// - Decoding is software-only: the app runs in the background while the agent drives other apps,
//   and iOS invalidates hardware decoder sessions there (-12903), which would need a new keyframe.
// - APV1 has no capture time. `snapshot(newerThan:)` waits for frames decoded after a given count,
//   which is how the agent knows a screenshot shows the result of its last action.
import CoreGraphics
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import ImageIO
@preconcurrency import Network
import UniformTypeIdentifiers
import VideoToolbox

public enum APV1Codec: UInt8, Sendable { case h264 = 1, hevc = 2 }

public struct APV1Record: Sendable, Equatable {
    public enum Kind: UInt8, Sendable { case configuration = 1, video = 2, reset = 3 }
    public let kind: Kind
    public let codec: APV1Codec
    public let keyframe: Bool
    public let payload: Data
    public init(kind: Kind, codec: APV1Codec, keyframe: Bool = false, payload: Data = Data()) {
        self.kind = kind; self.codec = codec; self.keyframe = keyframe; self.payload = payload
    }
}

public struct APV1Error: Error, CustomStringConvertible, Sendable {
    public let description: String
    public let status: Int32?
    init(_ description: String, status: Int32? = nil) { self.description = description; self.status = status }
}

/// 12-byte header "APV1" kind codec keyframe 0 length(u32 BE), then the payload.
public struct APV1Parser: Sendable {
    public static let maximumPayload = 2 * 1024 * 1024
    private var buffer = Data()
    public init() {}

    public mutating func receive(_ data: Data) throws -> [APV1Record] {
        guard buffer.count + data.count <= Self.maximumPayload + 65536 + 12 else { throw APV1Error("APV1 接收缓冲超限") }
        buffer.append(data)
        var records: [APV1Record] = []
        var offset = 0
        while buffer.count - offset >= 12 {
            let start = buffer.startIndex + offset
            let header = Array(buffer[start..<start + 12])
            guard header[0..<4].elementsEqual([65, 80, 86, 49]),
                  let kind = APV1Record.Kind(rawValue: header[4]),
                  let codec = APV1Codec(rawValue: header[5]), header[6] <= 1, header[7] == 0 else {
                throw APV1Error("无效 APV1 包头")
            }
            let length = header[8..<12].reduce(0) { ($0 << 8) | Int($1) }
            guard length <= Self.maximumPayload, kind == .reset ? length == 0 : length > 0,
                  kind == .video || header[6] == 0 else { throw APV1Error("无效 APV1 包长度或标记") }
            guard buffer.count - offset >= 12 + length else { break }
            records.append(.init(kind: kind, codec: codec, keyframe: header[6] == 1,
                                 payload: Data(buffer[start + 12..<start + 12 + length])))
            offset += 12 + length
        }
        if offset > 0 { buffer = Data(buffer.dropFirst(offset)) }
        return records
    }
}

enum APV1NAL {
    static func split(_ data: Data) throws -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(Int, Int)] = [], index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0 && bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 { starts.append((index, index + 3)); index += 3; continue }
                if index + 3 < bytes.count && bytes[index + 2] == 0 && bytes[index + 3] == 1 {
                    starts.append((index, index + 4)); index += 4; continue
                }
            }
            index += 1
        }
        guard let first = starts.first, bytes[..<first.0].allSatisfy({ $0 == 0 }) else { throw APV1Error("缺少 Annex-B 起始码") }
        return try starts.enumerated().map { i, entry in
            var end = i + 1 < starts.count ? starts[i + 1].0 : bytes.count
            while end > entry.1 && bytes[end - 1] == 0 { end -= 1 }
            guard end > entry.1 else { throw APV1Error("空 NAL") }
            return Data(bytes[entry.1..<end])
        }
    }

    static func type(_ nal: Data, codec: APV1Codec) throws -> Int {
        guard nal.count >= (codec == .hevc ? 3 : 2), nal[nal.startIndex] & 0x80 == 0 else { throw APV1Error("截断或无效 NAL") }
        if codec == .hevc {
            guard nal[nal.startIndex + 1] & 7 != 0, nal[nal.startIndex] & 1 == 0, nal[nal.startIndex + 1] & 0xf8 == 0 else {
                throw APV1Error("不支持的 HEVC 层或时间标记")
            }
            return Int((nal[nal.startIndex] >> 1) & 63)
        }
        return Int(nal[nal.startIndex] & 31)
    }

    static func isParameter(_ type: Int, codec: APV1Codec) -> Bool {
        codec == .hevc ? (32...34).contains(type) : [7, 8].contains(type)
    }

    /// The initial GOP holds several pictures: split at the first slice of each one.
    static func accessUnits(_ nals: [Data], codec: APV1Codec) throws -> [[Data]] {
        var units: [[Data]] = [], current: [Data] = [], hasPicture = false
        for nal in nals {
            let type = try type(nal, codec: codec)
            if isParameter(type, codec: codec) { continue }
            let vcl = codec == .hevc ? type <= 31 : (1...5).contains(type)
            let delimiter = codec == .hevc ? type == 35 : type == 9
            let prefix = codec == .hevc ? type == 39 : type == 6
            let firstSlice = vcl && nal[nal.startIndex + (codec == .hevc ? 2 : 1)] & 0x80 != 0
            if hasPicture && (firstSlice || delimiter || prefix) { units.append(current); current = []; hasPicture = false }
            current.append(nal)
            hasPicture = hasPicture || vcl
        }
        if hasPicture { units.append(current) }
        return units
    }

    static func isKeyframe(_ nals: [Data], codec: APV1Codec) throws -> Bool {
        try nals.contains { nal in
            let type = try type(nal, codec: codec)
            return codec == .hevc ? (16...21).contains(type) : type == 5
        }
    }

    static func lengthPrefixed(_ nals: [Data]) -> Data {
        var result = Data()
        for nal in nals {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(nal)
        }
        return result
    }
}

/// Queue-confined VideoToolbox decoder; the caller serializes configure/decode/reset.
final class APV1Decoder {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var codec: APV1Codec?
    private var parameterSets: [Data] = []
    private var waitingForKeyframe = true
    private var frameNumber: Int64 = 0
    deinit { reset() }

    func reset() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil; format = nil; codec = nil; waitingForKeyframe = true; frameNumber = 0; parameterSets = []
    }

    /// Returns true when the format changed (old pictures are void).
    @discardableResult
    func configure(_ parameters: Data, codec: APV1Codec) throws -> Bool {
        let required = codec == .hevc ? [32, 33, 34] : [7, 8]
        var sets: [Int: Data] = [:]
        for nal in try APV1NAL.split(parameters) {
            let type = try APV1NAL.type(nal, codec: codec)
            if required.contains(type) { sets[type] = nal }
        }
        guard required.allSatisfy({ sets[$0] != nil }) else { throw APV1Error("缺少视频参数集") }
        let normalized = required.map { sets[$0]! }
        // iOS repeats the same parameters around lock/unlock without an IDR: keep the references.
        if session != nil, self.codec == codec, parameterSets == normalized { return false }
        reset()
        let values = normalized.map { $0 as NSData }
        let pointers = values.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
        let sizes = values.map(\.length)
        var description: CMVideoFormatDescription?
        let status = withExtendedLifetime(values) {
            if codec == .hevc {
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault,
                    parameterSetCount: pointers.count, parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
            }
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count, parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, formatDescriptionOut: &description)
        }
        try check(status)
        guard let description else { throw APV1Error("没有视频格式") }
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        guard dimensions.width > 0, dimensions.height > 0, Int64(dimensions.width) * Int64(dimensions.height) <= 4096 * 4096 else {
            throw APV1Error("视频尺寸超限")
        }
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
        try check(VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: description,
            decoderSpecification: [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: false] as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &session))
        format = description; self.codec = codec; parameterSets = normalized
        return true
    }

    func decode(_ payload: Data, codec: APV1Codec, onImage: (CVPixelBuffer) -> Void) throws -> Int {
        guard self.codec == codec, let session, let format else { throw APV1Error("视频到达前缺少匹配的参数集") }
        var count = 0
        for unit in try APV1NAL.accessUnits(APV1NAL.split(payload), codec: codec) {
            if waitingForKeyframe {
                guard try APV1NAL.isKeyframe(unit, codec: codec) else { continue }
                waitingForKeyframe = false
            }
            let bytes = APV1NAL.lengthPrefixed(unit)
            var block: CMBlockBuffer?
            try check(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: bytes.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block))
            guard let block else { throw APV1Error("没有视频缓冲") }
            try bytes.withUnsafeBytes { raw in
                try check(CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count))
            }
            var sample: CMSampleBuffer?, size = bytes.count
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: frameNumber, timescale: 5),
                                            decodeTimeStamp: .invalid)
            frameNumber += 1
            try check(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample))
            guard let sample else { throw APV1Error("没有视频样本") }
            let output = DecodedOutput()
            let result = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                output.set(status, image)
            }
            do {
                try check(result)
                try check(VTDecompressionSessionWaitForAsynchronousFrames(session))
                let (status, image) = output.get()
                try check(status)
                if let image { onImage(image); count += 1 }
            } catch {
                waitingForKeyframe = true   // never continue on dependent pictures after a failed decode
                throw error
            }
        }
        return count
    }

    private func check(_ status: OSStatus) throws {
        if status != noErr { throw APV1Error("VideoToolbox 错误 \(status)", status: status) }
    }
}

/// A decoded picture handed to the conversion thread; nothing mutates it after decoding.
private struct PixelBox: @unchecked Sendable {
    let buffer: CVPixelBuffer
    init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
}

private final class DecodedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var status: OSStatus = noErr
    private var image: CVPixelBuffer?
    func set(_ status: OSStatus, _ image: CVPixelBuffer?) { lock.withLock { self.status = status; self.image = image } }
    func get() -> (OSStatus, CVPixelBuffer?) { lock.withLock { (status, image) } }
}

/// One JPEG of the iPhone screen.
public struct TonoLinkScreenShot: Sendable {
    public let jpeg: Data
    public let width: Int
    public let height: Int
    /// Decoded-frame counter when it was taken (pass to `snapshot(newerThan:)` after an action).
    public let frame: Int
}

public struct TonoLinkScreenStats: Sendable, Codable {
    public var status = "未开始"
    public var codec = ""
    public var connected = false
    public var records = 0
    public var bytes = 0
    public var decodedFrames = 0
    public var width = 0
    public var height = 0
    public var reconnects = 0
    public var resets = 0
    public var lastDecodedAgeMs: Int?
    public var error: String?
}

/// Persistent APV1 viewer on the board's :8769 over USB NCM.
public final class TonoLinkScreen: @unchecked Sendable {
    public static let shared = TonoLinkScreen()

    private let queue = DispatchQueue(label: "dev.phone-dsh.tonolink.screen", qos: .userInitiated)
    private let lock = NSLock()
    // Guarded by `lock`.
    private var stats = TonoLinkScreenStats()
    private var latest: CVPixelBuffer?
    private var lastDecodedAt: TimeInterval?
    // Queue-confined.
    private var connection: NWConnection?
    private var parser = APV1Parser()
    private let decoder = APV1Decoder()
    private var generation = 0
    private var running = false
    private var authDigest = Data(count: 16)

    public init() {}

    public var currentStats: TonoLinkScreenStats {
        lock.withLock {
            var value = stats
            value.lastDecodedAgeMs = lastDecodedAt.map { Int((ProcessInfo.processInfo.systemUptime - $0) * 1000) }
            return value
        }
    }

    /// Starts (or keeps) the viewer. `token` is the board's LAN token when LAN auth is on.
    public func start(token: String? = nil) {
        queue.async { [self] in
            authDigest = token.map { Data(SHA256.hash(data: Data($0.utf8)).prefix(16)) } ?? Data(count: 16)
            guard !running else { return }
            running = true
            connect()
        }
    }

    public func stop() {
        queue.async { [self] in
            running = false
            close()
            update { $0.status = "已停止" }
        }
    }

    /// Drops the connection and rejoins: the board replays its cached GOP to a new viewer.
    public func reconnect() {
        queue.async { [self] in
            guard running else { return }
            update { $0.reconnects += 1 }
            connect()
        }
    }

    private func update(_ body: (inout TonoLinkScreenStats) -> Void) { lock.withLock { body(&stats) } }

    private func connect() {
        close()
        update { $0.status = "连接板子 :8769…"; $0.error = nil }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.prohibitedInterfaceTypes = [.wifi, .cellular]   // the board is only on USB NCM
        let conn = NWConnection(host: NWEndpoint.Host(TonoLinkUSB.host), port: 8769, using: parameters)
        connection = conn
        let current = generation
        conn.stateUpdateHandler = { [weak self] state in
            guard let self, self.generation == current else { return }
            switch state {
            case .ready:
                var hello = Data("APVA".utf8); hello.append(self.authDigest)
                conn.send(content: hello, completion: .contentProcessed { _ in })
                self.update { $0.connected = true; $0.status = "已连接，等待画面（需先在控制中心开启屏幕镜像）" }
                self.receive(current)
            case .waiting(let error): self.fail("等待 USB 网络：\(error)")
            case .failed(let error): self.fail("连接失败：\(error)")
            default: break
            }
        }
        conn.start(queue: queue)
    }

    private func receive(_ current: Int) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self, self.generation == current else { return }
            do {
                if let data { for record in try self.parser.receive(data) { try self.consume(record) } }
                if done || error != nil { self.fail("视频连接中断") } else { self.receive(current) }
            } catch { self.fail(String(describing: error)) }
        }
    }

    private func consume(_ record: APV1Record) throws {
        update { $0.records += 1; $0.bytes += record.payload.count }
        switch record.kind {
        case .reset:
            decoder.reset()
            lock.withLock { latest = nil; lastDecodedAt = nil; stats.resets += 1; stats.status = "投屏已结束，等待新的投屏" }
        case .configuration:
            if try decoder.configure(record.payload, codec: record.codec) {
                lock.withLock { latest = nil; lastDecodedAt = nil; stats.status = "等待关键帧" }
            }
            update { $0.codec = record.codec == .hevc ? "HEVC" : "H.264" }
        case .video:
            do {
                _ = try decoder.decode(record.payload, codec: record.codec) { [self] image in
                    lock.withLock {
                        latest = image
                        lastDecodedAt = ProcessInfo.processInfo.systemUptime
                        stats.decodedFrames += 1
                        stats.width = CVPixelBufferGetWidth(image); stats.height = CVPixelBufferGetHeight(image)
                        stats.status = "正在接收画面"
                    }
                }
            } catch let error as APV1Error where error.status != nil {
                // A decode error waits for the next keyframe; rejoining makes the board replay its GOP.
                update { $0.error = error.description }
                queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.reconnect() }
            }
        }
    }

    private func close() {
        generation += 1
        connection?.stateUpdateHandler = nil
        connection?.cancel(); connection = nil
        parser = APV1Parser()
        decoder.reset()
        update { $0.connected = false }
    }

    private func fail(_ reason: String) {
        close()
        update { $0.status = "视频连接中断，自动重连"; $0.error = reason }
        guard running else { return }
        let current = generation
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.running, self.generation == current else { return }
            self.update { $0.reconnects += 1 }
            self.connect()
        }
    }

    /// The latest screen as JPEG (long side ≤ `maxLongSide`). With `newerThan`, waits until at least
    /// `fresh` more frames were decoded (the decoder lags a few frames behind the screen), or until
    /// `timeout` passes — iOS sends no frames while the screen is still, and then the last one is current.
    public func snapshot(newerThan frame: Int? = nil, fresh: Int = 6, timeout: Duration = .seconds(3),
                         maxLongSide: Int = 1280, quality: Double = 0.8) async throws -> TonoLinkScreenShot {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        if let frame {
            while clock.now < deadline, currentStats.decodedFrames < frame + fresh {
                try await Task.sleep(for: .milliseconds(80))
            }
        }
        let (buffer, count) = lock.withLock { (latest, stats.decodedFrames) }
        guard let buffer else {
            throw APV1Error(currentStats.connected ? "还没有画面：请在控制中心 → 屏幕镜像里选择板子" : "没有连上板子的视频通道（USB）")
        }
        let box = PixelBox(buffer)
        let jpeg = try await Self.onBigStack { try Self.jpeg(from: box.buffer, maxLongSide: maxLongSide, quality: quality) }
        return TonoLinkScreenShot(jpeg: jpeg.data, width: jpeg.width, height: jpeg.height, frame: count)
    }

    /// Frames decoded so far (mark this before an action).
    public var frameCount: Int { lock.withLock { stats.decodedFrames } }

    static func jpeg(from buffer: CVPixelBuffer, maxLongSide: Int, quality: Double) throws -> (data: Data, width: Int, height: Int) {
        var source: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &source) == noErr, let source else {
            throw APV1Error("画面转换失败")
        }
        let longSide = max(source.width, source.height)
        let scale = longSide > maxLongSide ? Double(maxLongSide) / Double(longSide) : 1
        let width = max(1, Int((Double(source.width) * scale).rounded())), height = max(1, Int((Double(source.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw APV1Error("画面转换失败")
        }
        ctx.interpolationQuality = .high
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else { throw APV1Error("画面转换失败") }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { throw APV1Error("JPEG 编码失败") }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw APV1Error("JPEG 编码失败") }
        return (out as Data, width, height)
    }

    /// CoreGraphics colour conversion needs more stack than a GCD or Swift-concurrency thread has
    /// (xiaozhi-link saw EXC_BAD_ACCESS in vImage after ~20 min of mirroring): run it on an 8 MB thread.
    static func onBigStack<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread { continuation.resume(with: Result { try body() }) }
            thread.stackSize = 8 << 20
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }
}
