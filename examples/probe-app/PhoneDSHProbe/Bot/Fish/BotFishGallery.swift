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
                            Text(state.galleryDisplayName)
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
                Text("动作与表情")
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
                        Text(reaction.galleryDisplayName)
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
                Text("主 Bot")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(HomeSpec.textPrimary)
                Text("皇冠行")
                    .font(.system(size: 11))
                    .foregroundStyle(HomeSpec.textSecondary)
            }
            LazyVGrid(columns: crownedColumns, spacing: 12) {
                ForEach(Self.crownedStates, id: \.rawValue) { state in
                    VStack(spacing: 4) {
                        BotFishView(state: state, size: 96, crowned: true, still: true)
                        Text(state.galleryDisplayName)
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
            Text("空闲 \(Int(size))pt")
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
/// Each state shows the existing 88pt standard fish next to the old
/// status-line size (28pt standard) and the new 28pt `.lively` fish, so the
/// three-frame burst can compare per-tile frame deltas directly.
struct BotFishDynamicGalleryView: View {
    static let states: [BotFishLifecycle] = [
        .thinking, .working, .speaking, .alerting, .celebrate,
    ]
    static let workStyles: [BotFishWorkStyle] = [
        .generic, .reading, .searching, .running, .writing,
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("standard 88pt · standard 28pt · lively 28pt")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(HomeSpec.textSecondary)
                    .padding(.horizontal, 20)
                ForEach(Self.states, id: \.rawValue) { state in
                    HStack(alignment: .top, spacing: 12) {
                        tile(state: state, size: 88, profile: .standard,
                             style: .generic, caption: "std 88", width: 88)
                        tile(state: state, size: 28, profile: .standard,
                             style: .generic, caption: "std 28", width: 58)
                        if state == .celebrate {
                            livelyCelebrationTile
                        } else {
                            tile(state: state, size: 28, profile: .lively,
                                 style: .generic, caption: "lively", width: 58)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.galleryDisplayName)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(HomeSpec.textPrimary)
                            Text("动画")
                                .font(.system(size: 12))
                                .foregroundStyle(HomeSpec.textSecondary)
                        }
                        .padding(.top, 8)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 20)
                    .accessibilityIdentifier("bot.fish.dynamic.\(state.rawValue)")
                }
                Text("lively working styles · 28pt")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(HomeSpec.textSecondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 2)
                HStack(alignment: .top, spacing: 8) {
                    ForEach(Self.workStyles, id: \.self) { style in
                        tile(state: .working, size: 28, profile: .lively,
                             style: style, caption: style.rawValue, width: 58)
                    }
                }
                .padding(.horizontal, 20)
                .accessibilityIdentifier("bot.fish.dynamic.workstyles")
            }
            .padding(.vertical, 12)
        }
        .background(HomeSpec.page)
        .accessibilityIdentifier("bot.fish.dynamic")
    }

    /// `celebrate` is a one-shot 1.2s clip (it holds its happy final pose for
    /// the exit animation). The capture burst lands two seconds after launch,
    /// so for the gallery only, restart the view every 1.2s to keep sampling
    /// the hop itself.
    private var livelyCelebrationTile: some View {
        BotFishLivelyCelebrationTile(width: 58)
    }

    private func tile(state: BotFishLifecycle, size: CGFloat,
                      profile: BotFishMotionProfile, style: BotFishWorkStyle,
                      caption: String, width: CGFloat) -> some View {
        VStack(spacing: 3) {
            BotFishView(state: state, size: size, motionProfile: profile,
                        workStyle: style)
                .frame(width: size, height: size)
            Text(caption)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(HomeSpec.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: width)
        }
        .frame(width: width)
    }
}

private struct BotFishLivelyCelebrationTile: View {
    let width: CGFloat
    @State private var cycle = 0

    var body: some View {
        VStack(spacing: 3) {
            BotFishView(state: .celebrate, size: 28, motionProfile: .lively)
                .id(cycle)
                .frame(width: 28, height: 28)
            Text("lively")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(HomeSpec.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: width)
        }
        .frame(width: width)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled else { return }
                cycle &+= 1
            }
        }
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
                        }
                        LazyVGrid(columns: columns, spacing: 4) {
                            ForEach(Self.colors, id: \.rawValue) { color in
                                VStack(spacing: 1) {
                                    BotFishView(state: .idle, size: 40,
                                                appearance: Self.appearance(color: color,
                                                                            hairstyle: hairstyle),
                                                still: true)
                                    Text(color.displayName)
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

/// Capture-only Chinese labels. The raw enum stays in accessibility
/// identifiers, so the acceptance screenshots show product-language labels
/// instead of English enum values.
private extension BotFishLifecycle {
    var galleryDisplayName: String {
        switch self {
        case .idle: return "空闲"
        case .thinking: return "思考"
        case .streaming: return "输出中"
        case .working: return "工作中"
        case .sleeping: return "睡眠"
        case .alerting: return "提醒"
        case .listening: return "聆听"
        case .speaking: return "说话"
        case .happy: return "开心"
        case .sad: return "难过"
        case .surprised: return "惊讶"
        case .confused: return "困惑"
        case .laughing: return "大笑"
        case .love: return "喜爱"
        case .angry: return "生气"
        case .wink: return "眨眼"
        case .nod: return "点头"
        case .shrug: return "耸肩"
        case .celebrate: return "庆祝"
        case .poke: return "戳一下"
        case .waking: return "醒来"
        case .waiting: return "等待"
        case .loading: return "加载中"
        case .done: return "完成"
        case .standby: return "待机"
        case .spawning: return "出现"
        case .bouncing: return "弹跳"
        case .dancing: return "跳舞"
        case .waving: return "挥手"
        case .shy: return "害羞"
        case .smug: return "得意"
        case .crying: return "哭泣"
        case .sighing: return "叹气"
        case .cheering: return "欢呼"
        case .bowing: return "鞠躬"
        case .clapping: return "鼓掌"
        case .stretching: return "伸展"
        case .yawning: return "打哈欠"
        case .kiss: return "飞吻"
        case .shakingHead: return "摇头"
        case .highFive: return "击掌"
        case .poweringDown: return "关机"
        }
    }
}

private extension BotFishReaction {
    var galleryDisplayName: String {
        switch name {
        case "waving": return "挥手"
        case "bowing": return "鞠躬"
        case "clapping": return "鼓掌"
        case "kiss": return "飞吻"
        case "cheering": return "欢呼"
        case "shy": return "害羞"
        case "smug": return "得意"
        case "crying": return "哭泣"
        case "sighing": return "叹气"
        case "shaking-head": return "摇头"
        case "stretching": return "伸展"
        case "yawning": return "打哈欠"
        case "high-five": return "击掌"
        case "nod": return "点头"
        case "celebrate": return "庆祝"
        case "dancing": return "跳舞"
        case "happy": return "开心"
        case "sad": return "难过"
        case "surprised": return "惊讶"
        case "confused": return "困惑"
        case "laughing": return "大笑"
        case "love": return "喜爱"
        case "angry": return "生气"
        case "wink": return "眨眼"
        default: return name
        }
    }
}

#endif
