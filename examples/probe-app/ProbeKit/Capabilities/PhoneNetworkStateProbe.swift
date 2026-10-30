// SPDX-License-Identifier: MIT

import Foundation
import Network

@MainActor
final class PhoneNetworkStateProbe {
    private var monitor: NWPathMonitor?
    private var continuation: CheckedContinuation<[String: Any], Never>?
    private var timeout: Task<Void, Never>?

    func current() async -> [String: Any] {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let monitor = NWPathMonitor()
            self.monitor = monitor
            monitor.pathUpdateHandler = { path in
                let status = switch path.status {
                case .satisfied: "satisfied"
                case .unsatisfied: "unsatisfied"
                case .requiresConnection: "requiresConnection"
                @unknown default: "unknown"
                }
                let result: [String: Any] = [
                    "status": status,
                    "expensive": path.isExpensive,
                    "cellular": path.usesInterfaceType(.cellular),
                    "wifi": path.usesInterfaceType(.wifi),
                    "wired": path.usesInterfaceType(.wiredEthernet),
                ]
                Task { @MainActor [weak self] in self?.finish(result) }
            }
            monitor.start(queue: DispatchQueue(label: "phone-dsh.network-state"))
            timeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.finish(["status": "unknown"])
            }
        }
    }

    private func finish(_ result: [String: Any]) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        monitor?.cancel()
        monitor = nil
        continuation.resume(returning: result)
    }
}
