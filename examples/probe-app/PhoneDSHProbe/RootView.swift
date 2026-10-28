// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — native iPhone workspace.

import SwiftUI

struct RootView: View {
    @State private var web = WebHostModel.shared
    @State private var chat = ChatModel.shared

    var body: some View {
        ZStack {
            if web.mode == .nativeRecovery {
                NativeShell()
            } else {
                // The complete DSH page is the default surface; the Web view
                // itself fills the screen under the safe areas.
                WebSurfacePage(engine: web.engine)
                    .ignoresSafeArea()
            }
        }
        // WebKit's worker must remain attached while the Web page is visible.
        // The engine is re-parented from this anchor into the full-screen
        // surface once the host boots.
        .overlay(alignment: .bottomTrailing) {
            // Only the surface that owns a host keeps its engine anchor in the
            // window. The other model is stopped, so it has nothing to attach.
            VisibleAnchorView(anchor: web.mode == .web ? web.anchor : chat.anchor)
                .frame(width: 2, height: 2)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .overlay {
            if web.mode == .web, web.engine == nil, web.lastError == nil {
                startupOverlay
            }
        }
        .overlay(alignment: .top) {
            if web.mode == .web, let message = web.lastError {
                errorBanner(message)
            }
        }
        .sheet(isPresented: Binding(
            get: { web.modelSettingsPresented },
            set: { web.modelSettingsPresented = $0 }
        )) {
            NavigationStack {
                ModelProviderSettingsPage(host: .web)
            }
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: Binding(
            get: { web.searchSettingsPresented },
            set: { web.searchSettingsPresented = $0 }
        )) {
            NavigationStack {
                WebSearchSettingsPage(host: .web)
            }
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: Binding(
            get: { web.mcpSettingsPresented },
            set: { presented in
                web.mcpSettingsPresented = presented
                if !presented { web.mcpSettingsDraft = nil }
            }
        )) {
            NavigationStack {
                MCPSettingsPage(host: .web, draft: web.mcpSettingsDraft)
            }
            .presentationDragIndicator(.visible)
        }
        .task { await web.start() }
    }

    /// The explicit, user-visible recovery path. It is not a debug panel: it
    /// switches the one host to the native Chat page after stopping Web.
    /// Product copy while the local Worker and the complete page start. No
    /// console/log line is surfaced here; diagnostics stay in the debug build.
    private var startupOverlay: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            VStack(spacing: 5) {
                Text("正在准备本地引擎")
                    .font(.headline)
                Text(web.statusLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("模型服务设置") {
                web.modelSettingsPresented = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(28)
        .frame(maxWidth: 340)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 24, y: 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(spacing: 10) {
            Text("本地页面暂时打不开。")
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("可以重试、检查模型服务配置，或切换到原生恢复界面。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
#if DEBUG
            Text(message)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
#endif
            HStack(spacing: 10) {
                Button("重试") {
                    Task { await web.start() }
                }
                .buttonStyle(.borderedProminent)
                Button("模型配置") {
                    web.modelSettingsPresented = true
                }
                .buttonStyle(.bordered)
                Button("原生恢复") {
                    Task { await web.enterNativeRecovery() }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}
