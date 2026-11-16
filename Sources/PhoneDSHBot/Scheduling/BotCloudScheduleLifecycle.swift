// SPDX-License-Identifier: MIT

import Foundation

/// Per-Bot production bridge for the three lifecycle signals the cloud client
/// needs but cannot observe itself: scene phase, account token update, and
/// logout/invalidation. The App composition owns one instance per Bot unit
/// next to `CloudScheduleClient`; it must call these from the real scene/account
/// observers, not from tests.
public actor BotCloudScheduleLifecycle {
    private let client: CloudScheduleClient
    private var appActive: Bool
    /// The bridge refuses to re-arm on foreground while the account is signed
    /// out; only a confirmed sign-in/refresh sets this back to true.
    private var signedIn: Bool

    public init(client: CloudScheduleClient, appActive: Bool = false,
                signedIn: Bool = true) {
        self.client = client
        self.appActive = appActive
        self.signedIn = signedIn
    }

    /// `active` = App foreground/usable. Background stops polling immediately;
    /// leases stay with the cloud and are reconciled after the next activation.
    public func scenePhaseChanged(_ active: Bool) async {
        appActive = active
        if active, signedIn {
            await client.activate()
        } else {
            await client.deactivate()
        }
    }

    /// Called only after the existing account SDK confirms a usable token
    /// (sign-in or successful refresh). Never called from a retry timer.
    public func credentialsDidChange(signedIn nextSignedIn: Bool) async {
        signedIn = nextSignedIn
        if nextSignedIn {
            await client.credentialsDidChange()
        } else {
            await client.credentialsInvalidated()
        }
    }

    /// Routine consent edits still go straight to the client in production;
    /// this exists so the composition has one lifecycle object to keep.
    public func schedulesChanged() async {
        await client.noteSchedulesChanged()
    }

    public func isAppActive() -> Bool { appActive }
}
