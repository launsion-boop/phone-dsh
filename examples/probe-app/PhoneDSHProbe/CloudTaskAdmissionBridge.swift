// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — phone task queue ↔ external admission journal.
//
// spec/v1/cloud-tasks.md §7 on the app side: the `CloudTaskHost` the
// coordinator calls. It only reads and writes the admission journal; it never
// boots an engine and executes nothing. A fetched task is an ordinary request
// attributed to `account:<user id>`: it carries no approval and bypasses no
// permission prompt.
//
// UI-free and host-free on purpose: the hostless simulator suite compiles this
// file and drives it with the real journal and the real coordinator.

import Foundation
import PhoneDSH
import ProbeKit

/// What the app can say about a task's target without booting anything.
enum CloudTaskTargetPresence: Equatable, Sendable {
    case present
    /// Definitely not on this phone: the task is acked `rejected` / `target_missing`.
    case absent
    /// Cannot tell now (engine not running and no cached answer, Bot roster not
    /// loaded). Nothing is admitted and nothing is acked: the lease redelivers.
    case unknown
}

struct CloudTaskAdmissionBridge: Sendable {
    let journal: ExternalAdmissionJournal
    /// The signed-in tono user id, read when a task is admitted; nil = no admission.
    let signedInUserID: @Sendable () async -> String?
    let presence: @Sendable (ExternalAdmissionTarget) async -> CloudTaskTargetPresence
    var now: @Sendable () -> Int64 = { ExternalAdmissionJournal.nowMs() }

    static func target(_ target: CloudTaskTarget) -> ExternalAdmissionTarget {
        switch target.kind {
        case .dshSession: return .dshSession(sessionId: target.id)
        case .bot: return .bot(botId: target.id)
        }
    }

    func signedInPrincipal() async -> String? {
        ExternalAdmissionRequest.accountPrincipal(userID: await signedInUserID())
    }

    /// The coordinator's view of the journal.
    func host() -> CloudTaskHost {
        let seen = PresenceMemo()
        return CloudTaskHost(
            targetExists: { target in
                // Without an account nothing is admitted; `admit` leaves the task unacked.
                guard await signedInPrincipal() != nil else { return true }
                let mapped = Self.target(target)
                let answer = await presence(mapped)
                seen.set(answer, for: mapped)
                // "Cannot tell" is not "missing": `admit` defers it without an ack.
                return answer != .absent
            },
            admit: { request in
                guard let principal = await signedInPrincipal() else { return .storage }
                let target = Self.target(request.target)
                guard seen.take(target) == .present else { return .storage }
                let nowMs = now()
                let outcome = await journal.admit(
                    .cloudTask(principal: principal, deviceID: request.deviceID,
                               taskID: request.taskID, target: target, text: request.text,
                               expiresAtMs: request.expiresAtMs),
                    nowMs: nowMs)
                switch outcome.result {
                case .admitted:
                    return outcome.receipt.map { .admitted(admissionID: $0.admissionId) } ?? .storage
                case .duplicate:
                    return outcome.receipt.map { .duplicate(admissionID: $0.admissionId) } ?? .storage
                case .invalid: return .invalid
                case .conflict: return .conflict
                case .capacity: return .capacity
                case .storage: return .storage
                }
            },
            terminalReports: { deviceID in await terminalReports(deviceID: deviceID) }
            // `terminalSettled` keeps its default: nothing is persisted. A settled
            // terminal record simply stays in the journal until its own tombstone
            // sweep (§7, v1.5); a new launch offers it once more and the cloud
            // answers `duplicate`.
        )
    }

    /// Terminal cloud-task records of this device and of the signed-in account.
    /// Another account's records are never offered to this account's session.
    func terminalReports(deviceID: String) async -> [CloudTaskTerminalReport] {
        guard let principal = await signedInPrincipal() else { return [] }
        return await journal.allRecords(nowMs: now()).compactMap { record in
            guard record.principal == principal, record.source.kind == .cloudTask,
                  record.source.id == deviceID else { return nil }
            return Self.terminalReport(record)
        }
    }

    static func terminalReport(_ record: ExternalAdmissionRecord) -> CloudTaskTerminalReport? {
        let stage: CloudTaskTerminalReport.Stage
        switch record.stage {
        case .admitted, .dispatching, .linked: return nil
        case .completed: stage = .completed
        case .failed: stage = .failed(reason: record.reason)
        case .expired: stage = .expired
        case .cancelled: stage = .cancelled
        case .unknown: stage = .unknown
        }
        return CloudTaskTerminalReport(taskID: record.sourceRequestId,
                                       admissionID: record.admissionId, stage: stage)
    }

    /// The account changed or signed out: `admitted` records of every account
    /// that is no longer signed in become `cancelled` (external-admission.md §3).
    @discardableResult
    func cancelAdmissionsOfSignedOutAccounts() async -> [ExternalAdmissionRecord] {
        await journal.cancelAccountAdmissions(exceptPrincipal: await signedInPrincipal(),
                                              nowMs: now())
    }
}

/// The answer `targetExists` got, handed to the `admit` call that follows it in
/// the same §7 decision (the coordinator decides one task at a time).
private final class PresenceMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: CloudTaskTargetPresence] = [:]

    private static func key(_ target: ExternalAdmissionTarget) -> String {
        switch target {
        case .dshSession(let id): return "s:" + id
        case .bot(let id): return "b:" + id
        }
    }

    func set(_ answer: CloudTaskTargetPresence, for target: ExternalAdmissionTarget) {
        lock.lock(); defer { lock.unlock() }
        answers[Self.key(target)] = answer
    }

    func take(_ target: ExternalAdmissionTarget) -> CloudTaskTargetPresence {
        lock.lock(); defer { lock.unlock() }
        return answers.removeValue(forKey: Self.key(target)) ?? .unknown
    }
}

/// The settings row's status line, in plain words.
enum CloudTaskStatusText {
    static func describe(enabled: Bool, signedIn: Bool, status: CloudTaskStatus?) -> String {
        guard enabled else { return "未开启" }
        guard signedIn else { return "未登录：登录 Tono 账号后才会接收任务" }
        switch status {
        case nil: return "已开启，回到前台时检查新任务"
        case .ready?: return "已开启"
        case .disabled?: return "未开启"
        case .signedOut?: return "未登录：登录 Tono 账号后才会接收任务"
        case .unavailable?: return "暂不可用：云端还没有开放这项服务"
        case .deviceLimit?: return "设备数已满：这个账号已登记 8 台设备，请先在其他设备上关闭"
        case .storeUnavailable?: return "暂不可用：手机解锁后再试"
        case .failed?: return "暂时连不上云端，下次回到前台时重试"
        }
    }

    /// What the cloud did when the switch was turned off.
    static func describeTurnedOff(status: CloudTaskStatus) -> String {
        switch status {
        case .disabled, .signedOut: return "未开启"
        default: return "已关闭；云端的登记会在下次联网时删除"
        }
    }
}
