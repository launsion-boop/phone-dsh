// SPDX-License-Identifier: MIT

#if DEBUG
import SwiftUI
import PhoneDSHBot

/// Fixture-only gallery used by `scripts/ci/bot-ui` screenshots. Every
/// lifecycle state is rendered at the same size so a reviewer can compare the
/// native renderer against the upstream dsh-bot reference state by state.
/// Each tile is static (`still: true`) to keep the 42-avatar grid cheap.
struct BotFishGalleryView: View {
    static let states: [BotFishLifecycle] = [
        .idle, .thinking, .streaming, .working, .sleeping,
        .alerting, .listening, .speaking, .happy, .sad,
        .surprised, .confused, .laughing, .love, .angry,
        .wink, .nod, .shrug, .celebrate, .poke,
        .waking, .waiting, .loading, .done, .standby,
        .spawning, .bouncing, .dancing, .waving,
        .shy, .smug, .crying, .sighing, .cheering,
        .bowing, .shakingHead, .clapping, .stretching, .yawning,
        .kiss, .highFive, .poweringDown,
    ]

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(Self.states, id: \.rawValue) { state in
                    VStack(spacing: 4) {
                        BotFishView(state: state, size: 96, still: true)
                        Text(state.rawValue)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(HomeSpec.textSecondary)
                            .lineLimit(1)
                    }
                    .accessibilityIdentifier("bot.fish.gallery.\(state.rawValue)")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .background(HomeSpec.page)
        .accessibilityIdentifier("bot.fish.gallery")
    }
}
#endif
