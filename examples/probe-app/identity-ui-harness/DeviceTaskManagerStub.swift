// SPDX-License-Identifier: MIT
import Foundation
import Observation

// The actual page is compiled, but this host must never start task intake.
@MainActor @Observable final class DeviceTaskManager {
    static let shared = DeviceTaskManager()
    let error: String? = nil
    static func bleKey(_ id: UUID) -> String { fatalError("task path must not be called") }
    func isActive(_ key: String) -> Bool { fatalError("task path must not be called") }
    func startBLE(_ id: UUID) async { fatalError("task path must not be called") }
    func stop(_ key: String) async { fatalError("task path must not be called") }
}
