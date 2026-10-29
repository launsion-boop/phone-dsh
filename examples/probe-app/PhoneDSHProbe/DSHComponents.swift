// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — small DSH-web-aligned presentation pieces.

import SwiftUI

/// The DSH web `TextShimmer`: a highlight band swept across the glyphs of one
/// line. The base text keeps its own color; a brighter copy is masked by a
/// moving 105° gradient (transparent → opaque 40–60% → transparent).
struct ShimmerText: View {
    let text: String
    let active: Bool
    var font: Font = .system(size: 13)
    var color: Color = .secondary

    @State private var phase: CGFloat = -1

    var body: some View {
        ZStack(alignment: .leading) {
            Text(text)
                .font(font)
                .lineLimit(1)
                .foregroundStyle(color)
            if active {
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                    .mask {
                        GeometryReader { proxy in
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .black, location: 0.4),
                                    .init(color: .black, location: 0.6),
                                    .init(color: .clear, location: 1),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: proxy.size.width)
                            .offset(x: phase * proxy.size.width)
                        }
                    }
                    .allowsHitTesting(false)
            }
        }
        .onAppear { startIfNeeded() }
        .onChange(of: active) { _, running in
            if running { startIfNeeded() } else { phase = -1 }
        }
    }

    private func startIfNeeded() {
        guard active else { return }
        phase = -1
        withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
            phase = 1
        }
    }
}

/// The DSH web `JsonBlock`: a `▾/▸ label` toggle over a pretty-printed JSON
/// body, capped at 20k characters, with a copy action from the app chrome.
struct DSHJsonBlock: View {
    let text: String
    @State private var open = false

    private var pretty: String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              JSONSerialization.isValidJSONObject(object),
              let encoded = try? JSONSerialization.data(withJSONObject: object,
                                                        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let string = String(data: encoded, encoding: .utf8) else { return nil }
        return string
    }

    var body: some View {
        if let pretty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Button {
                        open.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image("DSHChevronDown")
                                .resizable()
                                .renderingMode(.template)
                                .frame(width: 10, height: 10)
                                .rotationEffect(.degrees(open ? 0 : -90))
                            Text("结果")
                                .font(.system(size: 12))
                        }
                        .foregroundStyle(ChatPage.inkSecondary)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                    Button {
                        UIPasteboard.general.string = text
                    } label: {
                        Image("DSHCopy")
                            .resizable()
                            .renderingMode(.template)
                            .frame(width: 12, height: 12)
                            .foregroundStyle(ChatPage.inkSecondary)
                    }
                    .buttonStyle(.plain)
                }
                if open {
                    ScrollView([.horizontal, .vertical]) {
                        Text(pretty.count > 20_000 ? String(pretty.prefix(20_000)) + "\n…（共 \(pretty.count) 字符）" : pretty)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 280)
                }
            }
            .padding(.vertical, 6)
        } else {
            ScrollView([.horizontal, .vertical]) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 7)
            }
            .frame(maxHeight: 280)
        }
    }
}
