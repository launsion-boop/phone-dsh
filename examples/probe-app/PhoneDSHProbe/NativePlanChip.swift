// SPDX-License-Identifier: MIT
// NativePlanChip — the official composer plan-mode chip
// (`conversation.input.plan`), rendered natively for the 402pt session page.
//
// Official baseline: deepseek-harness 7be5505b0b (0.2.1-rc.2)
//   packages/client/ui-plan/src/client/PlanModeControl.tsx + .module.css
//   packages/client/ui-plan/src/client/locales.ts
//
// Geometry: 28pt tall, min-width 34, radius 8, padding 0/8, internal gap 4,
// 14pt glyph, label 13/20 w500, fill `state-business-tertiary`
// (#E4EDFD / #34415B), ink `state-business-primary` (#4176E6 / #7AAAFF),
// pressed/hover ink-mix 6%, disabled opacity 0.6. The chip renders only while
// the host's folded plan projection targets plan mode
// (`pending ? !active : active`) and executes `/plan off`.

import SwiftUI

/// The host `plan` projection (`packages/plan/plan-mode/src/types.ts`).
public struct NativePlanModeState: Equatable {
    public var active: Bool
    public var pending: Bool

    public init(active: Bool, pending: Bool) {
        self.active = active
        self.pending = pending
    }

    /// Official effective target: plan mode is on (or is being entered) unless a
    /// pending switch is already turning it off. The chip renders only then.
    public var isPlanTarget: Bool {
        pending ? !active : active
    }
}

/// Composer control-row chip that turns plan mode off.
public struct NativePlanChip: View {
    /// Official `chip.label`.
    public static let label = "计划"
    /// Official `chip.on.aria`.
    public static let accessibilityLabelText = "计划模式已开启，按下关闭"
    /// Official `chip.on.title`.
    public static let accessibilityHintText = "计划模式已开启 — 点击关闭（/plan off）"
    /// Official `chip.exitFailed`; shown beside the chip when `/plan off` fails.
    public static let exitFailureText = "退出计划模式失败"

    private let mode: NativePlanModeState
    private let isLocked: Bool
    private let isLeaving: Bool
    private let errorDetail: String?
    private let errorText: String?
    private let onExit: () -> Void
    @State private var hovering = false

    /// - Parameters:
    ///   - mode: host `plan` projection; the chip renders nothing when the
    ///     effective target is not plan mode.
    ///   - isLocked: owner-driven lock (e.g. a question is pending).
    ///   - isLeaving: `/plan off` is in flight.
    ///   - errorDetail: raw host failure (kept out of the visible copy, exposed
    ///     to VoiceOver).
    ///   - errorText: overrides the visible failure copy; defaults to
    ///     「退出计划模式失败」.
    ///   - onExit: executes `/plan off`.
    public init(mode: NativePlanModeState,
                isLocked: Bool = false,
                isLeaving: Bool = false,
                errorDetail: String? = nil,
                errorText: String? = nil,
                onExit: @escaping () -> Void) {
        self.mode = mode
        self.isLocked = isLocked
        self.isLeaving = isLeaving
        self.errorDetail = errorDetail
        self.errorText = errorText
        self.onExit = onExit
    }

    public var body: some View {
        if mode.isPlanTarget {
            HStack(spacing: 6) {
                chip
                if let copy = visibleErrorText {
                    failureLabel(copy)
                }
            }
        }
    }

    // MARK: - Chip

    private var isDisabled: Bool { isLocked || isLeaving }

    private var chip: some View {
        Button(action: onExit) {
            Text(Self.label)
        }
        .buttonStyle(NativePlanChipButtonStyle(hovering: hovering))
        .disabled(isDisabled)
        // Official `:disabled { opacity: .6 }`.
        .opacity(isDisabled ? 0.6 : 1)
        .onHover { hovering = $0 }
        .accessibilityLabel(Self.accessibilityLabelText)
        .accessibilityHint(Self.accessibilityHintText)
    }

    // MARK: - Failure line

    private var visibleErrorText: String? {
        if let errorText { return errorText }
        return errorDetail == nil ? nil : Self.exitFailureText
    }

    /// Official inline `span.error`: 12/18 `state-error-primary`, 6pt from the chip.
    private func failureLabel(_ copy: String) -> some View {
        Text(copy)
            .font(.system(size: 12))
            .foregroundStyle(NativeParityTokens.error)
            .lineLimit(1)
            .accessibilityLabel(copy)
            .accessibilityValue(errorDetail ?? "")
    }
}

// MARK: - Chip chrome

/// Draws the whole chip so the 14pt glyph can swap to the circled close on
/// press/hover (official `IconPlanOutline` → `IconCloseCircleFill`).
private struct NativePlanChipButtonStyle: ButtonStyle {
    let hovering: Bool

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let highlighted = hovering || configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: NativeParityTokens.radiusSM, style: .continuous)
        return HStack(spacing: 4) {
            ZStack {
                NativePlanGlyph()
                    .opacity(highlighted ? 0 : 1)
                NativePlanCloseCircleGlyph()
                    .opacity(highlighted ? 1 : 0)
            }
            .frame(width: 14, height: 14)
            .accessibilityHidden(true)
            configuration.label
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(NativeParityTokens.planChipInk)
        .padding(.horizontal, 8)
        .frame(minWidth: 34)
        .frame(height: 28)
        .background(
            shape
                // Official hover/press: color-mix(background, business-primary 6%).
                .fill(NativeParityTokens.planChipInk.opacity(highlighted ? 0.06 : 0))
                .background(NativeParityTokens.planChipBG, in: shape)
        )
        .contentShape(shape)
    }
}

// MARK: - Official glyphs (16-unit icon grid)

/// `IconPlanOutline` (`IconListPenOutline`): a page outline, two list rules and
/// the pen crossing the page's lower-right corner.
private struct NativePlanGlyph: View {
    var body: some View {
        ZStack {
            PlanPageShape()
                .stroke(style: StrokeStyle(lineWidth: 14.0 / 16.0,
                                           lineCap: .round,
                                           lineJoin: .round))
            PlanNibShape()
                .stroke(style: StrokeStyle(lineWidth: 14.0 * 2.0 / 16.0, lineCap: .round))
        }
    }

    private struct PlanPageShape: Shape {
        func path(in rect: CGRect) -> Path {
            let scale = min(rect.width, rect.height) / 16
            var path = Path()
            path.addRoundedRect(in: CGRect(x: 2 * scale,
                                           y: 1.33 * scale,
                                           width: 12 * scale,
                                           height: 13.34 * scale),
                                cornerSize: CGSize(width: 1.45 * scale, height: 1.45 * scale))
            path.move(to: CGPoint(x: 4.94 * scale, y: 5.9 * scale))
            path.addLine(to: CGPoint(x: 11.06 * scale, y: 5.9 * scale))
            path.move(to: CGPoint(x: 4.94 * scale, y: 9.03 * scale))
            path.addLine(to: CGPoint(x: 8.28 * scale, y: 9.03 * scale))
            return path
        }
    }

    private struct PlanNibShape: Shape {
        func path(in rect: CGRect) -> Path {
            let scale = min(rect.width, rect.height) / 16
            var path = Path()
            path.move(to: CGPoint(x: 9.4 * scale, y: 13.6 * scale))
            path.addLine(to: CGPoint(x: 13.2 * scale, y: 9.8 * scale))
            return path
        }
    }
}

/// `IconCloseCircleFill`: a 7-unit disc with the cross knocked out (even-odd),
/// so the cross takes the fill behind the glyph.
private struct NativePlanCloseCircleGlyph: View {
    var body: some View {
        CloseCircleShape()
            .fill(NativeParityTokens.planChipInk, style: FillStyle(eoFill: true))
    }

    private struct CloseCircleShape: Shape {
        func path(in rect: CGRect) -> Path {
            let scale = min(rect.width, rect.height) / 16
            var path = Path()
            path.addEllipse(in: CGRect(x: scale, y: scale, width: 14 * scale, height: 14 * scale))
            let cross: [(CGFloat, CGFloat)] = [
                (6.409, 10.652), (5.348, 9.591), (6.939, 8), (5.348, 6.409),
                (6.409, 5.348), (8, 6.939), (9.591, 5.348), (10.652, 6.409),
                (9.061, 8), (10.652, 9.591), (9.591, 10.652), (8, 9.061),
            ]
            for (index, point) in cross.enumerated() {
                let target = CGPoint(x: point.0 * scale, y: point.1 * scale)
                if index == 0 {
                    path.move(to: target)
                } else {
                    path.addLine(to: target)
                }
            }
            path.closeSubpath()
            return path
        }
    }
}

#if DEBUG
struct NativePlanChip_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Plan mode on (the resting state).
            NativePlanChip(mode: .init(active: true, pending: false)) {}
            // Entering plan mode: `pending` with `active == false` still targets plan.
            NativePlanChip(mode: .init(active: false, pending: true)) {}
            // `/plan off` in flight: still rendered, disabled at 60%.
            NativePlanChip(mode: .init(active: true, pending: false), isLeaving: true) {}
            // Locked by the owner (e.g. a pending question).
            NativePlanChip(mode: .init(active: true, pending: false), isLocked: true) {}
            // Failed `/plan off`: the 12/18 error line sits 6pt to the right.
            NativePlanChip(mode: .init(active: true, pending: false),
                           errorDetail: "exit plan mode failed (E_COMMAND)") {}
            // Leaving already applied (`pending` with `active == true`): nothing renders.
            NativePlanChip(mode: .init(active: true, pending: true)) {}
            // Not in plan mode: nothing renders.
            NativePlanChip(mode: .init(active: false, pending: false)) {}
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(Color(.systemGroupedBackground))
        .previewLayout(.sizeThatFits)
        .previewDisplayName("计划 chip：静息 / 进入中 / 退出中 / 锁定 / 失败 / 隐藏两态")
    }
}

struct NativePlanChipDark_Previews: PreviewProvider {
    static var previews: some View {
        NativePlanChip(mode: NativePlanModeState(active: true, pending: false)) {}
            .padding(24)
            .background(Color(.systemGroupedBackground))
            .preferredColorScheme(.dark)
            .previewLayout(.sizeThatFits)
            .previewDisplayName("计划 chip：深色")
    }
}
#endif
