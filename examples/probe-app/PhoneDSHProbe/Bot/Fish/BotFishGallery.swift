// SPDX-License-Identifier: MIT

#if DEBUG
import SwiftUI
import PhoneDSHBot

/// Fixture-only gallery used by `scripts/ci/bot-ui` screenshots. Every
/// lifecycle state is rendered at the same size so a reviewer can compare the
/// native renderer against the upstream dsh-bot reference state by state, and
/// a crowned section at the top exercises the main-Bot crown at 96pt plus the
/// 32pt/20pt buckets. Each tile is static (`still: true`) to keep the avatar
/// grid cheap.
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

    /// The four crowned states the capture flow checks at 96pt.
    static let crownedStates: [BotFishLifecycle] = [.idle, .thinking, .working, .happy]

    /// Every Agent-triggerable gesture/expression, one still tile each. The
    /// renderer freezes an action at a recognisable beat and a face at 650 ms,
    /// so a screenshot can verify the pose and the upright head direction.
    static let reactions: [BotFishReaction] = BotFishReactionVocabulary.reactions.compactMap { name in
        BotFishReaction.reaction(
            from: BotFishToolCall(id: "gallery-\(name)", name: "FishAction",
                                  arguments: .object(["action": .string(name)]),
                                  time: 0),
            now: 0)
    }

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 12)]
    private let crownedColumns = [GridItem(.adaptive(minimum: 96), spacing: 12)]
    private let reactionColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                crownedSection
                reactionsSection
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
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .background(HomeSpec.page)
        .accessibilityIdentifier("bot.fish.gallery")
    }

    /// One still tile per action/expression. Tiles are kept compact so the
    /// whole reaction grid and the beginning of the lifecycle grid fit the
    /// capture screen without scrolling.
    private var reactionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("reactions")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(HomeSpec.textPrimary)
                Text("FishAction · 一次性动作 / 表情")
                    .font(.system(size: 11))
                    .foregroundStyle(HomeSpec.textSecondary)
            }
            LazyVGrid(columns: reactionColumns, spacing: 8) {
                ForEach(Self.reactions) { reaction in
                    VStack(spacing: 2) {
                        BotFishView(state: .idle, size: 64, still: true, reaction: reaction)
                        Text(reaction.name)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(HomeSpec.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("reaction \(reaction.name)")
                    .accessibilityIdentifier("bot.fish.gallery.reaction.\(reaction.name)")
                }
            }
        }
        .accessibilityIdentifier("bot.fish.gallery.reactions")
    }

    /// The main-Bot crown row: idle/thinking/working/happy at 96pt, then the
    /// same idle fish at 32pt and 20pt to expose the small-size crown bucket
    /// (both use upstream's ≤40pt 250/138 box/baseline).
    private var crownedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("crowned")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(HomeSpec.textPrimary)
                Text("主 Bot · 皇冠行")
                    .font(.system(size: 11))
                    .foregroundStyle(HomeSpec.textSecondary)
            }
            LazyVGrid(columns: crownedColumns, spacing: 12) {
                ForEach(Self.crownedStates, id: \.rawValue) { state in
                    VStack(spacing: 4) {
                        BotFishView(state: state, size: 96, crowned: true, still: true)
                        Text(state.rawValue)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(HomeSpec.textSecondary)
                            .lineLimit(1)
                    }
                    .accessibilityIdentifier("bot.fish.gallery.crowned.\(state.rawValue)")
                }
                crownedSmall(size: 32)
                crownedSmall(size: 20)
            }
        }
        .accessibilityIdentifier("bot.fish.gallery.crowned")
    }

    private func crownedSmall(size: CGFloat) -> some View {
        VStack(spacing: 4) {
            BotFishView(state: .idle, size: size, crowned: true, still: true)
                .frame(width: 96, height: 96)
            Text("idle \(Int(size))pt")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(HomeSpec.textSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("crowned idle \(Int(size))pt")
        .accessibilityIdentifier("bot.fish.gallery.crowned.\(Int(size))")
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

/// The 15 colours × 4 hairstyles appearance grid used by the capture flow.
/// Every tile is a 40pt idle still so the caller can compare each combination
/// one-by-one against the desktop DSH bot. Tiles are grouped by hairstyle and
/// laid out five per row; the whole grid fits one phone screen in portrait.
struct BotFishAppearanceGalleryView: View {
    static let hairstyles: [BotFishHairstyle] = BotFishHairstyle.allCases
    static let colors: [BotFishColor] = BotFishColor.allCases

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 5)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Self.hairstyles, id: \.rawValue) { hairstyle in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(hairstyle.displayName)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(HomeSpec.textPrimary)
                            Text(hairstyle.rawValue)
                                .font(.system(size: 10))
                                .foregroundStyle(HomeSpec.textSecondary)
                        }
                        LazyVGrid(columns: columns, spacing: 4) {
                            ForEach(Self.colors, id: \.rawValue) { color in
                                VStack(spacing: 1) {
                                    BotFishView(state: .idle, size: 40,
                                                appearance: Self.appearance(color: color,
                                                                            hairstyle: hairstyle),
                                                still: true)
                                    Text(color.rawValue)
                                        .font(.system(size: 8))
                                        .foregroundStyle(HomeSpec.textSecondary)
                                        .lineLimit(1)
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("\(hairstyle.displayName) \(color.displayName)")
                                .accessibilityIdentifier("bot.fish.appearance.\(hairstyle.rawValue).\(color.rawValue)")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(HomeSpec.page)
        .accessibilityIdentifier("bot.fish.appearance")
    }

    /// Builds each tile through the additive public initialiser that the
    /// profile contract exposes for the appearance editor and gallery.
    private static func appearance(color: BotFishColor,
                                   hairstyle: BotFishHairstyle) -> BotFishAppearance {
        BotFishAppearance(color: color, hairstyle: hairstyle,
                          autoColor: false, autoHairstyle: false)
    }
}

#endif
