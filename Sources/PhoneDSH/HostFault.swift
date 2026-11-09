// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSH: the typed blast radius of a host failure.
//
// The incident this type exists for: iOS killed the WebContent process, the
// host restarted the Worker, the replacement Worker answered a non-HELLO first
// frame (`PROTO_MISMATCH`), the bootstrap surfaced that as
// `WebEngineError.bootFailed`, and the host passed the raw `Error` to a
// `fail(_:)` that accepted anything. A connection-level accident therefore
// acquired the blast radius of a workspace-level fact and persisted `failed`
// across processes, leaving the App permanently unusable without a user reset.
//
// `HostFault` is the seam that turns "how severe is this?" into a type rather
// than a property of whoever caught the error first:
//
//   `.boot`      -> controller `Backoff` (`FailureClass.transient`), retryable
//   `.workspace` -> controller `Failed`  (`FailureClass.terminal`), but the
//                   persisted retry window still lets the next process retry
//
// The classification rule is one question: *would this still hold after a new
// Worker, a new boot and a new process?* If a fresh attempt could clear it, the
// fault is `.boot`; if it is a property of the workspace on disk or of the
// configuration, it is `.workspace`.
//
// `classify(_:)` answers `nil` only for conditions that must never reach the
// host-level failure path at all:
//
//   * a superseded navigation/boot cycle — another owner is booting;
//   * a VFS resource refusal (`vfsRefused`/`vfsQuotaExceeded`) — an answer to
//     one tool call, never a host state (wire already refuses to close the
//     connection for it);
//   * `hostFailed`/`backoffNotElapsed` — conclusions, not causes.
//
// Every other unknown error is reported as unclassified (device log) and left
// for the call site to route by context; it is never silently swallowed.

import Foundation
import PhoneDSHController
import PhoneDSHEngine
import PhoneDSHLog
import PhoneDSHLoopback

/// The blast radius of one host failure.
public enum HostFault: Error, Equatable, Sendable {
    /// Process-scoped: a fresh Worker or one more boot attempt may clear it.
    /// The controller moves to its persisted `Backoff`; the host is not dead.
    case boot(BootFault)
    /// Workspace-scoped: the condition holds across a new process. The
    /// controller moves to `Failed`, and only the persisted retry window lets
    /// the next process try again.
    case workspace(WorkspaceFault)
}

/// A `.boot` fault: the failure belongs to this Worker boot, not the workspace.
public enum BootFault: Equatable, Sendable {
    /// A page navigation / Worker bootstrap / script evaluation failure.
    case engine(WebEngineError)
    /// HELLO, attach, channel and controller-race `PhoneDSHError`s. The
    /// `PROTO_MISMATCH` incident arrives here as `bootFailed` above; the rest
    /// of this group is `startTimedOut`, `channelUnavailable`, `invalidState`,
    /// `engineNotAttached`, `notStarted` and `invalidResponse`.
    case handshake(PhoneDSHError)
    /// A controller transition or persistence race (`HostStateError`).
    case controller(HostStateError)
    /// A workspace-log failure a fresh boot may repair: `posix` I/O pressure
    /// and the adoptable materialized divergence (`RecoveryReset`).
    case log(LogError)
    /// A loopback listener/connection refusal that only this boot saw.
    case transport(LoopbackError)
    /// Fence authority read/validation failure that a fresh process may clear.
    case authority(FenceAuthorityError)
    /// A handoff/reclaim transport failure that one more attempt may clear.
    case handoff(HandoffError)
    /// An error ``HostFault/classify(_:)`` could not place. Carrying it as a
    /// boot fault keeps a genuinely unexpected defect fail-loud (transient)
    /// instead of leaving a half-booted host. The call site always states the
    /// context.
    case unclassified(String)
}

/// A `.workspace` fault: the failure holds across a new Worker and a new
/// process (workspace bytes, configuration, authority, build capability).
public enum WorkspaceFault: Equatable, Sendable {
    /// A WebEngine configuration/origin that cannot produce a boot page.
    case engine(WebEngineError)
    /// An unusable bundle/configuration, a rejected lease, Lockdown Mode or an
    /// operation this build does not support.
    case configuration(PhoneDSHError)
    /// A workspace-log failure a retry cannot repair: `corrupt` outside the
    /// adoptable divergence subset, quota exhaustion, materialization errors.
    case log(LogError)
    /// A programming-level loopback refusal (`invalidEndpoint`,
    /// `alreadyRunning`).
    case transport(LoopbackError)
    /// Authority evidence that does not match (a fence generation the caller
    /// can no longer prove).
    case authority(FenceAuthorityError)
    /// A handoff/reclaim condition that needs a user or App action: the
    /// credential, the token vault, the payload bound or the build capability.
    case handoff(HandoffError)
    /// A controller/step record the host could not write (D13 settlement,
    /// `host-state.json`). The durable evidence this incarnation needs is
    /// missing, and a new process cannot fabricate it.
    case state(ControllerFileError)
}

// MARK: - Behaviour

extension HostFault: CustomStringConvertible {
    /// The diagnostic message the host publishes (event stream, `lastError`).
    /// The underlying error keeps its own wording so existing messages and log
    /// signatures do not change.
    public var description: String {
        switch self {
        case .boot(let fault): return fault.description
        case .workspace(let fault): return fault.description
        }
    }

    /// The controller signal class this fault drives.
    public var failureClass: FailureClass {
        switch self {
        case .boot: return .transient
        case .workspace: return .terminal
        }
    }

    /// Whether this is a `.boot` (retryable) fault.
    public var isBoot: Bool {
        if case .boot = self { return true }
        return false
    }

    /// Whether this fault came from the D15 handoff/reclaim path.
    ///
    /// The handoff owns its two-phase engine stop: it calls `terminateWorker`
    /// and `shutdownWorker` itself and the regressions assert the exact
    /// sequence, including "no shutdown after a refused/cancelled stop". A
    /// generic failure teardown must not add a second shutdown call there.
    public var isHandoff: Bool {
        switch self {
        case .boot(.handoff), .workspace(.handoff): return true
        default: return false
        }
    }

    /// Short scope label for diagnostics (`boot` / `workspace`).
    public var scope: String {
        switch self {
        case .boot: return "boot"
        case .workspace: return "workspace"
        }
    }
}

extension BootFault: CustomStringConvertible {
    public var description: String {
        switch self {
        case .engine(let error): return error.description
        case .handshake(let error): return error.description
        case .controller(let error): return String(describing: error)
        case .log(let error): return error.description
        case .transport(let error): return error.description
        case .authority(let error): return String(describing: error)
        case .handoff(let error): return error.description
        case .unclassified(let detail): return detail
        }
    }
}

extension WorkspaceFault: CustomStringConvertible {
    public var description: String {
        switch self {
        case .engine(let error): return error.description
        case .configuration(let error): return error.description
        case .log(let error): return error.description
        case .transport(let error): return error.description
        case .authority(let error): return String(describing: error)
        case .handoff(let error): return error.description
        case .state(let error): return String(describing: error)
        }
    }
}

// MARK: - Classification

extension HostFault {
    /// Classifies one caught error into a host failure, or returns `nil` when
    /// the error must never fail the host.
    ///
    /// Call sites route a classified value through `PhoneDSHHost.fail(_:)`;
    /// a `nil` is handled by context (a VFS refusal is logged and returned to
    /// the tool, a superseded boot is ignored). Unknown errors are logged as
    /// unclassified rather than swallowed.
    public static func classify(_ error: Error) -> HostFault? {
        switch error {
        case let fault as HostFault:
            // A classified fault that is rethrown keeps its own scope.
            return fault
        case let error as WebEngineError:
            return classify(engine: error)
        case let error as PhoneDSHError:
            return classify(phone: error)
        case let error as LogError:
            return classify(log: error)
        case let error as HostStateError:
            // Controller races are per-incarnation: a fresh controller or one
            // more boot attempt may settle them. A persistence failure is
            // reported through the same value; the next boot re-reads the
            // record, so retrying is still the right first answer.
            return .boot(.controller(error))
        case let error as LoopbackError:
            return classify(loopback: error)
        case let error as FenceAuthorityError:
            return classify(authority: error)
        case let error as HandoffError:
            return classify(handoff: error)
        case let error as ControllerFileError:
            // D13/D18 state that could not be written down (a step record, the
            // controller file). Retrying the same write against the same
            // directory fails the same way, and — more important — the next
            // boot cannot prove the open step is settled, so opening admission
            // after a retry would silently reopen a step the host already gave
            // up on. That is a workspace fact, not a boot failure.
            return .workspace(.state(error))
        default:
            NSLog("phone-dsh: unclassified host error (HostFault.classify): %@",
                  String(describing: error))
            return nil
        }
    }

    /// Whether ``classify(_:)`` returns `nil` for this error because it is a
    /// documented non-failure rather than an unclassified defect.
    ///
    /// A caller that sees `nil` distinguishes the two: a benign condition is
    /// reported and the host is left alone, an unclassified error still needs
    /// the caller's contextual fail-loud decision.
    public static func isBenign(_ error: Error) -> Bool {
        switch error {
        case let error as WebEngineError:
            switch error {
            case .navigationSuperseded, .bootSuperseded: return true
            default: return false
            }
        case let error as PhoneDSHError:
            switch error {
            case .hostFailed, .backoffNotElapsed: return true
            default: return false
            }
        case let error as LogError:
            switch error {
            case .vfsRefused, .vfsQuotaExceeded: return true
            default: return false
            }
        default:
            return false
        }
    }
}

// MARK: - Per-type mapping

private extension HostFault {
    static func classify(engine error: WebEngineError) -> HostFault? {
        switch error {
        case .invalidConfiguration, .invalidOrigin:
            // The page URL cannot be built: retrying the same configuration
            // produces the same refusal.
            return .workspace(.engine(error))
        case .navigationFailed, .navigationTimedOut, .bootFailed,
             .bootTimedOut, .contentProcessTerminated, .scriptEvaluationFailed:
            // The `PROTO_MISMATCH` incident arrives as `.bootFailed`.
            return .boot(.engine(error))
        case .navigationSuperseded, .bootSuperseded:
            // A newer load replaced this one. Not a failure: the replacement
            // (a planned restart, another termination recovery) owns the boot.
            return nil
        }
    }

    static func classify(phone error: PhoneDSHError) -> HostFault? {
        switch error {
        case .startTimedOut, .engineNotAttached, .notStarted, .invalidState,
             .channelUnavailable, .invalidResponse:
            // HELLO timeout, a WebView that is not attached yet, a call-order
            // race, a lost connection, an envelope violation: all per-boot.
            return .boot(.handshake(error))
        case .leaseRejected, .invalidBundle, .invalidConfiguration,
             .lockdownMode, .unsupported:
            // The Worker presented the wrong authority, the bundle/config is
            // unusable, Lockdown Mode disables JIT, or the build cannot do it.
            return .workspace(.configuration(error))
        case .hostFailed, .backoffNotElapsed:
            // A conclusion ("the host is failed") and a healthy wait ("the
            // retry window is still closed"), never causes for a new failure.
            return nil
        }
    }

    static func classify(log error: LogError) -> HostFault? {
        switch error {
        case .vfsRefused, .vfsQuotaExceeded:
            // Resource refusals belong to one tool call: no mseq is consumed
            // and the peer maps them to ENOSPC/EFBIG. They must never reach
            // `fail(_:)` (wire already refuses to close the connection for
            // them).
            return nil
        case .corrupt:
            // The materialized tree ahead of the retained WAL has a system
            // exit: `recover()` adopts the tree (`RecoveryReset`) and boots
            // again. Any other corruption is a workspace fact.
            return error.isMaterializedDivergence ? .boot(.log(error))
                : .workspace(.log(error))
        case .posix:
            // I/O pressure (disk full, interrupted write) can clear on a new
            // attempt; a persistent ENOSPC still ends in the retry window.
            return .boot(.log(error))
        case .materializationFailed, .quotaExceeded, .overlaySymlink,
             .overlayPathTooLong, .invalidBarrier, .epochCoverageFailed,
             .notReady, .closed:
            // Host defects and exhausted workspace budgets: retrying the same
            // bytes cannot repair them.
            return .workspace(.log(error))
        }
    }

    static func classify(loopback error: LoopbackError) -> HostFault? {
        switch error {
        case .channelUnavailable, .closed, .notRunning, .upstreamFailed:
            // Listener/connection state of this boot (an mseq wait timeout or
            // an upstream without an HTTP response); the next connection or
            // boot attempt may succeed.
            return .boot(.transport(error))
        case .invalidEndpoint, .alreadyRunning:
            // A programming-level refusal: the same configuration refuses
            // again.
            return .workspace(.transport(error))
        }
    }

    static func classify(authority error: FenceAuthorityError) -> HostFault? {
        switch error {
        case .staleGeneration:
            // The presented generation lost the authority race; a retry cannot
            // make the caller's evidence current.
            return .workspace(.authority(error))
        case .ownerMismatch, .walSeqRegression, .invalidReclaimToken,
             .invalidOwner, .corruptRecord, .handoffAuthorityUncertain:
            // A fresh process re-reads `fence.json` and may see a different
            // record; these are retried once (the persisted retry window keeps
            // a persistent one from bricking the App).
            return .boot(.authority(error))
        }
    }

    static func classify(handoff error: HandoffError) -> HostFault? {
        switch error {
        case .unauthorized, .fenceConflict, .staleGeneration,
             .snapshotConflict, .cleartextEndpoint, .invalidEndpoint,
             // Not repairable by a new Worker/process either: the credential,
             // the App vault, the payload bound or the build capability must
             // change, so these keep the workspace blast radius.
             .payloadTooLarge, .engineShutdownUnsupported, .noReclaimToken,
             .reclaimTokenStoreFailed, .manualReclaimRequired:
            return .workspace(.handoff(error))
        case .invalidControllerState(let detail)
                where isTeardownCapabilityRefusal(detail):
            // `invalidControllerState` is overloaded: it also carries the
            // host's teardown-capability refusals ("no verified Worker
            // termination hook" / "no verified shutdown hook"). They are the
            // same condition as `engineShutdownUnsupported` above — the
            // injected engine cannot prove it stopped the Worker — so a new
            // Worker or process cannot clear them and they keep the workspace
            // blast radius. The controller races that share the case stay
            // per-incarnation in the next branch.
            return .workspace(.handoff(error))
        case .segmentsGap, .badRequest, .payloadMismatch, .internalFailure,
             .transport, .invalidResponse, .notQuiescent, .segmentContinuity,
             .fenceMismatch, .applyFailed, .invalidControllerState, .cancelled:
            // The remote caches the reclaim response per token and a fresh
            // attempt re-reads the workspace, so one more try may hold.
            return .boot(.handoff(error))
        }
    }

    /// Whether an ``HandoffError/invalidControllerState(_:)`` detail is the
    /// host refusing a handoff because the injected engine cannot prove a
    /// Worker stop, rather than a controller state race.
    ///
    /// The two conditions share one error case, so the classification has to
    /// read the published detail. `PhoneDSHHost.suspendRuntimeForRemote` is the
    /// only producer of these two messages and the cold-safety regressions
    /// assert them verbatim; giving the capability refusal its own case would
    /// require touching the protocol and the host, which is outside this fix.
    private static func isTeardownCapabilityRefusal(_ detail: String) -> Bool {
        detail.contains("no verified Worker termination hook")
            || detail.contains("no verified shutdown hook")
    }
}
