// SPDX-License-Identifier: MIT
// PhoneDSHEngine tests: main-run-loop and event-stream helpers.
//
// The tests are synchronous XCTest methods that wait with expectations while
// XCTest pumps the main run loop, which is what WKWebView needs on macOS. The
// engine object is isolated to the main actor, so direct setup calls go through
// `onMain`.

import Foundation
import XCTest
import PhoneDSHEngine

/// Runs a main-actor closure synchronously from a test method.
func onMain<T>(_ body: @MainActor () throws -> T) -> T {
    if Thread.isMainThread {
        return try! MainActor.assumeIsolated { try body() }
    }
    return try! DispatchQueue.main.sync {
        try MainActor.assumeIsolated { try body() }
    }
}

/// A tiny thread-safe box for values captured by `Task` closures.
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T?

    init(_ value: T? = nil) {
        storage = value
    }

    var value: T? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

/// Records every engine event and fulfils XCTest expectations from the
/// consumer task running off the main actor.
final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [WebEngineEvent] = []
    private var waiters: [Waiter] = []
    private var consumer: Task<Void, Never>?

    private struct Waiter {
        let identifier: UUID
        let match: (WebEngineEvent) -> Bool
        let expectation: XCTestExpectation
    }

    init(_ stream: WebEngineEvents) {
        consumer = Task { [weak self] in
            for await event in stream {
                self?.receive(event)
            }
        }
    }

    deinit {
        consumer?.cancel()
    }

    /// All events seen so far, in order.
    var recordedEvents: [WebEngineEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    /// Returns an expectation fulfilled when a matching event arrives; if one
    /// already arrived, it is fulfilled immediately.
    func expect(_ description: String,
                matching predicate: @escaping (WebEngineEvent) -> Bool) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: description)
        lock.lock()
        if events.contains(where: predicate) {
            lock.unlock()
            expectation.fulfill()
            return expectation
        }
        waiters.append(Waiter(identifier: UUID(), match: predicate,
                              expectation: expectation))
        lock.unlock()
        return expectation
    }

    private func receive(_ event: WebEngineEvent) {
        lock.lock()
        events.append(event)
        let matches = waiters.filter { $0.match(event) }
        if matches.isEmpty == false {
            let identifiers = Set(matches.map(\.identifier))
            waiters.removeAll { identifiers.contains($0.identifier) }
        }
        lock.unlock()
        for waiter in matches {
            waiter.expectation.fulfill()
        }
    }
}
