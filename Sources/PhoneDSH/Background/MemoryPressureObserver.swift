// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — system memory-warning observer.
//
// PLAN §2.5 and spec/v1/budgets.md §3: the memory-proxy signal includes a
// platform memory-pressure input. The observation is informational: the host
// decides which existing budget action (clearTmp / planned restart) runs, and
// it never shows a prompt, banner or disabled state (plan §1.2).

import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Forwards the platform's "memory is tight" notification.
///
/// The observer coalesces nothing itself; the host owns the debounce and the
/// action order. It is a thin adapter so the host actor imports no UIKit API.
final class PhoneDSHMemoryPressureObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var token: NSObjectProtocol?
    private var handler: (@Sendable () -> Void)?

    init() {}

    /// Starts observing. Idempotent: a second call replaces the handler without
    /// registering a second notification token.
    func start(center: NotificationCenter = .default,
               handler: @escaping @Sendable () -> Void) {
        lock.lock()
        self.handler = handler
        let alreadyStarted = token != nil
        lock.unlock()
        guard !alreadyStarted else { return }
        #if canImport(UIKit)
        let observer = center.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil) { [weak self] _ in
                guard let self else { return }
                let handler = self.lock.withLock { self.handler }
                handler?()
            }
        lock.lock()
        token = observer
        lock.unlock()
        #endif
    }

    /// Stops observing and drops the handler. Idempotent.
    func stop(center: NotificationCenter = .default) {
        lock.lock()
        let observer = token
        token = nil
        handler = nil
        lock.unlock()
        #if canImport(UIKit)
        if let observer { center.removeObserver(observer) }
        #endif
    }
}
