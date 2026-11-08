// SPDX-License-Identifier: MIT
// HomeTabBar: the bottom menu from the home design spec. Four equal columns,
// a 28pt icon box over a 10.5pt medium label; the selected tab uses the
// filled glyph in #1A1A1A, the others the outline glyph in #888888. The bar
// shares the page color and draws no top divider or blur.

import SwiftUI

enum HomeTab: String, CaseIterable, Identifiable {
    case bot, tasks, discover, me

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bot: return "Bot"
        case .tasks: return "DSH"
        case .discover: return "发现"
        case .me: return "我的"
        }
    }

    /// Outline glyph for the resting tab, filled glyph for the selected one.
    /// Bot draws the dsh-bot fish (`FishGlyph`) and DSH the DeepSeek logo,
    /// so neither has a symbol.
    func symbol(selected: Bool) -> String? {
        switch self {
        case .bot, .tasks: return nil
        case .discover: return selected ? "safari.fill" : "safari"
        case .me: return selected ? "person.fill" : "person"
        }
    }
}

/// The Bot tab's mark: dsh-bot's `IconFish` glyph (body, forked tail, eye) in
/// its 16-unit box. The resting tab strokes it; the selected tab fills the
/// body with the eye cut out.
struct FishGlyph: View {
    var filled: Bool

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 16
            let transform = CGAffineTransform(scaleX: scale, y: scale)
            let body = Self.bodyPath.applying(transform)
            let tail = Self.tailPath.applying(transform)
            let eye = Path(ellipseIn: CGRect(x: 5.15, y: 6.65, width: 1.3, height: 1.3)).applying(transform)
            let stroke = StrokeStyle(lineWidth: 1.4 * scale, lineCap: .round, lineJoin: .round)
            if filled {
                var cutout = body
                cutout.addPath(eye)
                context.fill(cutout, with: .foreground, style: FillStyle(eoFill: true))
                context.stroke(body, with: .foreground, style: stroke)
            } else {
                context.stroke(body, with: .foreground, style: stroke)
                context.fill(eye, with: .foreground)
            }
            context.stroke(tail, with: .foreground, style: stroke)
        }
        .accessibilityHidden(true)
    }

    private static let bodyPath: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 1.9, y: 8))
        p.addCurve(to: CGPoint(x: 7.6, y: 4.6), control1: CGPoint(x: 3.3, y: 5.9), control2: CGPoint(x: 5.3, y: 4.6))
        p.addCurve(to: CGPoint(x: 13.5, y: 8), control1: CGPoint(x: 10, y: 4.6), control2: CGPoint(x: 12, y: 5.9))
        p.addCurve(to: CGPoint(x: 7.6, y: 11.4), control1: CGPoint(x: 12, y: 10.1), control2: CGPoint(x: 10, y: 11.4))
        p.addCurve(to: CGPoint(x: 1.9, y: 8), control1: CGPoint(x: 5.3, y: 11.4), control2: CGPoint(x: 3.3, y: 10.1))
        p.closeSubpath()
        return p
    }()

    private static let tailPath: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 13.2, y: 8))
        p.addLine(to: CGPoint(x: 15, y: 5.6))
        p.move(to: CGPoint(x: 13.2, y: 8))
        p.addLine(to: CGPoint(x: 15, y: 10.4))
        return p
    }()
}

struct HomeTabBar: View {
    @Binding var selection: HomeTab
    /// The home-indicator inset measured by the shell; the bar is 50pt of
    /// content plus this, and paints all of it in the page color.
    var bottomInset: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            ForEach(HomeTab.allCases) { tab in
                let selected = tab == selection
                Button {
                    guard tab != selection else { return }
                    selection = tab
                } label: {
                    // Spec positions from the bar top (the composer's bottom
                    // edge): a 28pt icon box centred 28pt down (≈22pt glyph,
                    // its ink starting ~17pt below the composer), then the
                    // 10.5pt label whose baseline sits 54pt down. The label
                    // runs a few points into the home-indicator area, exactly
                    // as in the reference, so the block reads lifted, not sunk.
                    VStack(spacing: 1) {
                        Group {
                            if let symbol = tab.symbol(selected: selected) {
                                Image(systemName: symbol)
                                    .font(.system(size: 23, weight: .regular))
                            } else if tab == .tasks {
                                Image("DeepSeekLogo")
                                    .renderingMode(.template)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 25, height: 25)
                            } else {
                                FishGlyph(filled: selected)
                                    .frame(width: 27, height: 27)
                            }
                        }
                        .frame(width: HomeSpec.tabIcon, height: HomeSpec.tabIcon)
                        Text(tab.title)
                            .font(.system(size: HomeSpec.tabLabelSize, weight: .medium))
                            .frame(height: 14)
                    }
                    .padding(.top, 14)
                    .foregroundStyle(selected ? HomeSpec.textPrimary : HomeSpec.textPlaceholder)
                    .frame(maxWidth: .infinity)
                    .frame(height: HomeSpec.tabBarHeight + bottomInset, alignment: .top)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .background(HomeSpec.page)
    }
}
