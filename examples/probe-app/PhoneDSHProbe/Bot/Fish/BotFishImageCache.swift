// SPDX-License-Identifier: MIT

// Process-wide cache of display-sized fish layers. Every `BotFishView`
// instance shares these CGImages, so a 32pt header avatar, a 28pt status-line
// avatar and a 96pt empty-state avatar do not each re-scale the 512px source
// art. The renderer only translates/blits these pixels afterwards; it never
// resamples the source layers per frame.

import Foundation
import UIKit

final class BotFishImageCache {
    static let shared = BotFishImageCache()

    private var storage: [String: CGImage] = [:]
    private let lock = NSLock()

    private init() {}

    /// Returns the cached image for `key`, building it with `make` on a miss.
    /// The build runs outside the lock; two views racing on the same key
    /// simply both build it and the first result wins.
    func cached(_ key: String, make: () -> CGImage?) -> CGImage? {
        lock.lock()
        if let image = storage[key] {
            lock.unlock()
            return image
        }
        lock.unlock()
        guard let image = make() else { return nil }
        lock.lock()
        if let existing = storage[key] {
            lock.unlock()
            return existing
        }
        storage[key] = image
        lock.unlock()
        return image
    }

    /// Scales a full 512px source-space layer and crops the 416px circle
    /// framing used by the avatar. The result is exactly `pixelSide` pixels,
    /// which is the same size the renderer's canvas uses, so drawing it costs
    /// a copy instead of a resample.
    func croppedLayer(_ source: CGImage, key: String, pixelSide: Int) -> CGImage? {
        cached(key) {
            guard pixelSide > 0,
                  let context = BotFishImageCache.makeContext(width: pixelSide, height: pixelSide)
            else { return nil }
            let scale = CGFloat(pixelSide) / BotFishRenderer.cropSide
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -BotFishRenderer.cropOrigin.x,
                                y: -BotFishRenderer.cropOrigin.y)
            BotFishImageCache.drawUpright(source,
                                          in: CGRect(x: 0, y: 0,
                                                     width: BotFishRenderer.size,
                                                     height: BotFishRenderer.size),
                                          on: context)
            return context.makeImage()
        }
    }

    /// Crops `sourceRect` from a full-size sheet and scales it to exactly
    /// `width × height` output pixels. Used for the sub-regions the renderer
    /// clips anyway (default eyes) and for the sprite table cells.
    func croppedPart(_ source: CGImage, sourceRect: CGRect, key: String,
                     width: Int, height: Int) -> CGImage? {
        cached(key) {
            guard width > 0, height > 0,
                  let cropped = source.cropping(to: sourceRect.integral),
                  let context = BotFishImageCache.makeContext(width: width, height: height)
            else { return nil }
            BotFishImageCache.drawUpright(cropped,
                                          in: CGRect(x: 0, y: 0,
                                                     width: CGFloat(width),
                                                     height: CGFloat(height)),
                                          on: context)
            return context.makeImage()
        }
    }

    /// Scales a complete sheet (or one already-cropped cel) to exactly
    /// `width × height` output pixels.
    func scaledSheet(_ source: CGImage, key: String, width: Int, height: Int) -> CGImage? {
        cached(key) {
            guard width > 0, height > 0,
                  let context = BotFishImageCache.makeContext(width: width, height: height)
            else { return nil }
            BotFishImageCache.drawUpright(source,
                                          in: CGRect(x: 0, y: 0,
                                                     width: CGFloat(width),
                                                     height: CGFloat(height)),
                                          on: context)
            return context.makeImage()
        }
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        // Top-left origin, matching the renderer's canvases and UIKit. The
        // local `drawUpright` pass undoes the flip for the Core Graphics image
        // itself, so cached layers are stored in the same orientation the
        // renderer draws them.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        return context
    }

    private static func drawUpright(_ image: CGImage, in rect: CGRect, on context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
}
