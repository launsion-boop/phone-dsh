// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — iOS probe app: Web surface lifecycle serialization.
//
// `WebHostModel` starts, resets, parks, resumes and stops one
// `PhoneDSHHost`. Those transitions are asynchronous: a background park can
// drain for the host's drain window, and a foreground resume can wait for the
// host's 240 s hello timeout. A teardown must never run beside one of them —
// `PhoneDSHHost.stop()` on a `.starting` host does not wait for or cancel the
// in-flight resume, so the resume could boot a Worker after the teardown.
//
// This gate is the model's single transition token. Every entry — start, the
// failed reset, park, resume and stop — claims it before touching the host,
// anchor or engine. A caller that must not drop its request (a retry of a
// failed host) *waits* for the token instead of inspecting flags; a teardown
// waits too, without a fixed deadline, because the host's own
// boot/hello/drain bounds end the transition. The file has no SwiftUI/UIKit
// dependency so the iOS Simulator regression suite compiles the same rules
// the app uses.

/// The lifecycle rules that must hold before the model starts a park/resume.
enum WebSurfaceLifecyclePolicy {
    /// A failed controller has no `Failed -> Parked` edge. `PhoneDSHHost.park()`
    /// on a failed host only moves the facade to `.stopped` while the machine
    /// stays `Failed`; `resume()` then throws forever and the explicit
    /// `userReset()` retry path is lost. Keep the failure intact instead.
    static func allowsPark(hostFailed: Bool) -> Bool {
        !hostFailed
    }

    /// `resume()` requires a host that was really parked and is not failed.
    /// Keeping this rule explicit also covers a stale `parked` flag.
    static func allowsResume(parked: Bool, hostFailed: Bool) -> Bool {
        parked && !hostFailed
    }
}

/// Serializes start/reset/park/resume/stop transitions and lets a teardown
/// wait for the one in flight. The wait is token-based, not timer-based:
/// returning after a fixed interval shorter than `helloTimeout` is exactly
/// what raced `host.stop()` with a resume that was still booting the Worker.
@MainActor
final class WebSurfaceLifecycleGate {
    private(set) var isTransitioning = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Claims the token without waiting. Returns `false` while another
    /// transition is in flight or after `stop()` was requested. Kept for
    /// callers that deliberately drop a redundant transition.
    func begin(stopping: Bool) -> Bool {
        guard !isTransitioning, !stopping else { return false }
        isTransitioning = true
        return true
    }

    /// Claims the token, waiting for the in-flight transition instead of
    /// dropping the request. This is what the failed-host retry and the boot
    /// path use: `start()` must not touch `host`/`anchor` while a park or
    /// resume still owns them. Returns `false` once a teardown owns the next
    /// move, so the caller leaves the retryable state untouched.
    func acquire(stopping: Bool) async -> Bool {
        while true {
            if stopping { return false }
            if !isTransitioning {
                isTransitioning = true
                return true
            }
            await waitForRelease()
        }
    }

    /// Claims the token for a teardown, waiting for any in-flight transition
    /// (including a failed-host reset or a resume still inside `helloTimeout`)
    /// to really end. `stop()` itself owns the teardown, so it is allowed to
    /// claim even while `stopping` is set.
    func acquireExclusive() async {
        while isTransitioning {
            await waitForRelease()
        }
        isTransitioning = true
    }

    /// Releases the token and wakes every waiter, which then re-checks the
    /// state. `acquire`/`acquireExclusive` may resume here; the model may
    /// begin the next queued transition once it is released.
    func end() {
        guard isTransitioning else { return }
        isTransitioning = false
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    /// Waits until no start/reset/park/resume transition is running. There is
    /// no fixed deadline: an in-flight resume is bounded by the host's
    /// `helloTimeout` (240 s), so waking earlier and calling `host.stop()`
    /// would tear down a host that is still booting.
    func waitUntilIdle() async {
        while isTransitioning {
            await waitForRelease()
        }
    }

    /// Suspends until `end()` releases the current token. The continuation is
    /// only stored while the token is still held, so an `end()` that races the
    /// suspension cannot leave a waiter behind.
    private func waitForRelease() async {
        await withCheckedContinuation { continuation in
            if isTransitioning {
                waiters.append(continuation)
            } else {
                continuation.resume()
            }
        }
    }
}
