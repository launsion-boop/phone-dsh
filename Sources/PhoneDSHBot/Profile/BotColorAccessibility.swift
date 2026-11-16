// SPDX-License-Identifier: MIT

import Foundation

/// Small sRGB helpers shared by the Bot's appearance-bound UI colors.
///
/// The avatar coat uses `BotFishColor.hex` directly. Cards must read as the
/// same brand color, but a pale coat (white, silver, peach, sky, amber) cannot
/// carry 12pt text on a white card. `accessible` adjusts brightness in HSB —
/// never the hue or saturation — only until the requested contrast is met, so
/// a strong blue/purple stays almost identical to the avatar while a pale
/// colour becomes its readable darker/lighter sibling. Decorative fills can
/// ask for a lower target and keep the source colour exactly.
public enum BotColorAccessibility {
    public struct RGB: Equatable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = Self.clamp(red)
            self.green = Self.clamp(green)
            self.blue = Self.clamp(blue)
        }

        public static let white = RGB(red: 1, green: 1, blue: 1)
        public static let black = RGB(red: 0, green: 0, blue: 0)

        public var hexString: String {
            let channels = [red, green, blue].map {
                Int(($0 * 255).rounded())
            }
            return "#" + channels.map { String(format: "%02X", $0) }.joined()
        }

        private static func clamp(_ value: Double) -> Double {
            min(1, max(0, value))
        }
    }

    /// Parses `#RRGGBB` or `RRGGBB`. Anything else is `nil`; callers keep
    /// their existing classic blue fallback rather than inventing a colour.
    public static func rgb(hex: String) -> RGB? {
        let raw = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard raw.count == 6, let value = UInt32(raw, radix: 16) else { return nil }
        return RGB(red: Double((value >> 16) & 0xFF) / 255,
                   green: Double((value >> 8) & 0xFF) / 255,
                   blue: Double(value & 0xFF) / 255)
    }

    public static func relativeLuminance(_ color: RGB) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045
                ? channel / 12.92
                : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red)
            + 0.7152 * linear(color.green)
            + 0.0722 * linear(color.blue)
    }

    /// WCAG contrast ratio, 1...21.
    public static func contrastRatio(_ lhs: RGB, _ rhs: RGB) -> Double {
        let first = relativeLuminance(lhs)
        let second = relativeLuminance(rhs)
        let lighter = max(first, second)
        let darker = min(first, second)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Returns `color` when it already meets `minimumContrast` against
    /// `background`. Otherwise the colour is moved along the brightness axis
    /// (towards white on a dark background, towards black on a light one) with
    /// hue and saturation unchanged. If the brightness axis alone cannot reach
    /// the target, a final blend towards white/black completes it.
    public static func accessible(_ color: RGB,
                                  on background: RGB,
                                  minimumContrast: Double = 4.5) -> RGB {
        guard minimumContrast.isFinite, minimumContrast > 1 else { return color }
        if contrastRatio(color, background) >= minimumContrast { return color }

        let hsb = hsb(from: color)
        let lighten = relativeLuminance(background) < 0.5
        let step = 0.004
        var brightness = hsb.brightness
        for _ in 0..<250 {
            let next = lighten
                ? min(1, brightness + step)
                : max(0, brightness - step)
            brightness = next
            let candidate = rgb(hue: hsb.hue, saturation: hsb.saturation,
                                brightness: brightness)
            if contrastRatio(candidate, background) >= minimumContrast {
                return candidate
            }
            if brightness == 0 || brightness == 1 { break }
        }

        // Fully saturated colours can hit the top/bottom of the brightness
        // axis before the target (for example purple in dark mode). Move the
        // remaining distance towards the background's opposite pole.
        let base = rgb(hue: hsb.hue, saturation: hsb.saturation,
                       brightness: brightness)
        let pole: RGB = lighten ? .white : .black
        for index in 1...100 {
            let amount = Double(index) / 100
            let candidate = RGB(red: base.red + (pole.red - base.red) * amount,
                                green: base.green + (pole.green - base.green) * amount,
                                blue: base.blue + (pole.blue - base.blue) * amount)
            if contrastRatio(candidate, background) >= minimumContrast {
                return candidate
            }
        }
        return pole
    }

    // MARK: - HSB

    private static func hsb(from color: RGB) -> (hue: Double, saturation: Double, brightness: Double) {
        let maximum = max(color.red, color.green, color.blue)
        let minimum = min(color.red, color.green, color.blue)
        let delta = maximum - minimum
        var hue = 0.0
        if delta > 0 {
            if maximum == color.red {
                hue = (color.green - color.blue) / delta
                if hue < 0 { hue += 6 }
            } else if maximum == color.green {
                hue = (color.blue - color.red) / delta + 2
            } else {
                hue = (color.red - color.green) / delta + 4
            }
            hue /= 6
        }
        let saturation = maximum == 0 ? 0 : delta / maximum
        return (hue, saturation, maximum)
    }

    private static func rgb(hue: Double, saturation: Double, brightness: Double) -> RGB {
        let sector = hue * 6
        let index = Int(sector) % 6
        let fraction = sector - floor(sector)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - fraction * saturation)
        let t = brightness * (1 - (1 - fraction) * saturation)
        switch index {
        case 0: return RGB(red: brightness, green: t, blue: p)
        case 1: return RGB(red: q, green: brightness, blue: p)
        case 2: return RGB(red: p, green: brightness, blue: t)
        case 3: return RGB(red: p, green: q, blue: brightness)
        case 4: return RGB(red: t, green: p, blue: brightness)
        default: return RGB(red: brightness, green: p, blue: q)
        }
    }
}
