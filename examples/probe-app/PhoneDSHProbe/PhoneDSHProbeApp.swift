// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — iOS Phase 0 probe app (PLAN W3-APP).
//
// Entry point. The app has five pages: Probes (the W3-PROBES suite on the
// device UI actor), Memory (real PhoneDSHHost boots with 20/50/100 MB
// synthetic overlays and a scripted session), Background (the background/lock
// matrix), Screen (the black low-brightness task screen) and Export (the
// aggregated JSON report).
//
// Every device-only number starts empty: nothing here claims iPhone behaviour
// until a run on a device records it.

import SwiftUI
import PhoneDSH

@main
struct PhoneDSHProbeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel()

    init() {
        #if DEBUG
        Self.seedProviderFromEnvironment()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // The native shell is a light design (hard-coded ink and
                // surface colors); without this the system's dark appearance
                // turns the page background black under a light layout.
                .preferredColorScheme(.light)
                .environment(model)
                .onChange(of: scenePhase) { _, newPhase in
                    Task { await model.scenePhaseChanged(newPhase) }
                }
                .task {
                    model.refreshLockdown()
                }
        }
    }
}

#if DEBUG
extension PhoneDSHProbeApp {
    /// 调试用:从环境变量一次性写入模型服务与密钥,避免把密钥敲进界面。
    /// 只在值变化时写,正常启动什么都不做。
    static func seedProviderFromEnvironment() {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["PDSH_SEED_PROVIDER_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return }
        let base = env["PDSH_SEED_PROVIDER_BASE"] ?? "https://api.deepseek.com/anthropic"
        let model = env["PDSH_SEED_PROVIDER_MODEL"] ?? "deepseek-chat"
        let name = env["PDSH_SEED_PROVIDER_NAME"] ?? "DeepSeek"
        let store = PhoneModelProviderSettings.shared
        let profile = ProviderProfile(id: "deepseek", displayName: name, baseURL: base, model: model)
        _ = try? store.upsert(profile, apiKey: key)
        try? store.select(id: profile.id)
    }
}
#endif
