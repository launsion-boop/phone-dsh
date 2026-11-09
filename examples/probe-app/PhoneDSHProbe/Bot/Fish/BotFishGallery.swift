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

/// Animated companion to the still grid: the five runtime states whose motion
/// the acceptance run samples three times. It lives in the capture app only.
struct BotFishDynamicGalleryView: View {
    static let states: [BotFishLifecycle] = [
        .thinking, .working, .speaking, .alerting, .celebrate,
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(Self.states, id: \.rawValue) { state in
                    HStack(spacing: 16) {
                        BotFishView(state: state, size: 88)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.rawValue)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(HomeSpec.textPrimary)
                            Text("animated")
                                .font(.system(size: 12))
                                .foregroundStyle(HomeSpec.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 20)
                    .accessibilityIdentifier("bot.fish.dynamic.\(state.rawValue)")
                }
            }
            .padding(.vertical, 16)
        }
        .background(HomeSpec.page)
        .accessibilityIdentifier("bot.fish.dynamic")
    }
}

#endif
