// SPDX-License-Identifier: MIT
import Foundation
import Observation
import PhoneDSHDeviceTasks

/// Presentation state for an explicitly requested, read-only local observation.
/// It never creates the journal directory or starts a device-task engine.
@MainActor @Observable
final class LegacyTaskInspectionModel {
    typealias Inspect = @Sendable () async -> DeviceTaskLegacyInspection

    private struct Presentation: Equatable {
        var result: DeviceTaskLegacyInspection?
        var isInspecting = false
        var cancellationRequested = false
    }

    private final class Operation {
        var task: Task<Void, Never>?
        var cancelled = false
        var discard = false
    }
    private final class Revision {}

    // A single observable value prevents readers from seeing a mixture of two
    // transitions. The desired value is separate because willSet observers can
    // synchronously change it before an older publication reaches its setter.
    private var presentation = Presentation()
    var result: DeviceTaskLegacyInspection? { presentation.result }
    var isInspecting: Bool { presentation.isInspecting }
    var cancellationRequested: Bool { presentation.cancellationRequested }
    @ObservationIgnored private var desired = Presentation()
    @ObservationIgnored private var revision = Revision()
    @ObservationIgnored private var operation: Operation?
    @ObservationIgnored private let inspect: Inspect

    init(inspect: @escaping Inspect = {
        await DeviceTaskLegacyInspector.inspect()
    }) {
        self.inspect = inspect
    }

    func start() {
        guard operation == nil else { return }
        let current = Operation()
        operation = current
        // This MainActor task cannot enter the inspector until this synchronous
        // start returns. Install it before publishing so reentrant cancellation
        // has a real task to cancel.
        current.task = Task {
            guard !Task.isCancelled else {
                finish(current, observation: nil)
                return
            }
            let observation = await inspect()
            finish(current, observation: observation)
        }
        desired = Presentation(result: nil, isInspecting: true, cancellationRequested: false)
        revision = Revision()
        publish()
    }

    func cancel() {
        guard let current = operation, !current.cancelled else { return }
        current.cancelled = true
        desired.cancellationRequested = true
        revision = Revision()
        current.task?.cancel()
        publish()
    }

    func cancelAndClear() {
        if let current = operation {
            guard !current.discard || !current.cancelled || desired.result != nil else { return }
            current.discard = true
            let needsCancellation = !current.cancelled
            current.cancelled = true
            desired.result = nil
            desired.cancellationRequested = true
            revision = Revision()
            if needsCancellation { current.task?.cancel() }
        } else {
            // This also invalidates a completion currently suspended in willSet,
            // even when the old visible result has not yet been installed.
            guard desired.result != nil else { return }
            desired.result = nil
            revision = Revision()
        }
        publish()
    }

    private func finish(_ current: Operation, observation: DeviceTaskLegacyInspection?) {
        guard operation === current else { return }
        // The inspector has returned (or was never entered). A new start may
        // now be accepted even from inside the completion notification.
        current.task = nil
        operation = nil
        desired = Presentation(result: current.discard ? nil : observation,
                               isInspecting: false, cancellationRequested: false)
        revision = Revision()
        publish()
    }

    private func publish() {
        guard desired != presentation else { return }
        let expected = revision
        let next = desired
        withMutation(keyPath: \.presentation) {
            // Observation's willSet callback can synchronously start, cancel,
            // or clear; check after it returns and before touching storage.
            guard revision === expected else { return }
            _presentation = next
        }
    }
}
