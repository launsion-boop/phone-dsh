// SPDX-License-Identifier: MIT

// Core Graphics port of dsh-bot `src/renderer/lib/fish/paint.js` plus the
// 8px head-slice compositing from `renderFrame`. All coordinates inside the
// painting helpers are the upstream 512px / 1024 design units, so the code can
// be compared line-by-line with the reference.

import Foundation
import PhoneDSHBot
import UIKit

final class BotFishRenderer {
    static let size: CGFloat = 512
    static let pad: CGFloat = 24
    static let scale: CGFloat = 464.0 / 1024.0
    static let tau = Double.pi * 2
    static let designInk = UIColor(red: 33.0 / 255.0, green: 25.0 / 255.0,
                                   blue: 45.0 / 255.0, alpha: 1)

    /// Upstream circle framing (`avatar.js`): the normal avatar shows the
    /// 416px square at (48, 30) out of the 512px source canvas.
    static let cropOrigin = CGPoint(x: 48, y: 30)
    static let cropSide: CGFloat = 416

    /// The 32pt header avatar is too small for the upstream motion amplitudes
    /// to read. Boost translation/roll 2.2× at 40pt and below, keep the
    /// upstream values from 64pt up, and clamp the boosted pose so the fish
    /// stays inside the circular crop instead of exposing an empty disc edge.
    private static let motionBoostSmallSize: CGFloat = 40
    private static let motionBoostLargeSize: CGFloat = 64
    private static let motionBoostFactor: Double = 2.2
    private static let motionBoostMaxTranslation: Double = 20
    private static let motionBoostMaxRoll: Double = 9

    private let assets: BotFishAssets?
    private var palette = BotFishPalette.blue

    private var pixelSide = 0
    private var baseTransform = CGAffineTransform.identity
    private var flatContext: CGContext?
    private var stageContext: CGContext?
    private var browContext: CGContext?
    private var bodyLayer: UIImage?
    private var hairLayers: BotFishHairLayers?
    private var renderedColor: BotFishColor?
    private var renderedHairstyle: BotFishHairstyle?

    init() {
        assets = BotFishAssets.shared
    }

    func render(_ params: BotFishParams, time: Double, size: CGFloat,
                displayScale: CGFloat,
                appearance: BotFishAppearance = .classic) -> UIImage? {
        guard let assets, !assets.eyeCels.isEmpty, !assets.mouthCels.isEmpty else { return nil }
        let scale = max(1, displayScale)
        let target = max(1, Int(ceil(Double(max(1, size) * scale))))
        guard ensureContexts(target), let flatContext else { return nil }
        if bodyLayer == nil || renderedColor != appearance.color
            || renderedHairstyle != appearance.hairstyle {
            let nextPalette = BotFishPalette(color: appearance.color)
            guard let layers = assets.layers(for: appearance.hairstyle),
                  let body = assets.bodyLayer(hairstyle: appearance.hairstyle,
                                              palette: nextPalette,
                                              pixelSide: CGFloat(target))
            else { return nil }
            palette = nextPalette
            hairLayers = layers
            bodyLayer = body
            renderedColor = appearance.color
            renderedHairstyle = appearance.hairstyle
        }
        guard bodyLayer != nil else { return nil }

        var p = params
        let boost = Self.motionBoost(for: size)
        p.motionScale = boost
        if boost > 1 {
            p.x = BotFishMath.clamp(p.x * boost,
                                    -Self.motionBoostMaxTranslation, Self.motionBoostMaxTranslation)
            p.y = BotFishMath.clamp(p.y * boost,
                                    -Self.motionBoostMaxTranslation, Self.motionBoostMaxTranslation)
            p.roll = BotFishMath.clamp(p.roll * boost,
                                       -Self.motionBoostMaxRoll, Self.motionBoostMaxRoll)
        }

        let headMotion = abs(p.headX) + abs(p.headY) + abs(p.hairSway) + abs(p.earFlutter)
        if headMotion >= 0.001, let stageContext {
            guard renderFlat(into: stageContext, assets: assets, p: p, time: time,
                             pixelSide: target) else { return nil }
            guard let stage = stageContext.makeImage() else { return nil }
            guard renderMotion(stage: stage, into: flatContext, p: p, pixelSide: target) else {
                return nil
            }
        } else {
            guard renderFlat(into: flatContext, assets: assets, p: p, time: time,
                             pixelSide: target) else { return nil }
        }
        guard let image = flatContext.makeImage() else { return nil }
        return UIImage(cgImage: image, scale: scale, orientation: .up)
    }

    private static func motionBoost(for size: CGFloat) -> Double {
        if size <= motionBoostSmallSize { return motionBoostFactor }
        if size >= motionBoostLargeSize { return 1 }
        let t = Double((size - motionBoostSmallSize)
            / (motionBoostLargeSize - motionBoostSmallSize))
        return motionBoostFactor + (1 - motionBoostFactor) * t
    }

    private func ensureContexts(_ target: Int) -> Bool {
        if pixelSide == target, flatContext != nil, stageContext != nil, browContext != nil {
            return true
        }
        guard let flat = makeContext(target), let stage = makeContext(target),
              let brow = makeContext(target) else {
            pixelSide = 0
            flatContext = nil
            stageContext = nil
            browContext = nil
            bodyLayer = nil
            return false
        }
        pixelSide = target
        flatContext = flat
        stageContext = stage
        browContext = brow
        bodyLayer = nil
        // A UIKit-style top-left origin: draw in source space exactly as the
        // previous UIGraphicsImageRenderer path did, but into a reused canvas.
        baseTransform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                                          tx: 0, ty: CGFloat(target))
        // Turn the identity CTM into the base transform, then keep that state
        // at the bottom of the stack. `resetCTM` restores this snapshot before
        // every paint instead of relying on an unavailable setCTM.
        for context in [flat, stage, brow] {
            context.concatenate(baseTransform)
            context.saveGState()
        }
        return true
    }

    private func makeContext(_ target: Int) -> CGContext? {
        let context = CGContext(data: nil, width: target, height: target,
                                bitsPerComponent: 8, bytesPerRow: target * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.interpolationQuality = .high
        return context
    }

    private var fullPixelRect: CGRect {
        CGRect(x: 0, y: 0, width: CGFloat(pixelSide), height: CGFloat(pixelSide))
    }

    /// `CGContext` exposes no public `setCTM`. Each reusable context is
    /// created at `baseTransform` and pushed once; a reset pops back to that
    /// snapshot and immediately re-pushes it so the next draw starts from the
    /// base transform again.
    private func resetCTM(_ cg: CGContext) {
        cg.restoreGState()
        cg.saveGState()
    }

    /// Draws a `CGImage` upright inside the flipped (top-left origin) context.
    /// `CGContext.draw` alone would render it upside down, while
    /// `UIImage.draw(in:)` would silently reset the context alpha and blend
    /// mode. The local flip is undone by `restoreGState`, so callers keep
    /// their CTM, alpha and blend mode.
    private func drawUpright(_ image: CGImage, in rect: CGRect, on cg: CGContext) {
        cg.saveGState()
        cg.translateBy(x: rect.minX, y: rect.maxY)
        cg.scaleBy(x: 1, y: -1)
        cg.draw(image, in: CGRect(origin: .zero, size: rect.size))
        cg.restoreGState()
    }

    /// Convenience overload for the UIKit assets. `rect` is in the current
    /// (source/design or output-pixel) space and does not depend on the
    /// asset's `UIImage.scale`: the full `cgImage` fills the same rect that
    /// `UIImage.draw(in:)` used to receive.
    private func drawUpright(_ image: UIImage, in rect: CGRect, on cg: CGContext) {
        guard let cgImage = image.cgImage else { return }
        drawUpright(cgImage, in: rect, on: cg)
    }

    private func renderFlat(into cg: CGContext, assets: BotFishAssets, p: BotFishParams,
                            time: Double, pixelSide target: Int) -> Bool {
        guard let body = bodyLayer, let hairLayers else { return false }
        let alpha = CGFloat(BotFishMath.clamp(p.alpha, 0, 1))
        let pixelScale = CGFloat(target) / Self.cropSide
        resetCTM(cg)
        cg.clear(fullPixelRect)
        cg.saveGState()
        // Source space stays 512px; the canvas is the 416px circle crop, so a
        // 32pt avatar rasterises only the pixels it can actually display.
        cg.scaleBy(x: pixelScale, y: pixelScale)
        cg.translateBy(x: -Self.cropOrigin.x, y: -Self.cropOrigin.y)
        cg.setAlpha(alpha)
        cg.translateBy(x: 256 + CGFloat(p.x), y: 350 + CGFloat(p.y))
        cg.rotate(by: CGFloat(p.roll * Double.pi / 180))
        cg.scaleBy(x: CGFloat(p.sx * p.morphX), y: CGFloat(p.sy * p.morphY))
        cg.translateBy(x: -256, y: -350)

        let frame = CGRect(x: 0, y: 0, width: Self.size, height: Self.size)
        drawUpright(body, in: frame, on: cg)
        drawUpright(hairLayers.fixed, in: frame, on: cg)

        if p.blush > 0.01 {
            cg.saveGState()
            cg.setAlpha(alpha * CGFloat(p.blush))
            drawUpright(assets.blush, in: frame, on: cg)
            cg.restoreGState()
        }

        paintEye(cg, assets: assets, side: -1, p: p, art: p.eyeArt, baseAlpha: Double(alpha))
        paintEye(cg, assets: assets, side: 1, p: p, art: p.eyeArt, baseAlpha: Double(alpha))
        // Brows are composited at base transform after the transformed pass so
        // `resetCTM` never has to pop a nested save (which would restore the
        // source-space transform instead of the base snapshot).
        let brows = p.eyeArt == nil ? browImage(p: p) : nil
        paintMouthCrossfade(cg, assets: assets, p: p, baseAlpha: Double(alpha))

        if p.tears > 0.01 {
            paintTears(cg, p: p, time: time, baseAlpha: Double(alpha))
        }
        paintFin(cg, side: -1, amount: p.finL, wave: p.finWave, fold: p.finFold,
                 baseAlpha: Double(alpha))
        paintFin(cg, side: 1, amount: p.finR, wave: -p.finWave, fold: p.finFold,
                 baseAlpha: Double(alpha))
        paintDecorations(cg, p: p, time: time, baseAlpha: Double(alpha))
        cg.restoreGState()
        if let brows {
            cg.saveGState()
            cg.setAlpha(alpha)
            drawUpright(brows, in: fullPixelRect, on: cg)
            cg.restoreGState()
        }
        return true
    }

    /// The upstream head-to-shoulder displacement. The 512px source is cut
    /// into the same 8px slices, but each slice is scaled to the display pixel
    /// height and drawn into the reused output context instead of first
    /// rendering a 512×512 bitmap and scaling that.
    private func renderMotion(stage: CGImage, into cg: CGContext, p: BotFishParams,
                              pixelSide target: Int) -> Bool {
        let pixelScale = CGFloat(target) / Self.cropSide
        resetCTM(cg)
        cg.setAlpha(1)
        cg.clear(fullPixelRect)
        var y = 0.0
        while y < Double(Self.size) {
            let nextY = min(Double(Self.size), y + 8)
            // The stage starts at source y=30 (the circle crop), not at zero.
            let yPixel = (CGFloat(y) - Self.cropOrigin.y) * pixelScale
            let nextPixel = (CGFloat(nextY) - Self.cropOrigin.y) * pixelScale
            // Snap both edges of every slice to whole output pixels. Adjacent
            // slices round the same shared boundary the same way, so the clips
            // tile exactly: no fractional clip edge leaves an antialiased
            // hairline, and no overlap double-composites a translucent edge.
            let top = max(0, floor(yPixel))
            let bottom = min(CGFloat(target), floor(nextPixel))
            if bottom > top {
                let v = BotFishMath.clamp((y - 365) / 65, 0, 1)
                let head = 1 - v * v * (3 - 2 * v)
                let dx = p.headX * (4.5 + (350 - y) * 0.009) * head
                    + p.hairSway * max(0, (y - 310) / 160)
                let dy = p.headY * 2.8 * head
                    + p.earFlutter * exp(-pow((y - 245) / 45, 2))
                cg.saveGState()
                cg.setShouldAntialias(false)
                cg.translateBy(x: CGFloat(dx) * pixelScale, y: CGFloat(dy) * pixelScale)
                cg.clip(to: CGRect(x: 0, y: top, width: CGFloat(target), height: bottom - top))
                drawUpright(stage, in: fullPixelRect, on: cg)
                cg.restoreGState()
            }
            y = nextY
        }
        return true
    }

    // MARK: - Eyes

    private func paintEye(_ cg: CGContext, assets: BotFishAssets, side: Double,
                          p: BotFishParams, art: String?, baseAlpha: Double) {
        if p.artMix < 1, p.eyeArtPrev != art {
            cg.saveGState()
            cg.setAlpha(CGFloat(baseAlpha * (1 - p.artMix)))
            paintEyeLayer(cg, assets: assets, side: side, p: p, art: p.eyeArtPrev)
            cg.restoreGState()
            cg.saveGState()
            cg.setAlpha(CGFloat(baseAlpha * p.artMix))
            paintEyeLayer(cg, assets: assets, side: side, p: p, art: art)
            cg.restoreGState()
            return
        }
        paintEyeLayer(cg, assets: assets, side: side, p: p, art: art)
    }

    private func paintEyeLayer(_ cg: CGContext, assets: BotFishAssets, side: Double,
                               p: BotFishParams, art: String?) {
        if let index = BotFishEyeCel.index(of: art) {
            let cel = index * 2 + (side < 0 ? 0 : 1)
            if cel < assets.eyeCels.count {
                let blink = max(0.035, p.blink)
                let cx = side < 0 ? 205.0 : 307.0
                let cy = 297.0 + (art == "laughing" ? 8 : 0)
                cg.saveGState()
                cg.translateBy(x: CGFloat(cx + p.gazeX * 2), y: CGFloat(cy + p.gazeY * 1.2))
                cg.scaleBy(x: 1, y: CGFloat(blink))
                drawUpright(assets.eyeCels[cel],
                            in: CGRect(x: -51, y: -51, width: 102, height: 102), on: cg)
                cg.restoreGState()
                return
            }
        }

        let cx = side < 0 ? 399.0 : 624.0
        let cy = 603.0
        let open = BotFishMath.clamp((side < 0 ? p.eyeL : p.eyeR) * p.blink, 0, 1.2)
        let happy = BotFishMath.clamp(p.joy, 0, 1)
        cg.saveGState()
        design(cg)
        cg.translateBy(x: CGFloat(cx), y: CGFloat(cy))
        if open > 1 {
            let expansion = CGFloat(1 + (open - 1) * 0.55)
            cg.scaleBy(x: expansion, y: expansion)
        }
        if open < 0.14 {
            cg.translateBy(x: 0, y: CGFloat(BotFishMath.lerp(29, 3, happy)))
            cg.setStrokeColor(BotFishRenderer.designInk.cgColor)
            cg.setLineWidth(6.5)
            cg.setLineCap(.round)
            cg.move(to: CGPoint(x: -58, y: 8))
            cg.addQuadCurve(to: CGPoint(x: 58, y: 8),
                            control: CGPoint(x: 0, y: happy > 0.35 ? -18 : 13))
            cg.strokePath()
            cg.setLineWidth(3.3)
            cg.move(to: CGPoint(x: side * 49, y: 4))
            cg.addLine(to: CGPoint(x: side * 62, y: -2))
            cg.strokePath()
            cg.restoreGState()
            return
        }

        let h = 64 * open
        let w = 76.0
        let tilt = p.anger * (-side) * 13 + p.sorrow * side * 6
        let descent = (1 - min(open, 1)) * BotFishMath.lerp(52, 22, happy)
        let lid = open < 0.96 || p.anger > 0.1 || p.sorrow > 0.1

        cg.saveGState()
        cg.clip(to: CGRect(x: -102, y: -96, width: 204, height: 190))
        if lid {
            cg.translateBy(x: 0, y: CGFloat(descent))
            cg.addPath(BotFishRenderer.eyePath(w: w, h: h, tilt: tilt))
            cg.clip()
            cg.translateBy(x: 0, y: CGFloat(-descent))
        }
        let gx = BotFishMath.clamp(p.gazeX, -1, 1) * 8
        let gy = BotFishMath.clamp(p.gazeY, -1, 1) * 6
        let moving = abs(gx) + abs(gy) > 0.05
        drawEyeBase(cg, image: moving ? assets.eyesWhite : assets.eyesOpen, cx: cx, cy: cy)
        if moving {
            cg.saveGState()
            cg.translateBy(x: CGFloat(gx), y: CGFloat(gy))
            drawEyeBase(cg, image: side < 0 ? assets.irisLeft : assets.irisRight, cx: cx, cy: cy)
            cg.restoreGState()
        }
        if p.love > 0.05 {
            cg.saveGState()
            cg.translateBy(x: CGFloat((side < 0 ? 410.5 : 625.5) - cx), y: 0)
            heart(cg, x: 0, y: 0, r: 24,
                  color: UIColor(red: 223.0 / 255.0, green: 77.0 / 255.0, blue: 136.0 / 255.0, alpha: 1),
                  alpha: p.love)
            cg.restoreGState()
        }
        cg.restoreGState()

        if lid {
            cg.saveGState()
            cg.translateBy(x: 0, y: CGFloat(descent))
            cg.setStrokeColor(BotFishRenderer.designInk.cgColor)
            cg.setLineWidth(7)
            cg.setLineCap(.round)
            cg.addPath(BotFishRenderer.lidPath(w: w, h: h, tilt: tilt))
            cg.strokePath()
            cg.restoreGState()
        }
        cg.restoreGState()
    }

    private func drawEyeBase(_ cg: CGContext, image: UIImage, cx: Double, cy: Double) {
        let inverse = Double(BotFishRenderer.size) / Double(BotFishRenderer.scale)
        drawUpright(image,
                    in: CGRect(x: -Double(BotFishRenderer.pad) / Double(BotFishRenderer.scale) - cx,
                               y: -Double(BotFishRenderer.pad) / Double(BotFishRenderer.scale) - cy,
                               width: inverse, height: inverse),
                    on: cg)
    }

    private static func eyePath(w: Double, h: Double, tilt: Double) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -w, y: 3))
        path.addCurve(to: CGPoint(x: w * 0.43, y: -h * 0.82 + tilt),
                      control1: CGPoint(x: -w * 0.88, y: -h * 0.76 - tilt),
                      control2: CGPoint(x: -w * 0.22, y: -h * 1.12))
        path.addCurve(to: CGPoint(x: w, y: h * 0.27),
                      control1: CGPoint(x: w * 0.88, y: -h * 0.63 + tilt),
                      control2: CGPoint(x: w * 1.08, y: -h * 0.05))
        path.addLine(to: CGPoint(x: 104, y: 100))
        path.addLine(to: CGPoint(x: -104, y: 100))
        path.closeSubpath()
        return path
    }

    private static func lidPath(w: Double, h: Double, tilt: Double) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -w, y: 3))
        path.addCurve(to: CGPoint(x: w * 0.43, y: -h * 0.82 + tilt),
                      control1: CGPoint(x: -w * 0.88, y: -h * 0.76 - tilt),
                      control2: CGPoint(x: -w * 0.22, y: -h * 1.12))
        path.addCurve(to: CGPoint(x: w * 0.98, y: -h * 0.12),
                      control1: CGPoint(x: w * 0.72, y: -h * 0.68 + tilt),
                      control2: CGPoint(x: w * 0.91, y: -h * 0.39))
        return path
    }

    // MARK: - Brows

    /// Renders the brow layer into the reusable scratch context and returns it
    /// in base (target-pixel) space. `renderFlat` composites it after dropping
    /// the source-space transform so a nested save never sits above the base
    /// snapshot that `resetCTM` restores.
    private func browImage(p: BotFishParams) -> CGImage? {
        guard abs(p.browL) + abs(p.browR) + p.anger + p.sorrow >= 0.02,
              let b = browContext, let hairLayers else { return nil }
        let pixelScale = CGFloat(pixelSide) / BotFishRenderer.cropSide
        resetCTM(b)
        b.setAlpha(1)
        b.clear(fullPixelRect)
        b.saveGState()
        b.scaleBy(x: pixelScale, y: pixelScale)
        b.translateBy(x: -BotFishRenderer.cropOrigin.x, y: -BotFishRenderer.cropOrigin.y)
        design(b)
        b.setStrokeColor(UIColor(red: 52.0 / 255.0, green: 37.0 / 255.0,
                                 blue: 58.0 / 255.0, alpha: 0.58).cgColor)
        b.setLineWidth(2.7)
        b.setLineCap(.round)
        for (cx, value, sideSign) in [(399.0, p.browL, -1.0), (624.0, p.browR, 1.0)] {
            b.saveGState()
            b.translateBy(x: CGFloat(cx), y: CGFloat(527 - value * 8))
            b.rotate(by: CGFloat(-sideSign * p.anger * 0.22 + sideSign * p.sorrow * 0.20))
            b.move(to: CGPoint(x: -26, y: 0))
            b.addQuadCurve(to: CGPoint(x: 26, y: 0), control: CGPoint(x: 0, y: -5))
            b.strokePath()
            b.restoreGState()
        }
        b.restoreGState()
        // Keep only the stroke pixels that fall inside the face: the mask must
        // be a destination-in pass, never an opaque image painted on top.
        b.setBlendMode(.destinationIn)
        b.saveGState()
        b.scaleBy(x: pixelScale, y: pixelScale)
        b.translateBy(x: -BotFishRenderer.cropOrigin.x, y: -BotFishRenderer.cropOrigin.y)
        drawUpright(hairLayers.faceMask,
                    in: CGRect(x: 0, y: 0, width: BotFishRenderer.size,
                               height: BotFishRenderer.size),
                    on: b)
        b.restoreGState()
        b.setBlendMode(.normal)
        return b.makeImage()
    }

    // MARK: - Mouth

    private func paintMouthCrossfade(_ cg: CGContext, assets: BotFishAssets,
                                     p: BotFishParams, baseAlpha: Double) {
        if p.artMix < 1, p.mouthArtPrev != p.mouthArt {
            cg.saveGState()
            cg.setAlpha(CGFloat(baseAlpha * (1 - p.artMix)))
            paintMouthLayer(cg, assets: assets, p: p, art: p.mouthArtPrev)
            cg.restoreGState()
            cg.saveGState()
            cg.setAlpha(CGFloat(baseAlpha * p.artMix))
            paintMouthLayer(cg, assets: assets, p: p, art: p.mouthArt)
            cg.restoreGState()
            return
        }
        paintMouthLayer(cg, assets: assets, p: p, art: p.mouthArt)
    }

    private func paintMouthLayer(_ cg: CGContext, assets: BotFishAssets,
                                 p: BotFishParams, art: String?) {
        if let index = BotFishMouthCel.index(of: art), index < assets.mouthCels.count {
            let w = 90 * p.mouthWidth
            drawUpright(assets.mouthCels[index],
                        in: CGRect(x: 256 - w / 2, y: 335 - w / 4,
                                   width: w, height: w / 2),
                        on: cg)
            return
        }
        paintMouth(cg, p: p)
    }

    private func paintMouth(_ cg: CGContext, p: BotFishParams) {
        cg.saveGState()
        design(cg)
        cg.translateBy(x: 512, y: 693)
        let w = 34 * p.mouthWidth
        let open = BotFishMath.clamp(p.mouth, 0, 1)
        cg.setLineCap(.round)
        if open < 0.045 {
            cg.move(to: CGPoint(x: -w, y: -2))
            cg.addCurve(to: CGPoint(x: w, y: -2),
                        control1: CGPoint(x: -w * 0.45, y: 19 * p.smile),
                        control2: CGPoint(x: w * 0.45, y: 19 * p.smile))
            cg.setStrokeColor(UIColor(red: 198.0 / 255.0, green: 96.0 / 255.0,
                                      blue: 88.0 / 255.0, alpha: 1).cgColor)
            cg.setLineWidth(3.4)
            cg.strokePath()
        } else {
            let h = 8 + open * 43
            let round = p.round
            let mouthPath = CGMutablePath()
            mouthPath.move(to: CGPoint(x: -w, y: 0))
            mouthPath.addCurve(to: CGPoint(x: w, y: 0),
                               control1: CGPoint(x: -w * 0.7, y: -7 - round * 5),
                               control2: CGPoint(x: w * 0.7, y: -7 - round * 5))
            mouthPath.addCurve(to: CGPoint(x: -w, y: 0),
                               control1: CGPoint(x: w * 0.94, y: h * 1.15),
                               control2: CGPoint(x: -w * 0.94, y: h * 1.15))
            mouthPath.closeSubpath()
            cg.setFillColor(UIColor(red: 116.0 / 255.0, green: 44.0 / 255.0,
                                    blue: 68.0 / 255.0, alpha: 1).cgColor)
            cg.addPath(mouthPath)
            cg.fillPath()
            cg.setStrokeColor(UIColor(red: 185.0 / 255.0, green: 91.0 / 255.0,
                                      blue: 97.0 / 255.0, alpha: 1).cgColor)
            cg.setLineWidth(2.8)
            cg.addPath(mouthPath)
            cg.strokePath()
            cg.saveGState()
            cg.addPath(mouthPath)
            cg.clip()
            cg.setFillColor(UIColor(red: 242.0 / 255.0, green: 141.0 / 255.0,
                                    blue: 156.0 / 255.0, alpha: 1).cgColor)
            cg.fillEllipse(in: CGRect(x: 2 - w * 0.66, y: h * 0.94 - h * 0.36,
                                      width: w * 1.32, height: h * 0.72))
            if p.joy > 0.7 {
                cg.setFillColor(UIColor(red: 1, green: 250.0 / 255.0,
                                        blue: 247.0 / 255.0, alpha: 1).cgColor)
                cg.fill(CGRect(x: -w, y: -6, width: w * 2, height: 10))
            }
            cg.restoreGState()
        }
        cg.restoreGState()
    }

    // MARK: - Blush, tears, fins

    private func paintTears(_ cg: CGContext, p: BotFishParams, time: Double, baseAlpha: Double) {
        cg.saveGState()
        design(cg)
        for (x, offset) in [(345.0, 0.0), (680.0, 0.45)] {
            let q = (time / 1900 + offset).truncatingRemainder(dividingBy: 1)
            let y = 658 + q * 75
            cg.setAlpha(CGFloat(baseAlpha * p.tears * sin(q * Double.pi)))
            let color = UIColor(red: 142.0 / 255.0, green: 214.0 / 255.0,
                                blue: 240.0 / 255.0, alpha: 1)
            let stroke = UIColor(red: 104.0 / 255.0, green: 170.0 / 255.0,
                                 blue: 203.0 / 255.0, alpha: 1)
            cg.setFillColor(color.cgColor)
            cg.setStrokeColor(stroke.cgColor)
            cg.setLineWidth(1.5)
            cg.move(to: CGPoint(x: x, y: y - 9))
            cg.addCurve(to: CGPoint(x: x, y: y - 9),
                        control1: CGPoint(x: x - 13, y: y + 14),
                        control2: CGPoint(x: x + 13, y: y + 14))
            cg.fillPath()
            cg.move(to: CGPoint(x: x, y: y - 9))
            cg.addCurve(to: CGPoint(x: x, y: y - 9),
                        control1: CGPoint(x: x - 13, y: y + 14),
                        control2: CGPoint(x: x + 13, y: y + 14))
            cg.strokePath()
        }
        cg.setAlpha(CGFloat(baseAlpha))
        cg.restoreGState()
    }

    private func paintFin(_ cg: CGContext, side: Double, amount: Double, wave: Double,
                          fold: Double, baseAlpha: Double) {
        guard amount >= 0.05 else { return }
        cg.saveGState()
        cg.setAlpha(CGFloat(baseAlpha * BotFishMath.clamp((amount - 0.05) / 0.35, 0, 1)))
        cg.translateBy(x: CGFloat((side < 0 ? 111.0 : 401.0) - side * fold * 82),
                       y: CGFloat(402 - amount * 12))
        cg.scaleBy(x: CGFloat(side), y: 1)
        cg.rotate(by: CGFloat(-0.42 * amount + wave * 0.45 + fold * 0.7))
        cg.setFillColor(palette.mid.cgColor)
        cg.setStrokeColor(palette.ink.cgColor)
        cg.setLineWidth(2.2)
        let finPath = CGMutablePath()
        finPath.move(to: CGPoint(x: -9, y: 7))
        finPath.addCurve(to: CGPoint(x: 25, y: -42),
                         control1: CGPoint(x: 9, y: -6), control2: CGPoint(x: 17, y: -22))
        finPath.addCurve(to: CGPoint(x: 43, y: -55),
                         control1: CGPoint(x: 29, y: -53), control2: CGPoint(x: 39, y: -59))
        finPath.addCurve(to: CGPoint(x: 41, y: -31),
                         control1: CGPoint(x: 48, y: -52), control2: CGPoint(x: 43, y: -37))
        finPath.addCurve(to: CGPoint(x: 52, y: -24),
                         control1: CGPoint(x: 51, y: -39), control2: CGPoint(x: 57, y: -34))
        finPath.addCurve(to: CGPoint(x: 55, y: -11),
                         control1: CGPoint(x: 61, y: -28), control2: CGPoint(x: 64, y: -20))
        finPath.addCurve(to: CGPoint(x: -9, y: 7),
                         control1: CGPoint(x: 35, y: 7), control2: CGPoint(x: 11, y: 18))
        finPath.closeSubpath()
        cg.addPath(finPath)
        cg.fillPath()
        cg.addPath(finPath)
        cg.strokePath()
        cg.setFillColor(palette.light.cgColor)
        cg.move(to: CGPoint(x: 4, y: 5))
        cg.addQuadCurve(to: CGPoint(x: 44, y: -24), control: CGPoint(x: 30, y: -16))
        cg.addQuadCurve(to: CGPoint(x: 4, y: 5), control: CGPoint(x: 31, y: 2))
        cg.fillPath()
        cg.restoreGState()
    }

    // MARK: - Decorations

    private func paintDecorations(_ cg: CGContext, p: BotFishParams, time: Double,
                                  baseAlpha: Double) {
        let decoration = p.decoration
        guard !decoration.isEmpty else { return }
        let phase = p.phase
        // Decorations are part of the avatar's readable motion. On the 32pt
        // header they receive the same small-size boost as the pose, without
        // moving their fixed anchors outside the circular canvas.
        let motion = p.motionScale
        cg.saveGState()
        cg.setLineCap(.round)
        cg.setLineJoin(.round)

        switch decoration {
        case "dots", "waiting":
            let x = decoration == "dots" ? 353.0 : 78.0
            let y = decoration == "dots" ? 64.0 : 369.0
            for index in 0..<3 {
                cg.setAlpha(CGFloat(baseAlpha * (0.35 + 0.65 * (0.5 + 0.5 * sin(phase * BotFishRenderer.tau - Double(index) * 0.7)))))
                cg.setFillColor(palette.ink.cgColor)
                cg.fillEllipse(in: CGRect(x: x + Double(index) * 13 - 3.6, y: y - 3.6,
                                          width: 7.2, height: 7.2))
            }
        case "alert":
            cg.setStrokeColor(UIColor(red: 206.0 / 255.0, green: 94.0 / 255.0,
                                      blue: 73.0 / 255.0, alpha: 1).cgColor)
            cg.setLineWidth(5)
            cg.move(to: CGPoint(x: 418, y: 75))
            cg.addLine(to: CGPoint(x: 418, y: 95))
            cg.strokePath()
            cg.setFillColor(UIColor(red: 206.0 / 255.0, green: 94.0 / 255.0,
                                    blue: 73.0 / 255.0, alpha: 1).cgColor)
            cg.fillEllipse(in: CGRect(x: 415, y: 102, width: 6, height: 6))
        case "question":
            cg.setStrokeColor(UIColor(red: 116.0 / 255.0, green: 96.0 / 255.0,
                                      blue: 152.0 / 255.0, alpha: 1).cgColor)
            cg.setLineWidth(4.2)
            cg.move(to: CGPoint(x: 402, y: 83))
            cg.addCurve(to: CGPoint(x: 429, y: 79),
                        control1: CGPoint(x: 400, y: 65), control2: CGPoint(x: 426, y: 63))
            cg.addCurve(to: CGPoint(x: 416, y: 101),
                        control1: CGPoint(x: 430, y: 90), control2: CGPoint(x: 415, y: 89))
            cg.strokePath()
            cg.setFillColor(UIColor(red: 116.0 / 255.0, green: 96.0 / 255.0,
                                    blue: 152.0 / 255.0, alpha: 1).cgColor)
            cg.fillEllipse(in: CGRect(x: 413.5, y: 108.5, width: 5, height: 5))
        case "sleep":
            let r = 10 + 3 * motion * sin(phase * BotFishRenderer.tau)
            cg.setStrokeColor(UIColor(red: 138.0 / 255.0, green: 172.0 / 255.0,
                                      blue: 192.0 / 255.0, alpha: 1).cgColor)
            cg.setFillColor(UIColor(red: 175.0 / 255.0, green: 214.0 / 255.0,
                                    blue: 232.0 / 255.0, alpha: 0.3).cgColor)
            cg.setLineWidth(1.4)
            cg.fillEllipse(in: CGRect(x: 407 - r, y: 177 - r, width: r * 2, height: r * 2))
            cg.strokeEllipse(in: CGRect(x: 407 - r, y: 177 - r, width: r * 2, height: r * 2))
            drawZ(cg, x: 420, y: 132, size: 24,
                  color: UIColor(red: 126.0 / 255.0, green: 149.0 / 255.0,
                                 blue: 175.0 / 255.0, alpha: 1))
            drawZ(cg, x: 441, y: 116, size: 16,
                  color: UIColor(red: 126.0 / 255.0, green: 149.0 / 255.0,
                                 blue: 175.0 / 255.0, alpha: 1))
        case "listen":
            cg.setStrokeColor(UIColor(red: 105.0 / 255.0, green: 166.0 / 255.0,
                                      blue: 181.0 / 255.0, alpha: 1).cgColor)
            cg.setLineWidth(1.7)
            for side in [-1.0, 1.0] {
                for index in 0..<2 {
                    cg.setAlpha(CGFloat(baseAlpha * (0.35 + 0.4 * (0.5 + 0.5 * sin(phase * BotFishRenderer.tau - Double(index))))))
                    let x = side < 0 ? 35.0 : 477.0
                    cg.addArc(center: CGPoint(x: x, y: 248), radius: CGFloat(10 + Double(index) * 8),
                              startAngle: CGFloat(side < 0 ? 2.3 : -0.8),
                              endAngle: CGFloat(side < 0 ? 4.0 : 0.8), clockwise: false)
                    cg.strokePath()
                }
            }
        case "hearts":
            heart(cg, x: 78, y: 140 - 8 * motion * sin(phase * BotFishRenderer.tau), r: 10,
                  color: UIColor(red: 230.0 / 255.0, green: 109.0 / 255.0,
                                 blue: 159.0 / 255.0, alpha: 1), alpha: 0.75)
            heart(cg, x: 420, y: 86 - 6 * motion * sin(phase * BotFishRenderer.tau + 1), r: 12,
                  color: UIColor(red: 230.0 / 255.0, green: 109.0 / 255.0,
                                 blue: 159.0 / 255.0, alpha: 1), alpha: 0.8)
            heart(cg, x: 448, y: 122, r: 6,
                  color: UIColor(red: 241.0 / 255.0, green: 160.0 / 255.0,
                                 blue: 188.0 / 255.0, alpha: 1), alpha: 0.7)
        case "spark":
            cg.setStrokeColor(UIColor(red: 225.0 / 255.0, green: 172.0 / 255.0,
                                      blue: 86.0 / 255.0, alpha: 1).cgColor)
            cg.setLineWidth(2)
            for (x, y, r) in [(80.0, 140.0, 8.0), (425.0, 89.0, 9.0)] {
                cg.move(to: CGPoint(x: x - r, y: y))
                cg.addLine(to: CGPoint(x: x + r, y: y))
                cg.move(to: CGPoint(x: x, y: y - r))
                cg.addLine(to: CGPoint(x: x, y: y + r))
                cg.strokePath()
            }
        case "anger":
            cg.setStrokeColor(UIColor(red: 190.0 / 255.0, green: 104.0 / 255.0,
                                      blue: 109.0 / 255.0, alpha: 1).cgColor)
            cg.setLineWidth(2.4)
            cg.move(to: CGPoint(x: 376, y: 180))
            cg.addLine(to: CGPoint(x: 381, y: 183))
            cg.addLine(to: CGPoint(x: 386, y: 179))
            cg.move(to: CGPoint(x: 380, y: 187))
            cg.addLine(to: CGPoint(x: 383, y: 191))
            cg.strokePath()
        case "confetti":
            let colors = [
                UIColor(red: 215.0 / 255.0, green: 124.0 / 255.0, blue: 144.0 / 255.0, alpha: 1),
                UIColor(red: 212.0 / 255.0, green: 173.0 / 255.0, blue: 87.0 / 255.0, alpha: 1),
                UIColor(red: 109.0 / 255.0, green: 174.0 / 255.0, blue: 165.0 / 255.0, alpha: 1),
                UIColor(red: 155.0 / 255.0, green: 131.0 / 255.0, blue: 192.0 / 255.0, alpha: 1),
            ]
            for index in 0..<12 {
                let x = 44.0 + Double((index * 83) % 420)
                let travel = Int(phase * 125 * motion) + index * 31
                let y = 35.0 + Double(travel % 154)
                cg.saveGState()
                cg.translateBy(x: x, y: y)
                cg.rotate(by: CGFloat(Double(index) + phase * BotFishRenderer.tau))
                cg.setFillColor(colors[index % 4].cgColor)
                cg.fill(CGRect(x: -2, y: -4, width: 4, height: 8))
                cg.restoreGState()
            }
        case "loading":
            for index in 0..<8 {
                let a = Double(index) * BotFishRenderer.tau / 8 + phase * BotFishRenderer.tau
                cg.setAlpha(CGFloat(baseAlpha * (0.25 + 0.75 * Double(index) / 8)))
                cg.setFillColor(palette.ink.cgColor)
                cg.fillEllipse(in: CGRect(x: 418 + cos(a) * 18 - 2.5,
                                          y: 96 + sin(a) * 18 - 2.5, width: 5, height: 5))
            }
        case "check":
            cg.setStrokeColor(UIColor(red: 66.0 / 255.0, green: 152.0 / 255.0,
                                      blue: 121.0 / 255.0, alpha: 1).cgColor)
            cg.setLineWidth(4)
            cg.move(to: CGPoint(x: 401, y: 92))
            cg.addLine(to: CGPoint(x: 412, y: 103))
            cg.addLine(to: CGPoint(x: 433, y: 79))
            cg.strokePath()
        case "music":
            cg.setStrokeColor(UIColor(red: 151.0 / 255.0, green: 128.0 / 255.0,
                                      blue: 183.0 / 255.0, alpha: 1).cgColor)
            cg.setFillColor(UIColor(red: 151.0 / 255.0, green: 128.0 / 255.0,
                                    blue: 183.0 / 255.0, alpha: 1).cgColor)
            cg.setLineWidth(2.8)
            for (x, y) in [(77.0, 133.0), (427.0, 112.0)] {
                cg.move(to: CGPoint(x: x, y: y))
                cg.addLine(to: CGPoint(x: x, y: y - 22))
                cg.addLine(to: CGPoint(x: x + 13, y: y - 26))
                cg.strokePath()
                cg.fillEllipse(in: CGRect(x: x - 9, y: y - 3, width: 10, height: 6))
            }
        default:
            break
        }
        cg.setAlpha(CGFloat(baseAlpha))
        cg.restoreGState()
    }

    private func drawZ(_ cg: CGContext, x: Double, y: Double, size: Double, color: UIColor) {
        cg.saveGState()
        cg.setStrokeColor(color.cgColor)
        cg.setLineWidth(max(1, size * 0.09))
        cg.move(to: CGPoint(x: x, y: y))
        cg.addLine(to: CGPoint(x: x + size * 0.62, y: y))
        cg.addLine(to: CGPoint(x: x, y: y + size * 0.7))
        cg.addLine(to: CGPoint(x: x + size * 0.68, y: y + size * 0.7))
        cg.strokePath()
        cg.restoreGState()
    }

    private func heart(_ cg: CGContext, x: Double, y: Double, r: Double,
                       color: UIColor, alpha: Double = 1) {
        cg.saveGState()
        if alpha < 1 {
            // Callers that already set a global alpha still get the decoration
            // alpha; multiplying through `setAlpha` is not readable, so bake
            // the requested alpha into the fill colour.
            cg.setAlpha(CGFloat(alpha))
        }
        cg.setFillColor(color.cgColor)
        cg.translateBy(x: CGFloat(x), y: CGFloat(y))
        cg.move(to: CGPoint(x: 0, y: r * 0.8))
        cg.addCurve(to: CGPoint(x: 0, y: -r * 0.35),
                    control1: CGPoint(x: -r * 1.5, y: -r * 0.1),
                    control2: CGPoint(x: -r * 0.8, y: -r * 1.1))
        cg.addCurve(to: CGPoint(x: 0, y: r * 0.8),
                    control1: CGPoint(x: r * 0.8, y: -r * 1.1),
                    control2: CGPoint(x: r * 1.5, y: -r * 0.1))
        cg.fillPath()
        cg.restoreGState()
    }

    private func design(_ cg: CGContext) {
        cg.translateBy(x: BotFishRenderer.pad, y: BotFishRenderer.pad)
        cg.scaleBy(x: BotFishRenderer.scale, y: BotFishRenderer.scale)
    }
}
