// SPDX-License-Identifier: MIT
// §3.4 phone ceremony and §4.3 phone enrollment records. One file per device
// fingerprint, atomic replace + fsync under an exclusive lock, read back
// before success. Corrupt files are preserved byte-for-byte and never used.
import Darwin
import Foundation

public enum BLESecureEnrollmentState: String, Sendable, Equatable { case staged, committed, revoked }

public struct BLESecureEnrollmentRecord: Equatable, Sendable {
    public var state: BLESecureEnrollmentState
    /// Bare 64-hex fingerprints.
    public var device: String
    public var phone: String
    public var eid: String
    public var rev: UInt32

    public init(state: BLESecureEnrollmentState, device: String, phone: String, eid: String, rev: UInt32) {
        self.state = state; self.device = device; self.phone = phone; self.eid = eid; self.rev = rev
    }

    public var deviceID: String { BLESecureIdentifiers.deviceID(fingerprint: device) }
    public var phoneID: String { BLESecureIdentifiers.phoneID(fingerprint: phone) }

    /// schema/ble-secure-enrollment-record.schema.json with side "phone".
    public func encoded() -> [UInt8] {
        BLESecureJSON.object([
            .init(name: "v", value: .number("1")), .init(name: "side", value: .string("phone")),
            .init(name: "state", value: .string(state.rawValue)), .init(name: "device", value: .string(deviceID)),
            .init(name: "phone", value: .string(phoneID)), .init(name: "eid", value: .string(eid)),
            .init(name: "rev", value: .number(String(rev))),
        ]).encoded()
    }

    /// Strict closed decoding; any deviation is nil (`record_corrupt`).
    public static func decode(_ bytes: [UInt8], side: String = "phone") -> BLESecureEnrollmentRecord? {
        guard let value = try? BLESecureJSON.parse(bytes), let names = value.memberNames,
              Set(names) == ["v", "side", "state", "device", "phone", "eid", "rev"], names.count == 7,
              value["v"]?.integerValue == 1, value["side"]?.stringValue == side,
              let state = value["state"]?.stringValue.flatMap(BLESecureEnrollmentState.init(rawValue:)),
              let device = value["device"]?.stringValue.flatMap(BLESecureIdentifiers.fingerprint(deviceID:)),
              let phone = value["phone"]?.stringValue.flatMap(BLESecureIdentifiers.fingerprint(phoneID:)),
              let eid = value["eid"]?.stringValue, BLESecureIdentifiers.isEID(eid),
              let rev = value["rev"]?.integerValue, (1...4294967295).contains(rev) else { return nil }
        if side == "board", state == .staged { return nil }
        return BLESecureEnrollmentRecord(state: state, device: device, phone: phone, eid: eid, rev: UInt32(rev))
    }
}

/// The closed §3.4 phone result set.
public enum BLESecureEnrollmentResult: String, Error, Equatable, Sendable {
    case ok, syntax
    case noPhoneKey = "no_phone_key", phoneKeyLost = "phone_key_lost", sameKey = "same_key"
    case occupied, busy, state
    case valueMismatch = "value_mismatch", recordCorrupt = "record_corrupt", storage
}

/// The on-disk file store under `ble-enrollment/v1/`.
public final class BLESecureEnrollmentFileStore: @unchecked Sendable {
    public enum Entry: Equatable, Sendable {
        case record(BLESecureEnrollmentRecord)
        /// Unreadable, malformed, unknown version or name ≠ device; preserved.
        case corrupt
    }

    public let directory: URL
    #if DEBUG
    /// Test seam: the next write fails before replacing the file.
    public var failNextWrite = false
    #endif

    /// `Application Support/phoneDSH/ble-enrollment/v1`.
    public static func defaultDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("phoneDSH/ble-enrollment/v1", isDirectory: true)
    }

    public init(directory: URL) { self.directory = directory }

    private func url(_ device: String) -> URL { directory.appendingPathComponent(device + ".json") }

    public func read(device: String) throws -> Entry? {
        guard BLESecureIdentifiers.isFingerprint(device) else { return nil }
        let path = url(device).path
        var info = stat()
        if lstat(path, &info) != 0 { if errno == ENOENT { return nil }; return .corrupt }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= 4096,
              let data = FileManager.default.contents(atPath: path),
              let record = BLESecureEnrollmentRecord.decode(Array(data)), record.device == device else { return .corrupt }
        return .record(record)
    }

    /// Every device file in the directory (lock files and corrupt-aside copies excluded).
    public func all() throws -> [String: Entry] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [:] }
        var out: [String: Entry] = [:]
        for name in names where name.hasSuffix(".json") && !name.contains(".corrupt-") {
            let device = String(name.dropLast(5))
            guard BLESecureIdentifiers.isFingerprint(device) else { continue }
            out[device] = try read(device: device)
        }
        return out
    }

    /// True if any enrollment file (valid or corrupt) exists.
    public func hasAnyRecord() -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return false }
        return names.contains { $0.hasSuffix(".json") }
    }

    /// Atomic replace with file and directory fsync under the exclusive lock,
    /// then read back and compare.
    public func write(_ record: BLESecureEnrollmentRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = open(directory.appendingPathComponent(".lock").path, O_RDWR | O_CREAT, 0o600)
        guard lock >= 0 else { throw BLESecureEnrollmentResult.storage }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw BLESecureEnrollmentResult.storage }
        defer { flock(lock, LOCK_UN) }
        #if DEBUG
        if failNextWrite { failNextWrite = false; throw BLESecureEnrollmentResult.storage }
        #endif
        let bytes = record.encoded()
        let temp = directory.appendingPathComponent(".\(record.device).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw BLESecureEnrollmentResult.storage }
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        let synced = fsync(fd) == 0
        close(fd)
        guard written == bytes.count, synced, rename(temp.path, url(record.device).path) == 0 else {
            unlink(temp.path)
            throw BLESecureEnrollmentResult.storage
        }
        let dirFD = open(directory.path, O_RDONLY)
        guard dirFD >= 0 else { throw BLESecureEnrollmentResult.storage }
        let dirSynced = fsync(dirFD) == 0
        close(dirFD)
        guard dirSynced, try read(device: record.device) == .record(record) else { throw BLESecureEnrollmentResult.storage }
    }

    /// v2 §3.4: the user-visible label of a committed record, chosen at
    /// confirmation. UI data kept beside the record (`labels/<device>.txt`),
    /// never part of the record schema and never a trust input.
    public func label(device: String) -> String? {
        guard BLESecureIdentifiers.isFingerprint(device),
              let data = FileManager.default.contents(atPath: labelURL(device).path), data.count <= 256 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func writeLabel(device: String, label: String) throws {
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard BLESecureIdentifiers.isFingerprint(device), !text.isEmpty, text.utf8.count <= 256,
              !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { throw BLESecureEnrollmentResult.syntax }
        try FileManager.default.createDirectory(at: labelURL(device).deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try Data(text.utf8).write(to: labelURL(device), options: .atomic) } catch { throw BLESecureEnrollmentResult.storage }
    }

    private func labelURL(_ device: String) -> URL { directory.appendingPathComponent("labels/" + device + ".txt") }

    /// Explicit user recovery only: moves a corrupt file aside to
    /// `<name>.corrupt-<n>` before anything may replace it.
    public func moveCorruptAside(device: String) throws {
        guard try read(device: device) == .corrupt else { throw BLESecureEnrollmentResult.state }
        var n = 1
        while FileManager.default.fileExists(atPath: url(device).path + ".corrupt-\(n)") { n += 1 }
        guard rename(url(device).path, url(device).path + ".corrupt-\(n)") == 0 else { throw BLESecureEnrollmentResult.storage }
    }
}

/// The phone side of the offline ceremony (§3.4) and session eligibility (§4.4).
public final class BLESecureEnrollment: @unchecked Sendable {
    public enum KeyState: Equatable, Sendable {
        case present(String)
        /// No key and no enrollment file.
        case absent
        /// No key while an enrollment file exists: only "reset phone key" leaves it.
        case lost
    }

    public let store: BLESecureEnrollmentFileStore
    public let keys: BLESecurePhoneKeyStore
    /// Called with a device fingerprint before forget/reset writes `revoked`,
    /// so the live session generation is invalidated first (§4.4, §8.4).
    private let invalidateSession: @Sendable (String) -> Void
    private let lock = NSRecursiveLock()

    public init(store: BLESecureEnrollmentFileStore, keys: BLESecurePhoneKeyStore,
                invalidateSession: @escaping @Sendable (String) -> Void = { _ in }) {
        self.store = store
        self.keys = keys
        self.invalidateSession = invalidateSession
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }

    /// A transient key-store error throws (`storage`) and changes nothing.
    public func keyState() throws -> KeyState {
        let key: BLESecurePhoneKey?
        do { key = try keys.load() } catch { throw BLESecureEnrollmentResult.storage }
        if let key { return .present(key.fingerprint) }
        return store.hasAnyRecord() ? .lost : .absent
    }

    private func currentKey() throws -> BLESecurePhoneKey {
        let key: BLESecurePhoneKey?
        do { key = try keys.load() } catch { throw BLESecureEnrollmentResult.storage }
        if let key { return key }
        throw store.hasAnyRecord() ? BLESecureEnrollmentResult.phoneKeyLost : BLESecureEnrollmentResult.noPhoneKey
    }

    /// A record is usable only if well formed and, while committed, bound to the current key.
    private func entry(_ device: String, phone: String?) throws -> BLESecureEnrollmentFileStore.Entry? {
        let e = try store.read(device: device)
        if case .record(let r)? = e, r.state == .committed, let phone, r.phone != phone { return .corrupt }
        return e
    }

    /// The token `pdsh-phone-v1:<fp>`; generates the key the first time.
    public func showToken() -> Result<String, BLESecureEnrollmentResult> {
        locked {
            do {
                switch try keyState() {
                case .present(let fp): return .success(BLESecureIdentifiers.phoneToken(fingerprint: fp))
                case .lost: return .failure(.phoneKeyLost)
                case .absent:
                    let key = try keys.generate()
                    return .success(key.token)
                }
            } catch let r as BLESecureEnrollmentResult { return .failure(r) } catch { return .failure(.storage) }
        }
    }

    public func enterBoardToken(_ input: String) -> BLESecureEnrollmentResult {
        locked {
            guard let (device, eid) = BLESecureIdentifiers.parseBoardToken(input) else { return .syntax }
            return run {
                let key = try currentKey()
                guard device != key.fingerprint else { return .sameKey }
                switch try entry(device, phone: key.fingerprint) {
                case .corrupt?: return .recordCorrupt
                case .record(let r)? where r.state == .committed: return .occupied
                case .record(let r)? where r.state == .staged:
                    return r.eid == eid && r.phone == key.fingerprint ? .ok : .busy
                case .record(let r)?:
                    try store.write(.init(state: .staged, device: device, phone: key.fingerprint, eid: eid, rev: try next(r.rev)))
                case nil:
                    try store.write(.init(state: .staged, device: device, phone: key.fingerprint, eid: eid, rev: 1))
                }
                return .ok
            }
        }
    }

    /// Confirms the staged record of `recordDevice` after the operator
    /// compared the board's printed `committed` values `eid` and `device`.
    public func confirm(recordDevice: String, eid: String, device: String, label: String? = nil) -> BLESecureEnrollmentResult {
        locked {
            run {
                let key = try currentKey()
                guard case let found? = try entry(recordDevice, phone: key.fingerprint) else { return .state }
                guard case .record(let r) = found else { return .recordCorrupt }
                guard r.state == .staged else { return .state }
                guard r.eid == eid, r.device == device, r.phone == key.fingerprint else { return .valueMismatch }
                if let label, (try? store.writeLabel(device: r.device, label: label)) == nil { return .syntax }
                try store.write(.init(state: .committed, device: r.device, phone: r.phone, eid: r.eid, rev: try next(r.rev)))
                return .ok
            }
        }
    }

    public func abort(device: String) -> BLESecureEnrollmentResult { revoke(device: device, allowed: [.staged]) }

    public func forget(device: String) -> BLESecureEnrollmentResult { revoke(device: device, allowed: [.staged, .committed]) }

    private func revoke(device: String, allowed: Set<BLESecureEnrollmentState>) -> BLESecureEnrollmentResult {
        locked {
            run {
                let key = try currentKey()
                guard case let found? = try entry(device, phone: key.fingerprint) else { return .state }
                guard case .record(let r) = found else { return .recordCorrupt }
                guard allowed.contains(r.state) else { return .state }
                invalidateSession(device)
                try store.write(.init(state: .revoked, device: r.device, phone: r.phone, eid: r.eid, rev: try next(r.rev)))
                return .ok
            }
        }
    }

    /// Revokes every staged/committed record, then replaces the key. Required
    /// to leave `phone_key_lost`.
    public func resetPhoneKey() -> BLESecureEnrollmentResult {
        locked {
            run {
                for (device, e) in try store.all() {
                    guard case .record(let r) = e, r.state != .revoked else { continue }
                    invalidateSession(device)
                    try store.write(.init(state: .revoked, device: r.device, phone: r.phone, eid: r.eid, rev: try next(r.rev)))
                }
                do { try keys.delete(); _ = try keys.generate() } catch { return .storage }
                return .ok
            }
        }
    }

    /// §4.4: own key present, record committed and bound to the current key.
    public func sessionEligible(device: String) -> Bool {
        (try? committedRecord(device: device)) != nil
    }

    public func committedRecord(device: String) throws -> BLESecureEnrollmentRecord? {
        try locked {
            guard case .present(let fp) = try keyState(), case .record(let r)? = try entry(device, phone: fp),
                  r.state == .committed else { return nil }
            return r
        }
    }

    public func committedRecords() throws -> [BLESecureEnrollmentRecord] {
        try locked {
            guard case .present(let fp) = try keyState() else { return [] }
            return try store.all().keys.sorted().compactMap { device in
                guard case .record(let r)? = try entry(device, phone: fp), r.state == .committed else { return nil }
                return r
            }
        }
    }

    private func next(_ rev: UInt32) throws -> UInt32 {
        guard rev < UInt32.max else { throw BLESecureEnrollmentResult.storage }
        return rev + 1
    }

    private func run(_ body: () throws -> BLESecureEnrollmentResult) -> BLESecureEnrollmentResult {
        do { return try body() } catch let r as BLESecureEnrollmentResult { return r } catch { return .storage }
    }
}
