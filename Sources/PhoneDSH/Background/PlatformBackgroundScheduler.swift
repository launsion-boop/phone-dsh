// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSH: platform background scheduler.
//
// PLAN W6-BACKGROUND. On iOS 26 the drain window is a
// `BGContinuedProcessingTask`: it is submitted only when the App is about to
// drain, its launch handler performs no work (the drain itself is the ordinary
// controller path), and it is completed when the drain window closes. On older
// iOS the documented `UIApplication.beginBackgroundTask` window is used.
//
// NOT_VERIFIED: actual scheduling/entitlement behaviour on a device. A
// BGContinuedProcessingTask registration also needs the concrete identifier
// family in the App's Info.plist (`BGTaskSchedulerPermittedIdentifiers`); when
// registration or submission is refused this scheduler falls back to
// `beginBackgroundTask` instead of failing the drain.

import Foundation
import PhoneDSHController

#if canImport(UIKit) && canImport(BackgroundTasks) && os(iOS) && !targetEnvironment(macCatalyst)
import UIKit
#endif

/// iOS/macOS scheduler for the 20 s background drain window.
public final class PlatformBackgroundTaskScheduler: BackgroundTaskScheduling,
    @unchecked Sendable {
    private struct LegacyHandle {
        var identifier: Int
    }

    private let lock = NSLock()
    private var nextID: UInt64 = 0
    private var legacy: [UInt64: LegacyHandle] = [:]
    #if canImport(UIKit) && canImport(BackgroundTasks) && os(iOS) && !targetEnvironment(macCatalyst)
    // Kept as `AnyObject` so the stored property itself does not require the
    // iOS 26 availability of `ContinuedProcessingDrainWindow`; every access
    // casts inside an `#available(iOS 26.0, *)` block.
    private var continued: [UInt64: AnyObject] = [:]
    #endif

    public init() {}

    public var kind: BackgroundTaskKind {
        #if canImport(UIKit) && canImport(BackgroundTasks) && os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) {
            return .continuedProcessing
        }
        return .backgroundTask
        #else
        return .none
        #endif
    }

    public func beginBackgroundTask(
        name: String,
        expiration: @escaping @Sendable () -> Void) async -> BackgroundTaskToken? {
        #if canImport(UIKit) && canImport(BackgroundTasks) && os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *),
           let window = ContinuedProcessingDrainWindow.begin(name: name,
                                                             expiration: expiration) {
            let token = makeToken(kind: .continuedProcessing)
            lock.withLock { continued[token.id] = window }
            return token
        }
        let identifier = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: name) {
                expiration()
            }
        }
        guard identifier != .invalid else { return nil }
        let token = makeToken(kind: .backgroundTask)
        lock.withLock { legacy[token.id] = LegacyHandle(identifier: identifier.rawValue) }
        return token
        #else
        _ = name
        _ = expiration
        return nil
        #endif
    }

    public func reportProgress(_ fraction: Double,
                               for token: BackgroundTaskToken) async {
        #if canImport(UIKit) && canImport(BackgroundTasks) && os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) {
            let window = lock.withLock {
                continued[token.id] as? ContinuedProcessingDrainWindow
            }
            window?.report(progress: fraction)
        }
        #else
        _ = fraction
        _ = token
        #endif
    }

    public func endBackgroundTask(_ token: BackgroundTaskToken) async {
        #if canImport(UIKit) && canImport(BackgroundTasks) && os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) {
            let window = lock.withLock {
                continued.removeValue(forKey: token.id) as? ContinuedProcessingDrainWindow
            }
            if let window {
                window.finish(success: true)
                return
            }
        }
        let handle: LegacyHandle? = lock.withLock {
            legacy.removeValue(forKey: token.id)
        }
        if let handle {
            await MainActor.run {
                UIApplication.shared.endBackgroundTask(
                    UIBackgroundTaskIdentifier(rawValue: handle.identifier))
            }
        }
        #else
        _ = token
        #endif
    }

    private func makeToken(kind: BackgroundTaskKind) -> BackgroundTaskToken {
        let id: UInt64 = lock.withLock {
            nextID += 1
            return nextID
        }
        return BackgroundTaskToken(id: id, kind: kind)
    }
}
