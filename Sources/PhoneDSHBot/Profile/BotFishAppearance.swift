// SPDX-License-Identifier: MIT

import Foundation

/// The fifteen coat colours the desktop DSH bot exposes.
///
/// The declaration order is the seed order exported in
/// `spec/bot/v1/golden/bot-profile.json`; do not reorder cases without a new
/// golden export. Raw values match the dsh-bot `fish_color` values.
public enum BotFishColor: String, CaseIterable, Codable, Hashable, Sendable {
    case white
    case brown
    case red
    case orange
    case amber
    case green
    case teal
    case blue
    case purple
    case magenta
    case gray
    case black
    case silver
    case peach
    case sky

    public var hex: String {
        switch self {
        case .white: return "#FFFFFF"
        case .brown: return "#9D6937"
        case .red: return "#E5484D"
        case .orange: return "#F76B15"
        case .amber: return "#FFB224"
        case .green: return "#14C16F"
        case .teal: return "#13B7A2"
        case .blue: return "#1680F3"
        case .purple: return "#8F59F9"
        case .magenta: return "#F93498"
        case .gray: return "#8B8B8B"
        case .black: return "#1C1C1C"
        case .silver: return "#C9CBD1"
        case .peach: return "#F3B6A4"
        case .sky: return "#7ED0E8"
        }
    }

    /// Simplified-Chinese label used by the phone UI (upstream names are
    /// traditional; the values are the same colours).
    public var displayName: String {
        switch self {
        case .white: return "白"
        case .brown: return "棕"
        case .red: return "红"
        case .orange: return "橘"
        case .amber: return "橙黄"
        case .green: return "绿"
        case .teal: return "青绿"
        case .blue: return "蓝"
        case .purple: return "紫"
        case .magenta: return "桃红"
        case .gray: return "灰"
        case .black: return "黑"
        case .silver: return "银"
        case .peach: return "粉肤"
        case .sky: return "天蓝"
        }
    }
}

/// The four desktop DSH bot hairstyles. The `long` layers live in
/// `BotFish/base`, the other three in `BotFish/hair/<rawValue>`.
public enum BotFishHairstyle: String, CaseIterable, Codable, Hashable, Sendable {
    case long
    case twinTail = "twin-tail"
    case bob
    case sideBraid = "side-braid"

    public var displayName: String {
        switch self {
        case .long: return "经典长卷发"
        case .twinTail: return "高双马尾"
        case .bob: return "短鲍伯"
        case .sideBraid: return "粗侧辫"
        }
    }

    /// The upstream full name, suitable for an accessibility hint.
    public var accessibilityHint: String {
        switch self {
        case .long: return "经典长卷发・白褶发箍"
        case .twinTail: return "高双马尾・大蝴蝶结"
        case .bob: return "短鲍伯・贝壳珍珠夹"
        case .sideBraid: return "粗侧辫・小贝雷帽"
        }
    }
}

/// One Bot's resolved visual identity. `autoColor`/`autoHairstyle` retain
/// whether the corresponding stored field was `null` (automatic, derived from
/// the Bot id), so the editor can show the effective value without writing it.
public struct BotFishAppearance: Equatable, Hashable, Sendable {
    public var color: BotFishColor
    public var hairstyle: BotFishHairstyle
    public var autoColor: Bool
    public var autoHairstyle: Bool

    public init(color: BotFishColor, hairstyle: BotFishHairstyle,
                autoColor: Bool = false, autoHairstyle: Bool = false) {
        self.color = color
        self.hairstyle = hairstyle
        self.autoColor = autoColor
        self.autoHairstyle = autoHairstyle
    }

    /// The historical phoneDSH look and the desktop "new Bot" default.
    public static let classic: BotFishAppearance = BotFishAppearance(color: .blue, hairstyle: .long)

    /// Deterministic desktop DSH seed. The hash is FNV-1a over the JavaScript
    /// string's code points, but each code point contributes only its first
    /// UTF-16 unit. For BMP scalars that is the scalar value; for an astral
    /// scalar (emoji) it is the high surrogate. The golden vector locks this
    /// behaviour, so do not "fix" it to a scalar hash.
    public static func seed(_ seed: String) -> (color: BotFishColor, hairstyle: BotFishHairstyle) {
        let colorIndex = Int(BotFishSeed.hash(seed) % UInt32(BotFishColor.allCases.count))
        let hairstyleIndex = Int(BotFishSeed.hash(seed + ":hair") % UInt32(BotFishHairstyle.allCases.count))
        return (BotFishColor.allCases[colorIndex], BotFishHairstyle.allCases[hairstyleIndex])
    }

    /// Explicit stored fields win item by item; missing fields fall back to the
    /// seed from `id`, then `name`, then the literal `"fish"`.
    public static func resolve(_ profile: BotProfile) -> BotFishAppearance {
        let seedValue: String
        if !profile.id.isEmpty {
            seedValue = profile.id
        } else if !profile.name.isEmpty {
            seedValue = profile.name
        } else {
            seedValue = "fish"
        }
        let seeded = seed(seedValue)
        return BotFishAppearance(
            color: profile.fishColor ?? seeded.color,
            hairstyle: profile.fishHairstyle ?? seeded.hairstyle,
            autoColor: profile.fishColor == nil,
            autoHairstyle: profile.fishHairstyle == nil
        )
    }
}

/// `null`, `""` and `"auto"` mean automatic; anything else is lower-cased and
/// accepted only when it is an exact known id. There is no trimming: `" blue"`
/// is unknown. Unknown values do not throw; they also mean automatic.
public enum BotProfileNormalizer {
    public static func fishColor(_ raw: String?) -> BotFishColor? {
        guard let raw else { return nil }
        let lowered = raw.lowercased()
        guard lowered != "auto", !lowered.isEmpty else { return nil }
        return BotFishColor(rawValue: lowered)
    }

    public static func fishHairstyle(_ raw: String?) -> BotFishHairstyle? {
        guard let raw else { return nil }
        let lowered = raw.lowercased()
        guard lowered != "auto", !lowered.isEmpty else { return nil }
        return BotFishHairstyle(rawValue: lowered)
    }
}

private enum BotFishSeed {
    /// FNV-1a 32-bit with JavaScript `Math.imul`-compatible wrapping.
    static func hash(_ value: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for scalar in value.unicodeScalars {
            // JavaScript iterates code points (`for (const c of String(seed))`)
            // but `c.charCodeAt(0)` reads the first UTF-16 unit: the scalar for
            // BMP code points, the high surrogate for astral ones (emoji).
            let scalarValue = scalar.value
            let unit: UInt16
            if scalarValue <= 0xFFFF {
                unit = UInt16(scalarValue)
            } else {
                let offset = scalarValue - 0x10000
                unit = UInt16(0xD800 + (offset >> 10))
            }
            hash = (hash ^ UInt32(unit)) &* 16_777_619
        }
        return hash
    }
}
