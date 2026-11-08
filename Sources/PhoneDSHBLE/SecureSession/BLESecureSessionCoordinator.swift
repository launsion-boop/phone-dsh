// SPDX-License-Identifier: MIT
// secure-session-v2 §3.4, §8.2: ties the phone enrollment records, the
// user's device selection, BLEDeviceStore's connection ownership and one
// BLESecurePhoneGeneration / BLESecureTaskIntake together for the UI.
//
// Shipping builds never reach task intake: `grant` first calls
// BLEDeviceStore.grantDeviceTasks(enabled: true), which refuses in every
// build of this package until the spec's §14 acceptance is recorded (GAP-16).
import Foundation
import Observation
import PhoneDSHDeviceTasks

@MainActor @Observable public final class BLESecureSessionCoordinator {
    public static let shared = BLESecureSessionCoordinator()

    public struct Selection: Equatable, Sendable {
        public let peripheral: UUID
        public let record: BLESecureEnrollmentRecord
        public let label: String
        public var deviceID: String { record.deviceID }
    }

    public enum SessionPhase: String, Sendable {
        case idle, opening, ready, closed, granted, ended
    }

    public let enrollment: BLESecureEnrollment
    @ObservationIgnored private let store: BLEDeviceStore
    public private(set) var selection: Selection?
    public private(set) var phase: SessionPhase = .idle
    public private(set) var message = ""
    public private(set) var notices: [String] = []
    /// Bumped whenever enrollment records may have changed (UI refresh).
    public private(set) var recordsRevision = 0
    @ObservationIgnored private var generation: BLESecurePhoneGeneration?
    /// The store's connection-generation token the generation was built on.
    @ObservationIgnored private var connection: BLESecureLease?
    /// A connection whose generation already ended (background, revoke):
    /// never reused for a new generation; the user reconnects (§8.2).
    @ObservationIgnored private weak var spentConnection: BLESecureLease?
    /// Invalidated synchronously whenever this coordinator ends the generation.
    @ObservationIgnored private var generationLease: BLESecureLease?
    /// The selected record; invalidated synchronously by forget / reset.
    @ObservationIgnored private var recordLease: BLESecureLease?
    @ObservationIgnored private var intake: BLESecureTaskIntake?
    @ObservationIgnored private var foreground = true
    @ObservationIgnored private var timing: BLESecureTaskIntake.Timing
    @ObservationIgnored private var generationTimers: BLESecurePhoneGeneration.Timers

    /// Thread-safe hand-off from the enrollment callback (any thread).
    private final class Box: @unchecked Sendable {
        weak var coordinator: BLESecureSessionCoordinator?
        private let lock = NSLock()
        private var lease: BLESecureLease?
        func setRecordLease(_ lease: BLESecureLease?) { lock.lock(); self.lease = lease; lock.unlock() }
        /// Synchronous: the selected record stops being current before
        /// `revoked` is written; MainActor teardown follows.
        func invalidated(_ device: String) {
            lock.lock(); let lease = self.lease; lock.unlock()
            guard let lease, lease.device == device else { return }
            lease.invalidate()
            Task { @MainActor [weak coordinator] in coordinator?.recordInvalidated(lease) }
        }
    }
    @ObservationIgnored private let box: Box

    public convenience init() {
        let directory = (try? BLESecureEnrollmentFileStore.defaultDirectory())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("pdsh-ble-enrollment-unavailable", isDirectory: true)
        self.init(store: .shared, records: BLESecureEnrollmentFileStore(directory: directory), keys: BLESecureKeychainKeyStore())
    }

    public init(store: BLEDeviceStore, records: BLESecureEnrollmentFileStore, keys: BLESecurePhoneKeyStore,
                timing: BLESecureTaskIntake.Timing = .init(), generationTimers: BLESecurePhoneGeneration.Timers = .init()) {
        let box = Box()
        self.box = box
        self.store = store
        self.timing = timing
        self.generationTimers = generationTimers
        // §3.4 forget / reset phone key: the live generation is invalidated
        // synchronously before `revoked` is written; teardown follows.
        self.enrollment = BLESecureEnrollment(store: records, keys: keys, invalidateSession: { device in
            box.invalidated(device)
        })
        box.coordinator = self
    }

    // MARK: enrollment (§3.4)

    public struct KeyInfo: Equatable, Sendable {
        public enum State: Equatable, Sendable { case absent, present, lost, unavailable }
        public let state: State
        public let token: String?
        public let hardwareBacked: Bool
    }

    /// Inspects the phone key without generating one.
    public func keyInfo() -> KeyInfo {
        guard let state = try? enrollment.keyState() else { return KeyInfo(state: .unavailable, token: nil, hardwareBacked: false) }
        switch state {
        case .absent: return KeyInfo(state: .absent, token: nil, hardwareBacked: false)
        case .lost: return KeyInfo(state: .lost, token: nil, hardwareBacked: false)
        case .present(let fp):
            let hardware = (try? enrollment.keys.load())?.isHardwareBacked ?? false
            return KeyInfo(state: .present, token: BLESecureIdentifiers.phoneToken(fingerprint: fp), hardwareBacked: hardware)
        }
    }

    /// Shows the phone token, generating the key (Secure Enclave when
    /// available) the first time.
    public func showPhoneToken() -> Result<String, BLESecureEnrollmentResult> {
        defer { recordsRevision += 1 }
        return enrollment.showToken()
    }

    public struct RecordRow: Identifiable, Equatable, Sendable {
        public var id: String { device }
        public let device: String
        public let record: BLESecureEnrollmentRecord?
        public let label: String?
        public var corrupt: Bool { record == nil }
    }

    public func records() -> [RecordRow] {
        _ = recordsRevision
        let all = (try? enrollment.store.all()) ?? [:]
        return all.keys.sorted().map { device in
            switch all[device] {
            case .record(let r)?: return RecordRow(device: device, record: r, label: enrollment.store.label(device: device))
            default: return RecordRow(device: device, record: nil, label: nil)
            }
        }
    }

    private func changed(_ result: BLESecureEnrollmentResult) -> BLESecureEnrollmentResult {
        recordsRevision += 1
        return result
    }

    public func enterBoardToken(_ input: String) -> BLESecureEnrollmentResult { changed(enrollment.enterBoardToken(input)) }

    public func confirm(device: String, eid: String, label: String) -> BLESecureEnrollmentResult {
        changed(enrollment.confirm(recordDevice: device, eid: eid, device: device, label: label))
    }

    public func abort(device: String) -> BLESecureEnrollmentResult { changed(enrollment.abort(device: device)) }

    public func forget(device: String) -> BLESecureEnrollmentResult { changed(enrollment.forget(device: device)) }

    public func resetPhoneKey() -> BLESecureEnrollmentResult { changed(enrollment.resetPhoneKey()) }

    public func moveCorruptAside(device: String) -> BLESecureEnrollmentResult {
        do { try enrollment.store.moveCorruptAside(device: device); return changed(.ok) }
        catch let r as BLESecureEnrollmentResult { return changed(r) } catch { return changed(.storage) }
    }

    /// Renames a committed record's label (UI data, never a trust input).
    public func setLabel(device: String, label: String) -> BLESecureEnrollmentResult {
        guard case .record(let r)? = try? enrollment.store.read(device: device), r.state == .committed else { return .state }
        do { try enrollment.store.writeLabel(device: device, label: label); return changed(.ok) }
        catch let r as BLESecureEnrollmentResult { return changed(r) } catch { return changed(.storage) }
    }

    // MARK: device selection (§8.2 M1)

    /// Selects one committed record for the next connection to `peripheral`.
    /// The peripheral must not be connected yet; a live generation of an
    /// earlier selection ends first.
    @discardableResult public func select(peripheral: UUID, device: String) -> Bool {
        guard let record = try? enrollment.committedRecord(device: device),
              let device = store.devices.first(where: { $0.id == peripheral }), device.state == "未连接" else {
            message = "只能在连接前选择一个已完成配对的设备"
            return false
        }
        endGeneration(.recordChanged)
        guard store.selectSecureDevice(peripheral, device: record.device) else { return false }
        let label = enrollment.store.label(device: record.device) ?? "未命名设备"
        selection = Selection(peripheral: peripheral, record: record, label: label)
        recordLease = BLESecureLease(peripheral: peripheral, device: record.device)
        box.setRecordLease(recordLease)
        phase = .idle
        message = ""
        return true
    }

    public func clearSelection() {
        endGeneration(.recordChanged)
        if let selection { store.selectSecureDevice(selection.peripheral, device: nil) }
        selection = nil
        recordLease = nil
        box.setRecordLease(nil)
        phase = .idle
    }

    // MARK: sessions and grant (§8.2)

    /// Opens the first session of the current connection generation (no
    /// grant). Readiness is shown; it is not permission.
    public func openSession() async {
        guard foreground, let selection, let recordLease, recordLease.isValid else { message = "请先选择设备"; return }
        guard let lease = store.secureLease(selection.peripheral) else { message = "安全会话服务尚不可用"; return }
        do {
            let intake = try prepare(selection: selection, lease: lease, recordLease: recordLease)
            phase = .opening
            try await intake.openInitialSession()
            guard self.intake === intake else { return }
            phase = .ready
            message = "安全会话已就绪：\(selection.label) · \(selection.deviceID)"
        } catch {
            if lease.isValid, self.connection === lease { phase = .closed }
            message = "安全会话未就绪：\(error)"
        }
    }

    private func prepare(selection: Selection, lease: BLESecureLease,
                         recordLease: BLESecureLease) throws -> BLESecureTaskIntake {
        if let intake, connection === lease, generationLease?.isValid == true { return intake }
        guard spentConnection !== lease else { throw BLEFailure("本次连接的安全会话已结束，请断开后重新连接") }
        endGeneration(.disconnect)
        guard let key = try enrollment.keys.load() else { throw BLESecureEnrollmentResult.noPhoneKey }
        let record = selection.record
        let enrollment = self.enrollment
        let local = BLESecureLease(peripheral: selection.peripheral, device: record.device)
        let generation = try BLESecurePhoneGeneration(
            key: key, selected: record, timers: generationTimers,
            isCurrent: { lease.isValid && local.isValid },
            recordStillCurrent: {
                recordLease.isValid && (try? enrollment.committedRecord(device: record.device)) == record
                    && (try? enrollment.keys.load())?.fingerprint == key.fingerprint
            })
        let store = self.store
        let peripheral = selection.peripheral
        let intake = BLESecureTaskIntake(
            generation: generation, deviceID: record.deviceID, phoneID: key.phoneID, timing: timing,
            openStream: { try await store.openSecureStream(peripheral, lease: lease) })
        lease.onInvalidate { [weak self] in Task { @MainActor in self?.connectionEnded(lease) } }
        self.generation = generation
        self.connection = lease
        self.generationLease = local
        self.intake = intake
        return intake
    }

    /// The foreground user grant. The store's gate decides first; it refuses
    /// in every build of this package, so shipping builds never reach intake.
    public func grant(executor: DeviceTaskExecutor) async throws {
        guard foreground, let selection, let connection, let generation, let intake,
              connection.isValid, !(await generation.isEnded) else { throw BLEFailure("安全会话未就绪，不能授权") }
        try store.grantDeviceTasks(selection.peripheral, enabled: true)
        guard store.secureGrantAdmitted(selection.peripheral, lease: connection), self.intake === intake else {
            throw BLEFailure("安全会话未就绪，不能授权")
        }
        try await intake.grant(executor: executor)
        guard self.intake === intake else { throw BLEFailure("连接已变化") }
        phase = .granted
        message = "已授权 \(selection.label)（\(selection.deviceID)）在本次连接中派任务"
        await intake.start { [weak self] reason in await self?.intakeStopped(intake, reason) }
    }

    /// User revocation: ends the grant and the generation (§8.2).
    public func revoke() {
        if let selection { try? store.grantDeviceTasks(selection.peripheral, enabled: false) }
        endGeneration(.userRevoked)
        phase = .ended
        message = "已撤销授权；如需继续，请重新连接"
    }

    public func sceneActive(_ active: Bool) {
        foreground = active
        guard !active else { return }
        if let selection { try? store.grantDeviceTasks(selection.peripheral, enabled: false) }
        if generation != nil {
            phase = .ended
            message = "应用进入后台，安全会话和授权已结束；请断开后重新连接"
        }
        endGeneration(.background)
    }

    private func intakeStopped(_ intake: BLESecureTaskIntake, _ reason: BLESecureTaskIntake.StopReason) {
        guard self.intake === intake else { return }
        Task { notices = await intake.notices }
        if let selection { try? store.grantDeviceTasks(selection.peripheral, enabled: false) }
        phase = .ended
        message = "设备任务已停止（\(reason.rawValue)）；请重新连接并授权"
    }

    private func connectionEnded(_ lease: BLESecureLease) {
        guard connection === lease else { return }
        endGeneration(.disconnect)
        phase = .ended
        message = "连接已结束，安全会话和授权已失效"
    }

    /// Forget / reset invalidated the selected record (its lease is already
    /// invalid, so the generation can no longer act).
    private func recordInvalidated(_ lease: BLESecureLease) {
        guard recordLease === lease else { return }
        endGeneration(.forget)
        if let selection { store.selectSecureDevice(selection.peripheral, device: nil) }
        selection = nil
        recordLease = nil
        box.setRecordLease(nil)
        phase = .ended
        message = "已忘记该设备，安全会话已结束"
    }

    private func endGeneration(_ reason: BLESecurePhoneSessionCore.GenerationEnd) {
        let generation = self.generation, intake = self.intake
        // §8.4: invalidated before any asynchronous teardown.
        generationLease?.invalidate()
        if let connection { spentConnection = connection }
        self.generation = nil; self.intake = nil; self.connection = nil; self.generationLease = nil
        if let selection { try? store.grantDeviceTasks(selection.peripheral, enabled: false) }
        guard generation != nil || intake != nil else { return }
        Task {
            await generation?.end(reason)
            await intake?.stop()
        }
    }
}
