// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSH: iOS background URLSession probe.
//
// PLAN W6-BACKGROUND. iOS-only implementation of the flag-gated probe: one
// non-streaming model request is uploaded through
// `URLSessionConfiguration.background(withIdentifier:)`, and the delegate
// records the wake path (`urlSessionDidFinishEvents`). The App delegate must
// forward `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
// to ``handleEvents(completionHandler:)``.
//
// This file submits a diagnostic request and nothing else. It is not the task
// execution path and it never opens admission. NOT_VERIFIED: background upload
// scheduling and wake delivery on a device; the simulator has no real
// background URLSession launch.

#if canImport(UIKit) && os(iOS) && !targetEnvironment(macCatalyst)

import Foundation

/// `URLSessionConfiguration.background` transport for the probe.
public final class PlatformBackgroundURLSessionProbeTransport: NSObject,
    BackgroundProbeTransport, URLSessionDelegate, URLSessionTaskDelegate,
    @unchecked Sendable {
    private final class Pending: @unchecked Sendable {
        let continuation: CheckedContinuation<BackgroundProbeOutcome, Never>
        let onWake: @Sendable () -> Void

        init(continuation: CheckedContinuation<BackgroundProbeOutcome, Never>,
             onWake: @escaping @Sendable () -> Void) {
            self.continuation = continuation
            self.onWake = onWake
        }
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var sessions: [String: URLSession] = [:]
    private var latestWake: (@Sendable () -> Void)?
    private var eventsCompletion: (() -> Void)?

    public override init() {
        super.init()
    }

    public func submit(_ request: BackgroundProbeRequest,
                       sessionIdentifier: String,
                       onWake: @escaping @Sendable () -> Void) async
        -> BackgroundProbeOutcome {
        await withCheckedContinuation { continuation in
            let configuration = URLSessionConfiguration.background(
                withIdentifier: sessionIdentifier)
            configuration.sessionSendsLaunchEvents = true
            configuration.isDiscretionary = false
            let session = URLSession(configuration: configuration,
                                     delegate: self,
                                     delegateQueue: nil)
            lock.withLock {
                sessions[sessionIdentifier] = session
                latestWake = onWake
            }
            var urlRequest = URLRequest(url: request.url)
            urlRequest.httpMethod = request.method
            urlRequest.allHTTPHeaderFields = request.headers
            let task = session.uploadTask(with: urlRequest, from: request.body)
            let entry = Pending(continuation: continuation, onWake: onWake)
            lock.withLock {
                pending[task.taskIdentifier] = entry
                latestWake = onWake
            }
            task.resume()
        }
    }

    /// Forwards the App delegate's background-session completion handler.
    ///
    /// Call from
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    /// The handler runs after the session's events are delivered.
    public func handleEvents(completionHandler: @escaping () -> Void) {
        lock.withLock { eventsCompletion = completionHandler }
    }

    // MARK: - URLSessionTaskDelegate

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           didCompleteWithError error: Error?) {
        let entry: Pending? = lock.withLock {
            pending.removeValue(forKey: task.taskIdentifier)
        }
        guard let entry else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        entry.continuation.resume(returning: BackgroundProbeOutcome(
            statusCode: status,
            errorDescription: error?.localizedDescription,
            completedAt: Date()))
    }

    // MARK: - URLSessionDelegate

    /// The system woke the App to deliver the background session's events.
    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let (wake, completion): ((@Sendable () -> Void)?, (() -> Void)?) = lock.withLock {
            let wake = latestWake
            let completion = eventsCompletion
            eventsCompletion = nil
            return (wake, completion)
        }
        wake?()
        if let completion {
            if Thread.isMainThread {
                completion()
            } else {
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    public func urlSession(_ session: URLSession,
                           didBecomeInvalidWithError error: Error?) {
        let leftover: [Int: Pending] = lock.withLock {
            let values = pending
            pending.removeAll()
            return values
        }
        for entry in leftover.values {
            entry.continuation.resume(returning: BackgroundProbeOutcome(
                statusCode: nil,
                errorDescription: error?.localizedDescription ?? "session invalidated",
                completedAt: Date()))
        }
    }
}

#endif
