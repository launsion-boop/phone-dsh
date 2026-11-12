// SPDX-License-Identifier: MIT
// phone-dsh — PhoneDSHGateway: model-purpose execution point.
//
// P26 §2.10 (spec/bot/v1/README.md) and PC-20261113-p12-model-purpose-sink
// freeze two branches at the host's single model-request entry:
//
//   purpose present -> the one frozen enforcer (`BotModelPurposeGate` in
//                      `PhoneDSHAgentCore`) decides; allow forwards the
//                      exchange, deny refuses it before credentials or sockets.
//   purpose absent  -> one host-internal `purpose_absent` diagnostic and the
//                      exchange behaves exactly like the baseline. Never
//                      fail closed: a request without purpose evidence is not
//                      denied, and no default purpose is invented.
//
// There is no wire carrier for a purpose (the proposed header was vetoed), so
// a purpose can only come from host composition. The default deployment
// installs no provider and therefore takes the absent branch.

import Foundation
import PhoneDSHAgentCore

/// Host-composition seam that supplies the purpose evidence for one
/// `/v1/http` exchange.
///
/// `GatewayRequest` keeps only method/url/headers/body; no purpose header or
/// field exists (spec/v1/gateway-security.md, P05 has no delta). An
/// implementation returns the evidence the enforcer needs — the purpose and
/// the model the request is about — or `nil` when this exchange carries no
/// purpose. It must never infer a purpose from the model name, the URL or the
/// body: that would be a second policy authority (§2.10).
public protocol ModelPurposeProviding: Sendable {
    /// The policy evidence for this request, or `nil` for the absent branch.
    func modelPurposeEvidence(for request: GatewayRequest) -> BotModelRequest?
}

/// The frozen two-branch outcome of the execution point. There is no third
/// branch: absence never denies and presence never skips the enforcer.
enum ModelPurposeDecision: Sendable {
    /// No evidence: record one `purpose_absent` diagnostic, change nothing.
    case absent
    /// Evidence exists and the frozen enforcer allowed it.
    case allowed(model: String)
    /// Evidence exists and the frozen enforcer refused it; the exchange is not
    /// sent. The error is the enforcer's own frozen `BotModelPurposeError`
    /// (`EPURPOSE_MODEL_DENIED` / `EPURPOSE_MODEL_REQUIRED`), so P05 gains no
    /// second error code.
    case denied(BotModelPurposeError)
}

/// Calls the one frozen enforcer at the `/v1/http` entry.
///
/// The policy is the frozen table in `PhoneDSHAgentCore`
/// (`BotModelPurposePolicy.frozen`): the gateway must not carry a copy
/// (AGENTS.md §2.1). A profile-provided policy would be a new P26/P05
/// decision, not something this execution point may add.
struct ModelPurposeExecutionPoint: Sendable {
    let provider: (any ModelPurposeProviding)?
    private let gate: BotModelPurposeGate

    init(provider: (any ModelPurposeProviding)?) {
        self.provider = provider
        self.gate = BotModelPurposeGate()
    }

    func decide(_ request: GatewayRequest) -> ModelPurposeDecision {
        guard let evidence = provider?.modelPurposeEvidence(for: request) else {
            return .absent
        }
        do {
            return .allowed(model: try gate.authorize(evidence))
        } catch let denial as BotModelPurposeError {
            return .denied(denial)
        } catch {
            // `authorize` throws only `BotModelPurposeError`; a foreign error
            // is still a refusal, never an allow. Re-wrap it with the frozen
            // denial code instead of forwarding an unknown error shape.
            return .denied(BotModelPurposeError(
                code: "EPURPOSE_MODEL_DENIED",
                purpose: evidence.purpose ?? .workerTurn,
                model: evidence.model,
                message: error.localizedDescription))
        }
    }
}
