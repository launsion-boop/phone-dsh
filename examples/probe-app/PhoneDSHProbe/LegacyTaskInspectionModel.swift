// SPDX-License-Identifier: MIT
import Foundation
import Observation
import PhoneDSHDeviceTasks

/// Presentation state for an explicitly requested, read-only local observation.
/// It never creates the journal directory or starts a device-task engine.
@MainActor @Observable
final class LegacyTaskInspectionModel {
    typealias Inspect = @Sendable () async -> DeviceTaskLegacyInspection

    private(set) var result: DeviceTaskLegacyInspection?
    private(set) var isInspecting = false
    private(set) var cancellationRequested = false
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var discardResult = false
    @ObservationIgnored private let inspect: Inspect

    init(inspect: @escaping Inspect = {
        await DeviceTaskLegacyInspector.inspect()
    }) {
        self.inspect = inspect
    }

    func start() {
        guard job == nil else { return }
        result = nil
        cancellationRequested = false
        discardResult = false
        isInspecting = true
        job = Task {
            let observation = await inspect()
            // Cancellation is advisory until the inspector has closed all of
            // its descriptors and returned; don't allow a second scan sooner.
            if !discardResult { result = observation }
            isInspecting = false
            cancellationRequested = false
            job = nil
        }
    }

    func cancel() {
        guard let job else { return }
        cancellationRequested = true
        job.cancel()
    }

    func cancelAndClear() {
        discardResult = true
        cancel()
        result = nil
    }
}
