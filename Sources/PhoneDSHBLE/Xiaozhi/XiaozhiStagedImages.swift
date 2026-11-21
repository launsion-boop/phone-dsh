// SPDX-License-Identifier: MIT
// phone-dsh — PhoneDSHBLE/Xiaozhi: in-memory staged firmware images and device
// records (spec/device/v1/xiaozhi-firmware.md §2.4, §2.5, §3). Nothing is persisted.
#if DEBUG
import CryptoKit
import Foundation

public struct XiaozhiStagedImage: Equatable, Sendable {
    public let mac: String
    public let imageData: Data
    /// SHA-256 of `imageData`, 64 lowercase hex.
    public let sha256: String
    /// SHA-256 of the ELF the image was built from, 64 lowercase hex.
    public let elfSha256: String

    public var rewriteInput: XiaozhiOTARewrite.Staged { (mac, sha256, elfSha256) }
}

/// At most one staged image per MAC; staging again replaces the earlier one.
public final class XiaozhiStagedImages: @unchecked Sendable {
    private let lock = NSLock()
    private var byMAC: [String: XiaozhiStagedImage] = [:]

    public init() {}

    /// Returns nil when `mac` or `elfSha256` is not in its canonical lowercase form.
    @discardableResult
    public func stage(mac: String, imageData: Data, elfSha256: String) -> XiaozhiStagedImage? {
        guard XiaozhiDeviceReport.normalizedMAC(mac) == mac, XiaozhiDeviceReport.isLowerHex64(elfSha256) else { return nil }
        let digest = SHA256.hash(data: imageData).map { String(format: "%02x", $0) }.joined()
        let image = XiaozhiStagedImage(mac: mac, imageData: imageData, sha256: digest, elfSha256: elfSha256)
        lock.lock(); defer { lock.unlock() }
        byMAC[mac] = image
        return image
    }

    public func staged(forMAC mac: String) -> XiaozhiStagedImage? {
        lock.lock(); defer { lock.unlock() }
        return byMAC[mac.lowercased()]
    }

    public func image(sha256: String) -> XiaozhiStagedImage? {
        lock.lock(); defer { lock.unlock() }
        return byMAC.values.first { $0.sha256 == sha256 }
    }

    public func clear(mac: String) {
        lock.lock(); defer { lock.unlock() }
        byMAC[mac.lowercased()] = nil
    }
}

/// One firmware download the relay served (§2.5), for the progress UI only: it never changes a
/// response, a rewrite decision or a device record, and nothing reads it back into the protocol.
public struct XiaozhiDownload: Equatable, Sendable {
    public enum State: String, Equatable, Sendable { case sending, complete, aborted }
    /// Image SHA-256 that was requested.
    public var sha256: String
    /// The MAC the image is staged for.
    public var mac: String
    /// Body bytes acknowledged by the local TCP stack so far (not proof the board wrote them).
    public var sent: Int
    public var total: Int
    public var startedAt: Date
    public var updatedAt: Date
    public var state: State
}

/// Latest download per MAC. Lost when the app quits.
public final class XiaozhiDownloads: @unchecked Sendable {
    private let lock = NSLock()
    private var byMAC: [String: XiaozhiDownload] = [:]

    public init() {}

    public func begin(sha256: String, mac: String, total: Int, at date: Date) {
        lock.lock(); defer { lock.unlock() }
        byMAC[mac] = XiaozhiDownload(sha256: sha256, mac: mac, sent: 0, total: total,
                                     startedAt: date, updatedAt: date, state: total == 0 ? .complete : .sending)
    }

    /// Records progress of the download started at `startedAt`; a newer download for the MAC wins.
    public func update(mac: String, startedAt: Date, sent: Int, state: XiaozhiDownload.State, at date: Date) {
        lock.lock(); defer { lock.unlock() }
        guard var download = byMAC[mac], download.startedAt == startedAt, download.state == .sending else { return }
        download.sent = min(max(download.sent, sent), download.total)
        download.state = state
        download.updatedAt = date
        byMAC[mac] = download
    }

    public func latest(forMAC mac: String) -> XiaozhiDownload? {
        lock.lock(); defer { lock.unlock() }
        return byMAC[mac.lowercased()]
    }
}

public enum XiaozhiRelayDecision: String, Equatable, Sendable {
    case passthrough, hold, offer
    case upstreamFailed = "upstream_failed"
}

public struct XiaozhiDeviceRecord: Equatable, Sendable {
    public var mac: String
    public var version: String?
    public var elfSha256: String?
    /// Shown in the UI only; never put into Bot text.
    public var boardType: String?
    public var lastSeen: Date
    public var lastDecision: XiaozhiRelayDecision
}

/// Per-MAC record of the latest version check. Lost when the app quits.
public final class XiaozhiDeviceRecords: @unchecked Sendable {
    private let lock = NSLock()
    private var byMAC: [String: XiaozhiDeviceRecord] = [:]
    private var changeHandler: (@Sendable (XiaozhiDeviceRecord) -> Void)?

    public init() {}

    /// Called after every update, on the thread that recorded it.
    public func setOnChange(_ handler: (@Sendable (XiaozhiDeviceRecord) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        changeHandler = handler
    }

    /// A report without a valid MAC is not recorded.
    public func record(report: XiaozhiDeviceReport, at date: Date, decision: XiaozhiRelayDecision) {
        guard let mac = report.mac else { return }
        let record = XiaozhiDeviceRecord(mac: mac, version: report.version, elfSha256: report.elfSha256,
                                         boardType: report.boardType, lastSeen: date, lastDecision: decision)
        lock.lock()
        byMAC[mac] = record
        let callback = changeHandler
        lock.unlock()
        callback?(record)
    }

    public func record(forMAC mac: String) -> XiaozhiDeviceRecord? {
        lock.lock(); defer { lock.unlock() }
        return byMAC[mac.lowercased()]
    }

    public var all: [XiaozhiDeviceRecord] {
        lock.lock(); defer { lock.unlock() }
        return byMAC.values.sorted { $0.mac < $1.mac }
    }
}
#endif
