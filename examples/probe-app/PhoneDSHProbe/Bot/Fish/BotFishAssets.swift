// SPDX-License-Identifier: MIT

// Shared, lazily loaded 大肥鱼 layers. The per-hairstyle grayscale `body.png`
// is tinted through the upstream LUT once per (hairstyle, crowned, colour,
// display-size bucket) and cached for the whole process: every `BotFishView`
// instance paints from the same decoded layers without allocating or
// re-tinting a 512×512 bitmap per frame. Crown overlays are decoded lazily too.

import Foundation
import PhoneDSHBot
import UIKit

/// The three per-hairstyle layers. `long` uses the classic `BotFish/base`
/// folder; the other styles use `BotFish/hair/<style>`. A crowned Bot uses the
/// matching `BotFish/crowned/...` trio instead; eyes, iris, blush and the
/// expressive sprites remain shared across every hairstyle and crown state.
struct BotFishHairLayers {
    let lumaBody: UIImage
    let fixed: UIImage
    let faceMask: UIImage
}

/// Upstream `crownStyle`: `gold` is the default, `crystal` is the alternate
/// overlay. The crown is loaded lazily and shared process-wide.
enum BotFishCrownStyle: String, CaseIterable {
    case gold
    case crystal
}

struct BotFishPalette {
    let id: String
    let lut: [UInt8]
    let ink: UIColor
    let mid: UIColor
    let light: UIColor

    /// The fixed classic fish colour, `#1680F3`.
    static let blue = BotFishPalette(id: "blue", hex: 0x1680F3)

    init(color: BotFishColor) {
        let raw = color.hex.hasPrefix("#") ? String(color.hex.dropFirst()) : color.hex
        let value = UInt32(raw, radix: 16) ?? 0x1680F3
        self.init(id: color.rawValue, hex: value)
    }

    private init(id: String, hex: UInt32) {
        self.id = id
        let rgb = [
            Double((hex >> 16) & 0xFF),
            Double((hex >> 8) & 0xFF),
            Double(hex & 0xFF),
        ]

        func shade(_ amount: Double, white: Double = 0) -> [Double] {
            rgb.map { BotFishMath.lerp($0 * amount, 255, white).rounded() }
        }

        let stops: [(at: Double, rgb: [Double])] = [
            (0, [13, 15, 25]),
            (0.20, shade(0.25)),
            (0.48, shade(0.52)),
            (0.73, rgb),
            (0.91, shade(1, white: 0.36)),
            (1, shade(1, white: 0.73)),
        ]

        var lut = [UInt8](repeating: 0, count: 256 * 3)
        for index in 0..<256 {
            let x = Double(index) / 255
            var lower = stops[0]
            var upper = stops[stops.count - 1]
            for candidate in 1..<stops.count where x <= stops[candidate].at {
                lower = stops[candidate - 1]
                upper = stops[candidate]
                break
            }
            let span = upper.at - lower.at
            let t = span == 0 ? 0 : (x - lower.at) / span
            for channel in 0..<3 {
                let value = Int(BotFishMath.lerp(lower.rgb[channel], upper.rgb[channel], t).rounded())
                lut[index * 3 + channel] = UInt8(clamping: value)
            }
        }

        let inkRGB = shade(0.22)
        self.lut = lut
        self.ink = BotFishPalette.color(inkRGB)
        self.mid = BotFishPalette.color(rgb)
        self.light = BotFishPalette.color(shade(1, white: 0.5))
    }

    private static func color(_ rgb: [Double]) -> UIColor {
        UIColor(red: CGFloat(rgb[0] / 255), green: CGFloat(rgb[1] / 255),
                blue: CGFloat(rgb[2] / 255), alpha: 1)
    }
}

final class BotFishAssets {
    let eyesOpen: UIImage
    let eyesWhite: UIImage
    let irisLeft: UIImage
    let irisRight: UIImage
    let blush: UIImage
    let expressiveEyes: UIImage
    let expressiveMouths: UIImage
    /// 24 pre-cropped 128×128 cells: for cel `n`, index `n * 2` is the left
    /// eye half and `n * 2 + 1` the right eye half (matching `artEye`).
    let eyeCels: [UIImage]
    /// 12 pre-cropped 256×128 cells in row-major grid order.
    let mouthCels: [UIImage]

    /// The visible circle crops 416 of the 512px source (448 when crowned). A
    /// tinted body at a 512-space raster side therefore reaches
    /// `pixelSide * 512 / cropSide` pixels; round that up to a small bucket so
    /// a 32pt header avatar and a 96pt empty-state avatar share one cache
    /// entry per process.
    private static let sizeBuckets = [32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048]
    private var tintedBodies: [String: UIImage] = [:]
    private let tintedBodyLock = NSLock()
    private var hairstyleLayers: [String: BotFishHairLayers] = [:]
    private let hairstyleLock = NSLock()
    private var crownLayers: [BotFishCrownStyle: UIImage] = [:]
    private let crownLock = NSLock()

    static let shared: BotFishAssets? = load()

    private init(eyesOpen: UIImage, eyesWhite: UIImage, irisLeft: UIImage, irisRight: UIImage,
                 blush: UIImage, expressiveEyes: UIImage, expressiveMouths: UIImage) {
        self.eyesOpen = eyesOpen
        self.eyesWhite = eyesWhite
        self.irisLeft = irisLeft
        self.irisRight = irisRight
        self.blush = blush
        self.expressiveEyes = expressiveEyes
        self.expressiveMouths = expressiveMouths
        self.eyeCels = BotFishAssets.eyeCels(from: expressiveEyes)
        self.mouthCels = BotFishAssets.cels(from: expressiveMouths, columns: 3, rows: 4,
                                            cell: CGSize(width: 256, height: 128))
    }

    private static func load() -> BotFishAssets? {
        guard let eyesOpen = image("eyes-open", folder: "base"),
              let eyesWhite = image("eyes-white", folder: "base"),
              let irisLeft = image("iris-left", folder: "base"),
              let irisRight = image("iris-right", folder: "base"),
              let blush = image("blush", folder: "base"),
              let expressiveEyes = image("eyes", folder: "expressive"),
              let expressiveMouths = image("mouths", folder: "expressive")
        else { return nil }
        return BotFishAssets(eyesOpen: eyesOpen, eyesWhite: eyesWhite,
                             irisLeft: irisLeft, irisRight: irisRight, blush: blush,
                             expressiveEyes: expressiveEyes, expressiveMouths: expressiveMouths)
    }

    /// Loads (and caches) the body/fixed/face-mask trio for one hairstyle and
    /// crown state. Plain `long` is the classic `BotFish/base` set; the other
    /// plain styles live under `BotFish/hair/<style>`. Crowned variants mirror
    /// upstream's `crownPath`: `crowned/long` for the classic cut and
    /// `crowned/<style>` for the v3 cuts.
    func layers(for hairstyle: BotFishHairstyle, crowned: Bool = false) -> BotFishHairLayers? {
        let key = "\(hairstyle.rawValue):\(crowned ? "crowned" : "plain")"
        hairstyleLock.lock()
        defer { hairstyleLock.unlock() }
        if let cached = hairstyleLayers[key] { return cached }
        let folder: String
        switch (hairstyle, crowned) {
        case (.long, false): folder = "base"
        case (.long, true): folder = "crowned/long"
        case (_, false): folder = "hair/\(hairstyle.rawValue)"
        case (_, true): folder = "crowned/\(hairstyle.rawValue)"
        }
        guard let luma = Self.image("body", folder: folder),
              let fixed = Self.image("fixed", folder: folder),
              let faceMask = Self.image("face-mask", folder: folder)
        else { return nil }
        let layers = BotFishHairLayers(lumaBody: luma, fixed: fixed, faceMask: faceMask)
        hairstyleLayers[key] = layers
        return layers
    }

    /// Loads (and caches) one crown overlay on first use. Every crowned view
    /// shares the decoded image; no crown is decoded for plain avatars.
    func crown(for style: BotFishCrownStyle) -> UIImage? {
        crownLock.lock()
        defer { crownLock.unlock() }
        if let cached = crownLayers[style] { return cached }
        let name = style == .gold ? "crown" : "crown-crystal"
        guard let image = Self.image(name, folder: "overlays") else { return nil }
        crownLayers[style] = image
        return image
    }

    private static func image(_ name: String, folder: String) -> UIImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png",
                                        subdirectory: "BotFish/\(folder)") else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    private static func cels(from image: UIImage, columns: Int, rows: Int, cell: CGSize) -> [UIImage] {
        guard let source = image.cgImage else { return [] }
        var result: [UIImage] = []
        result.reserveCapacity(columns * rows)
        for index in 0..<(columns * rows) {
            let rect = CGRect(x: CGFloat(index % columns) * cell.width,
                              y: CGFloat(index / columns) * cell.height,
                              width: cell.width, height: cell.height)
            guard let cropped = source.cropping(to: rect) else { return [] }
            result.append(UIImage(cgImage: cropped, scale: 1, orientation: .up))
        }
        return result
    }

    /// The eye sheet stores both eyes side by side in one 256×128 cell.
    private static func eyeCels(from image: UIImage) -> [UIImage] {
        guard let source = image.cgImage else { return [] }
        var result: [UIImage] = []
        result.reserveCapacity(BotFishEyeCel.names.count * 2)
        for index in 0..<BotFishEyeCel.names.count {
            for half in 0..<2 {
                let rect = CGRect(x: CGFloat((index % 3) * 256 + half * 128),
                                  y: CGFloat((index / 3) * 128),
                                  width: 128, height: 128)
                guard let cropped = source.cropping(to: rect) else { return [] }
                result.append(UIImage(cgImage: cropped, scale: 1, orientation: .up))
            }
        }
        return result
    }

    /// Returns the LUT-tinted body at the nearest display-size bucket. The
    /// returned bitmap is in the 512px source space, so callers keep the
    /// upstream coordinates and only the (hairstyle, crown, colour, size)
    /// rasterisation is shared process-wide.
    func bodyLayer(hairstyle: BotFishHairstyle, palette: BotFishPalette,
                   pixelSide: CGFloat, crowned: Bool = false) -> CGImage? {
        guard let layers = layers(for: hairstyle, crowned: crowned) else { return nil }
        let cropSide = crowned ? BotFishRenderer.crownedCropSide : BotFishRenderer.cropSide
        let fullSourceSide = max(1, pixelSide * BotFishRenderer.size / cropSide)
        let bucket = Self.sizeBucket(for: fullSourceSide)
        let key = "\(hairstyle.rawValue):\(crowned ? "crowned" : "plain"):\(palette.id)@\(bucket)"
        tintedBodyLock.lock()
        defer { tintedBodyLock.unlock() }
        if let cached = tintedBodies[key] { return cached.cgImage }
        guard let image = Self.tintBody(layers.lumaBody, palette: palette,
                                        width: bucket, height: bucket) else {
            return nil
        }
        tintedBodies[key] = image
        return image.cgImage
    }

    private static func sizeBucket(for pixelSide: CGFloat) -> Int {
        let rounded = max(1, Int(ceil(Double(pixelSide))))
        return sizeBuckets.first(where: { $0 >= rounded }) ?? sizeBuckets[sizeBuckets.count - 1]
    }

    /// Upstream `tintBody`: grayscale luma drives a 256-entry LUT; alpha and
    /// framing are preserved. Returns a premultiplied RGBA bitmap.
    private static func tintBody(_ image: UIImage, palette: BotFishPalette,
                                 width: Int, height: Int) -> UIImage? {
        guard let source = image.cgImage else { return nil }
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for offset in stride(from: 0, to: width * height * 4, by: 4) {
            let alpha = Int(pixels[offset + 3])
            if alpha == 0 {
                pixels[offset] = 0
                pixels[offset + 1] = 0
                pixels[offset + 2] = 0
                continue
            }
            // The bitmap is premultiplied; recover the straight luma first.
            let luma = min(255, Int(pixels[offset]) * 255 / alpha)
            let lutIndex = min(255, luma) * 3
            pixels[offset] = UInt8(clamping: Int(palette.lut[lutIndex]) * alpha / 255)
            pixels[offset + 1] = UInt8(clamping: Int(palette.lut[lutIndex + 1]) * alpha / 255)
            pixels[offset + 2] = UInt8(clamping: Int(palette.lut[lutIndex + 2]) * alpha / 255)
        }
        guard let output = context.makeImage() else { return nil }
        return UIImage(cgImage: output, scale: 1, orientation: .up)
    }
}
