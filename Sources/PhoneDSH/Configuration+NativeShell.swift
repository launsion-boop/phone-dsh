// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — product embedding helpers for the native accelerators.
//
// The default `PhoneDSHConfiguration.accelerators` has no materialized mount
// and advertises nothing; an embedding app has to point the provider at the
// workspace log's materialized copy and copy the executable names into the
// HELLO caps. These helpers do both in one call and keep the provider identity
// of `PhoneDSHConfiguration.Equatable` correct by rebuilding the value through
// its designated initializer.

import Foundation
import PhoneDSHAgentCore
import PhoneDSHShell

public extension PhoneDSHConfiguration {
    /// The linked read-only accelerator provider over `workspaceRoot`.
    ///
    /// `workspaceRoot` is the `Library/xl/<workspace_id>/` log root; the
    /// provider mounts its `materialized/workspace` and `materialized/home`
    /// copies. When `toolBridge` is non-nil the `phone` / `ctx` accelerators
    /// are registered and advertised too; without it they are absent from both
    /// the provider and the HELLO caps.
    static func nativeAcceleratorProvider(
        workspaceRoot: URL,
        toolBridge: (any PhoneToolBridge)? = nil,
        limits: PDSHShellLimits = .default
    ) -> PDSHShellProvider {
        PDSHShellProvider(workspaceRoot: workspaceRoot,
                          limits: limits,
                          toolBridge: toolBridge)
    }

    /// A copy of this configuration with the native accelerator provider
    /// installed over ``workspaceRoot`` and its executable names advertised.
    ///
    /// Use it at the app's composition root:
    ///
    /// ```swift
    /// let configuration = base.enablingNativeAccelerators(toolBridge: mcpBridge)
    /// ```
    ///
    /// The returned value is built through the designated initializer, so its
    /// provider identity and `Equatable` semantics stay correct. Every other
    /// configuration field (engine, gateway, log, loopback, budgets) is
    /// preserved. A build without the linked XCFramework still returns the
    /// honest stub: no names are advertised and every run fails with
    /// ``PDSHShellError/notLinked``.
    func enablingNativeAccelerators(
        toolBridge: (any PhoneToolBridge)? = nil,
        limits: PDSHShellLimits = .default
    ) -> PhoneDSHConfiguration {
        let provider = Self.nativeAcceleratorProvider(
            workspaceRoot: workspaceRoot,
            toolBridge: toolBridge,
            limits: limits)
        var updated = PhoneDSHConfiguration(
            workspaceRoot: workspaceRoot,
            token: loopback.token,
            origin: engine.origin,
            deviceTier: deviceTier,
            bundle: bundle,
            allowedModelHosts: allowedModelHosts,
            egressAllowHosts: egressAllowHosts,
            replaySafeModelEndpoints: replaySafeModelEndpoints,
            handoff: handoff,
            credentialProvider: credentialProvider,
            execProvider: provider,
            acceleratorNames: provider.acceleratorNames,
            mcpLoopbackURL: mcpLoopbackURL,
            budgets: budgets,
            plannedRestartInterval: plannedRestartInterval,
            drainDeadline: drainDeadline,
            helloTimeout: helloTimeout,
            turnInactivityTimeout: turnInactivityTimeout,
            singleFileLimitBytes: singleFileLimitBytes)
        // Preserve caller tunings that the convenience initializer re-derives.
        updated.loopback = loopback
        updated.log = log
        updated.gateway = gateway
        updated.engine = engine
        updated.accelerators = provider
        return updated
    }
}
