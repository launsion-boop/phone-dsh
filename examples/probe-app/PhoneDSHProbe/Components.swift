// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — iOS Phase 0 probe app (PLAN W3-APP).
//
// Small shared views: the Lockdown Mode indicator, the one-point host anchor
// the WKWebView engine attaches to, and status chips.

import ProbeKit
import SwiftUI
import PhoneDSH

/// Lockdown Mode indicator. Reads the system flag; it is never a guess.
struct LockdownBadge: View {
    let lockdown: DeviceReportLockdown

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: lockdown.enabled ? "lock.shield.fill" : "lock.open")
                .foregroundStyle(lockdown.enabled ? .red : .secondary)
            Text(lockdown.enabled
                 ? "Lockdown Mode ON — local harness unavailable"
                 : "Lockdown Mode off")
                .font(.caption2)
                .foregroundStyle(lockdown.enabled ? .red : .secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(lockdown.enabled
                           ? Color.red.opacity(0.12)
                           : Color.secondary.opacity(0.10)))
        .accessibilityLabel(lockdown.enabled
                            ? "Lockdown Mode is on; the local DSH harness is unavailable"
                            : "Lockdown Mode is off")
    }
}

/// The one-point transparent view a `WebEngine` attaches its WKWebView to.
///
/// The engine requires a window-attached view of at least one point; the App
/// keeps this view in the page hierarchy for the whole host lifetime. SwiftUI
/// does not call `makeUIView` again when only the anchor changes, so the
/// representable owns a small container and `updateUIView` swaps the host
/// anchor inside it. That is what lets the Web surface hand the window from
/// `WebHostModel` to `ChatModel` (and back) without either host booting
/// against a detached view.
struct VisibleAnchorView: UIViewRepresentable {
    let anchor: VisibleEngineAnchor

    final class Coordinator {
        var installedAnchor: VisibleEngineAnchor?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
        container.backgroundColor = .clear
        container.isUserInteractionEnabled = false
        container.isAccessibilityElement = false
        install(anchor, in: container)
        context.coordinator.installedAnchor = anchor
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard context.coordinator.installedAnchor !== anchor else { return }
        let previous = context.coordinator.installedAnchor
        // Detach the old host first: the old engine has already been stopped
        // by the surface switch, so this only removes an inert anchor view.
        uiView.subviews.forEach { $0.removeFromSuperview() }
        install(anchor, in: uiView)
        context.coordinator.installedAnchor = anchor
        previous?.refreshAttachment()
    }

    private func install(_ anchor: VisibleEngineAnchor, in container: UIView) {
        let view = anchor.view
        view.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
        view.translatesAutoresizingMaskIntoConstraints = true
        container.addSubview(view)
        anchor.refreshAttachment()
    }
}

/// PASS / FAIL / INFO chip.
struct ProbeStatusChip: View {
    let status: ProbeStatus

    private var color: Color {
        switch status {
        case .pass: return .green
        case .fail: return .red
        case .info: return .orange
        }
    }

    var body: some View {
        Text(status.rawValue)
            .font(.caption2.weight(.bold))
            .monospaced()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }
}

/// Section header used by the pages.
struct PageSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(.secondarySystemBackground)))
    }
}

/// A key/value line.
struct KeyValueLine: View {
    let key: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption.monospaced())
                .multilineTextAlignment(.trailing)
        }
    }
}

/// 代码块只有这一处实现:两路径都引它,免得标签位置、底色、内边距各改一半。
struct DSSCodeBlock: View {
    let source: String
    var language: String = ""

    private var hasHeader: Bool { !language.isEmpty }

    var body: some View {
        // 顶部行的两个元素都用绝对定位钉住(overlay + 明确的 top/leading),
        // 不参与布局流,避免被代码文本的行带带走。
        ScrollView(.horizontal, showsIndicators: false) {
            Text(source)
                .font(.system(size: 13, design: .monospaced))
                .lineSpacing(20 - 16)
                .textSelection(.enabled)
                .lineLimit(nil)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 12)
        .padding(.top, hasHeader ? 44 : 12)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 246 / 255, green: 246 / 255, blue: 248 / 255),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .topLeading) {
            if hasHeader {
                Text(language)
                    .font(.system(size: 12))
                    .foregroundStyle(ChatPage.inkSecondary)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.leading, 12)
                    .padding(.top, 12)
            }
        }
        .overlay(alignment: .topTrailing) {
            if hasHeader {
                Button("拷贝") { UIPasteboard.general.string = source }
                    .font(.system(size: 13))
                    .foregroundStyle(ChatPage.accent)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.trailing, 12)
                    .padding(.top, 11)
            }
        }
    }
}
