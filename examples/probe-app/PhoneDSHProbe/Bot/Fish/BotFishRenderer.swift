// SPDX-License-Identifier: MIT

// Core Graphics port of dsh-bot `src/renderer/lib/fish/paint.js` plus the
// 8px head-slice compositing from `renderFrame`. All painting coordinates are
// the upstream 512px / 1024 design units, so the code can be compared
// line-by-line with the reference.
//
// Performance model (PR #75 follow-up):
//  * The static body/fixed/blush/eye/sprite layers are scaled to the exact
//    display pixel size once, process-wide, and blitted 1:1 afterwards.
//  * The whole-fish translate/rotate/scale pose is *not* rasterised here; the
//    SwiftUI view applies it on the GPU. The renderer only rebuilds the face
//    layer when a quantised facial parameter actually changed, and the two
//    displayed layers are reused otherwise.
//  * Head-slice motion needs a per-row offset, so it still runs on the CPU.
//    It is quantised to 0.1 source units and skipped entirely at <= 40pt,
//    where the largest slice displacement is below one output pixel.

import Foundation
import PhoneDSHBot
import UIKit

/// The pose passed to SwiftUI's GPU transform. Offsets are in points; the
/// renderer's source-space values are converted by the engine.
struct BotFishPose: Equatable {
    var offsetX: CGFloat = 0
    var offsetY: CGFloat = 0
    var roll: Double = 0
    var scaleX: Double = 1
    var scaleY: Double = 1
}

/// The two display-sized layers a frame is composed from. Both are owned by
/// the renderer (and by the shared image cache) and stay valid until the next
/// `prepare` call that changes them.
struct BotFishPreparedFrame {
    var base: CGImage
    var face: CGImage
}

private struct BotFishFaceSignature: Equatable {
    var eyeL: Int
    var eyeR: Int
    var joy: Int
    var browL: Int
    var browR: Int
    var anger: Int
    var sorrow: Int
    var smile: Int
    var mouth: Int
    var mouthWidth: Int
    var round: Int
    var blush: Int
    var tears: Int
    var love: Int
    var gazeX: Int
    var gazeY: Int
    var blink: Int
    var artMix: Int
    var finL: Int
    var finR: Int
    var finWave: Int
    var finFold: Int
    var decorationPhase: Int
    var tearsTime: Int
    var motionScale: Int
    var eyeArt: String?
    var mouthArt: String?
    var eyeArtPrev: String?
    var mouthArtPrev: String?
    var decoration: String
}

private struct BotFishHeadSignature: Equatable {
    var headX: Int
    var headY: Int
    var hairSway: Int
    var earFlutter: Int

    static let identity = BotFishHeadSignature(headX: 0, headY: 0,
                                               hairSway: 0, earFlutter: 0)
    var isIdentity: Bool { self == Self.identity }
}

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
    static let motionBoostSmallSize: CGFloat = 40
    static let motionBoostLargeSize: CGFloat = 64
    static let motionBoostFactor: Double = 2.2
    static let motionBoostMaxTranslation: Double = 20
    static let motionBoostMaxRoll: Double = 9

    /// Below this size the 8px source slices move by less than one device
    /// pixel, so the CPU slice pass is skipped (the upstream pose boost keeps
    /// the visible motion).
    static let headSlicingMinimumSize: CGFloat = 40

    /// Head-slice inputs are quantised to 1/10 source unit (~0.07px at 96pt
    /// @3x). Anything finer changed no displayed pixel.
    private static let headSliceQuantum = 0.1

    private let assets: BotFishAssets?
    private var palette = BotFishPalette.blue
    private var hairstyle: BotFishHairstyle = .long

    private var pixelSide = 0
    private var baseTransform = CGAffineTransform.identity
    private var faceContext: CGContext?
    /// Allocated only when the state actually paints brows / head-slice
    /// motion. A 42-tile still gallery therefore keeps one context per tile,
    /// not five.
    private var browContext: CGContext?
    private var slicedBaseContext: CGContext?
    private var slicedFaceContext: CGContext?

    private var appearanceKey: String?
    private var baseImage: CGImage?
    private var faceImage: CGImage?
    private var faceSignature: BotFishFaceSignature?
    private var faceGeneration = 0

    private struct SliceKey: Equatable {
        var faceGeneration: Int
        var head: BotFishHeadSignature
    }
    private var sliceKey: SliceKey?
    private var slicedBase: CGImage?
    private var slicedFace: CGImage?

    init() {
        assets = BotFishAssets.shared
    }

    static func pixelSide(size: CGFloat, displayScale: CGFloat) -> Int {
        max(1, Int(ceil(Double(max(1, size) * max(1, displayScale)))))
    }

    static func motionBoost(for size: CGFloat) -> Double {
        if size <= motionBoostSmallSize { return motionBoostFactor }
        if size >= motionBoostLargeSize { return 1 }
        let t = Double((size - motionBoostSmallSize)
            / (motionBoostLargeSize - motionBoostSmallSize))
        return motionBoostFactor + (1 - motionBoostFactor) * t
    }

    /// Quantised head-slice inputs. Values are source-space tenths of a pixel.
    private static func headSignature(_ p: BotFishParams, size: CGFloat) -> BotFishHeadSignature {
        guard size > headSlicingMinimumSize else { return .identity }
        func quantise(_ value: Double) -> Int {
            Int((value / headSliceQuantum).rounded())
        }
        return BotFishHeadSignature(headX: quantise(p.headX),
                                    headY: quantise(p.headY),
                                    hairSway: quantise(p.hairSway),
                                    earFlutter: quantise(p.earFlutter))
    }

    // MARK: - Frame preparation

    func prepare(_ params: BotFishParams, time: Double, size: CGFloat,
                 displayScale: CGFloat,
                 appearance: BotFishAppearance = .classic) -> BotFishPreparedFrame? {
        guard let assets, !assets.eyeCels.isEmpty, !assets.mouthCels.isEmpty else {
            return nil
        }
        let target = Self.pixelSide(size: size, displayScale: displayScale)
        guard prepareContexts(target) else { return nil }

        let key = "\(appearance.hairstyle.rawValue):\(appearance.color.rawValue)@\(target)"
        if appearanceKey != key {
            guard buildBase(appearance: appearance, assets: assets, target: target) else {
                return nil
            }
            appearanceKey = key
            faceImage = nil
            faceSignature = nil
            slicedBase = nil
            slicedFace = nil
            sliceKey = nil
            faceGeneration &+= 1
        }

        let signature = Self.faceSignature(params, time: time)
        if faceImage == nil || faceSignature != signature {
            guard renderFace(params, time: time, assets: assets) else { return nil }
            faceImage = faceContext?.makeImage()
            guard faceImage != nil else { return nil }
            faceSignature = signature
            faceGeneration &+= 1
            sliceKey = nil
        }

        guard let baseImage, let faceImage else { return nil }
        let head = Self.headSignature(params, size: size)
        if !head.isIdentity {
            let key = SliceKey(faceGeneration: faceGeneration, head: head)
            if sliceKey != key || slicedBase == nil || slicedFace == nil {
                guard ensureSliceContexts(),
                      let b = sliceImage(baseImage, head: head, into: slicedBaseContext,
                                         target: target),
                      let f = sliceImage(faceImage, head: head, into: slicedFaceContext,
                                         target: target)
                else { return nil }
                slicedBase = b
                slicedFace = f
                sliceKey = key
            }
            if let slicedBase, let slicedFace {
                return BotFishPreparedFrame(base: slicedBase, face: slicedFace)
            }
        }
        return BotFishPreparedFrame(base: baseImage, face: faceImage)
    }

    private func prepareContexts(_ target: Int) -> Bool {
        if pixelSide == target, faceContext != nil { return true }
        faceContext = nil
        browContext = nil
        slicedBaseContext = nil
        slicedFaceContext = nil
        pixelSide = 0
        baseImage = nil
        faceImage = nil
        faceSignature = nil
        appearanceKey = nil
        slicedBase = nil
        slicedFace = nil
        sliceKey = nil
        baseTransform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                                          tx: 0, ty: CGFloat(target))
        guard let face = makeContext(target) else { return false }
        // Turn the identity CTM into the top-left base transform, then keep
        // that state at the bottom of the stack. `resetCTM` restores this
        // snapshot before every paint instead of relying on an unavailable
        // setCTM.
        face.concatenate(baseTransform)
        face.saveGState()
        pixelSide = target
        faceContext = face
        faceGeneration &+= 1
        return true
    }

    private func ensureSliceContexts() -> Bool {
        if slicedBaseContext == nil {
            guard let context = makeContext(pixelSide) else { return false }
            context.concatenate(baseTransform)
            context.saveGState()
            slicedBaseContext = context
        }
        if slicedFaceContext == nil {
            guard let context = makeContext(pixelSide) else { return false }
            context.concatenate(baseTransform)
            context.saveGState()
            slicedFaceContext = context
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

    private var pixelScale: CGFloat {
        CGFloat(pixelSide) / BotFishRenderer.cropSide
    }

    /// `CGContext` exposes no public `setCTM`. Each reusable context is
    /// created at `baseTransform` and pushed once; a reset pops back to that
    /// snapshot and immediately re-pushes it so the next draw starts from the
    /// base transform again.
    private func resetCTM(_ cg: CGContext) {
        cg.restoreGState()
        cg.saveGState()
        cg.setAlpha(1)
        cg.setBlendMode(.normal)
        cg.setShouldAntialias(true)
    }

    /// Draws a `CGImage` upright inside the flipped (top-left origin) context.
    /// The local flip is undone by `restoreGState`, so callers keep their CTM,
    /// alpha and blend mode.
    private func drawUpright(_ image: CGImage, in rect: CGRect, on cg: CGContext) {
        cg.saveGState()
        cg.translateBy(x: rect.minX, y: rect.maxY)
        cg.scaleBy(x: 1, y: -1)
        cg.draw(image, in: CGRect(origin: .zero, size: rect.size))
        cg.restoreGState()
    }

    private func drawUpright(_ image: UIImage, in rect: CGRect, on cg: CGContext) {
        guard let cgImage = image.cgImage else { return }
        drawUpright(cgImage, in: rect, on: cg)
    }

    // MARK: - Static layers

    private func buildBase(appearance: BotFishAppearance, assets: BotFishAssets,
                           target: Int) -> Bool {
        guard let layers = assets.layers(for: appearance.hairstyle),
              let context = makeContext(target)
        else { return false }
        let nextPalette = BotFishPalette(color: appearance.color)
        guard let body = assets.bodyLayer(hairstyle: appearance.hairstyle,
                                          palette: nextPalette,
                                          pixelSide: CGFloat(target)),
              let bodyLayer = BotFishImageCache.shared.croppedLayer(
                  body, key: "body:\(appearance.hairstyle.rawValue):\(nextPalette.id)@\(target)",
                  pixelSide: target),
              let fixedSource = layers.fixed.cgImage,
              let fixedLayer = BotFishImageCache.shared.croppedLayer(
                  fixedSource, key: "fixed:\(appearance.hairstyle.rawValue)@\(target)",
                  pixelSide: target)
        else { return false }
        palette = nextPalette
        hairstyle = appearance.hairstyle
        context.concatenate(baseTransform)
        context.clear(fullPixelRect)
        drawUpright(bodyLayer, in: fullPixelRect, on: context)
        drawUpright(fixedLayer, in: fullPixelRect, on: context)
        baseImage = context.makeImage()
        return baseImage != nil
    }

    private func croppedAsset(_ image: UIImage, key: String) -> CGImage? {
        guard let source = image.cgImage else { return nil }
        return BotFishImageCache.shared.croppedLayer(
            source, key: "\(key)@\(pixelSide)", pixelSide: pixelSide)
    }

    // MARK: - Face layer

    private static func faceSignature(_ p: BotFishParams, time: Double) -> BotFishFaceSignature {
        func q(_ value: Double, _ step: Double = 1.0 / 64.0) -> Int {
            Int((value / step).rounded())
        }
        let animatedPhase: Double
        switch p.decoration {
        case "dots", "waiting", "sleep", "listen", "hearts", "confetti", "loading":
            animatedPhase = p.phase
        default:
            animatedPhase = 0
        }
        return BotFishFaceSignature(
            eyeL: q(p.eyeL), eyeR: q(p.eyeR), joy: q(p.joy),
            browL: q(p.browL), browR: q(p.browR),
            anger: q(p.anger), sorrow: q(p.sorrow),
            smile: q(p.smile), mouth: q(p.mouth),
            mouthWidth: q(p.mouthWidth, 0.02), round: q(p.round),
            blush: q(p.blush), tears: q(p.tears), love: q(p.love),
            gazeX: q(p.gazeX, 0.05), gazeY: q(p.gazeY, 0.05),
            blink: q(p.blink), artMix: q(p.artMix, 1.0 / 16.0),
            finL: q(p.finL), finR: q(p.finR),
            finWave: q(p.finWave, 1.0 / 32.0), finFold: q(p.finFold),
            decorationPhase: q(animatedPhase, 1.0 / 24.0),
            // Tears are the only face painter that reads the raw clock. When
            // no tears are visible the signature must stay constant so an
            // idle avatar does not repaint on every tick.
            tearsTime: p.tears > 0.01 ? q(time / 40.0, 1.0) : 0,
            motionScale: q(p.motionScale, 0.05),
            eyeArt: p.eyeArt, mouthArt: p.mouthArt,
            eyeArtPrev: p.eyeArtPrev, mouthArtPrev: p.mouthArtPrev,
            decoration: p.decoration)
    }

    private func renderFace(_ params: BotFishParams, time: Double,
                            assets: BotFishAssets) -> Bool {
        guard let cg = faceContext else { return false }
        resetCTM(cg)
        cg.clear(fullPixelRect)

        if params.blush > 0.01,
           let blush = croppedAsset(assets.blush, key: "blush") {
            cg.saveGState()
            cg.setAlpha(CGFloat(BotFishMath.clamp(params.blush, 0, 1)))
            drawUpright(blush, in: fullPixelRect, on: cg)
            cg.restoreGState()
        }

        paintEye(cg, assets: assets, side: -1, p: params)
        paintEye(cg, assets: assets, side: 1, p: params)
        paintMouthCrossfade(cg, assets: assets, p: params)
        if params.tears > 0.01 {
            paintTears(cg, p: params, time: time)
        }
        paintFin(cg, side: -1, amount: params.finL, wave: params.finWave,
                 fold: params.finFold)
        paintFin(cg, side: 1, amount: params.finR, wave: -params.finWave,
                 fold: params.finFold)
        paintDecorations(cg, p: params)
        if params.eyeArt == nil, let brows = browImage(p: params, assets: assets) {
            cg.saveGState()
            cg.setAlpha(1)
            drawUpright(brows, in: fullPixelRect, on: cg)
            cg.restoreGState()
        }
        return true
    }

    // MARK: - Eyes

    private func paintEye(_ cg: CGContext, assets: BotFishAssets, side: Double,
                          p: BotFishParams) {
        if p.artMix < 1, p.eyeArtPrev != p.eyeArt {
            cg.saveGState()
            cg.setAlpha(CGFloat(1 - p.artMix))
            paintEyeLayer(cg, assets: assets, side: side, p: p, art: p.eyeArtPrev)
            cg.restoreGState()
            cg.saveGState()
            cg.setAlpha(CGFloat(p.artMix))
            paintEyeLayer(cg, assets: assets, side: side, p: p, art: p.eyeArt)
            cg.restoreGState()
            return
        }
        paintEyeLayer(cg, assets: assets, side: side, p: p, art: p.eyeArt)
    }

    private func paintEyeLayer(_ cg: CGContext, assets: BotFishAssets, side: Double,
                               p: BotFishParams, art: String?) {
        if let index = BotFishEyeCel.index(of: art) {
            let cel = index * 2 + (side < 0 ? 0 : 1)
            if cel < assets.eyeCels.count {
                let blink = max(0.035, p.blink)
                let sourceX = side < 0 ? 205.0 : 307.0
                let sourceY = 297.0 + (art == "laughing" ? 8 : 0)
                let sidePixels = max(1, Int((102 * pixelScale).rounded()))
                let image = eyeCelImage(cel, sidePixels: sidePixels, assets: assets)
                let offsetX = (sourceX + p.gazeX * 2 - Double(BotFishRenderer.cropOrigin.x))
                    * Double(pixelScale)
                let offsetY = (sourceY + p.gazeY * 1.2 - Double(BotFishRenderer.cropOrigin.y))
                    * Double(pixelScale)
                cg.saveGState()
                cg.translateBy(x: CGFloat(offsetX), y: CGFloat(offsetY))
                cg.scaleBy(x: 1, y: CGFloat(blink))
                if let image {
                    drawUpright(image,
                                in: CGRect(x: -CGFloat(sidePixels) / 2,
                                           y: -CGFloat(sidePixels) / 2,
                                           width: CGFloat(sidePixels),
                                           height: CGFloat(sidePixels)),
                                on: cg)
                }
                cg.restoreGState()
                return
            }
        }
        paintDesignEye(cg, assets: assets, side: side, p: p)
    }

    private func paintDesignEye(_ cg: CGContext, assets: BotFishAssets,
                                side: Double, p: BotFishParams) {
        let designX = side < 0 ? 399.0 : 624.0
        let designY = 603.0
        let open = BotFishMath.clamp((side < 0 ? p.eyeL : p.eyeR) * p.blink, 0, 1.2)
        let happy = BotFishMath.clamp(p.joy, 0, 1)
        let center = designPoint(designX, designY)
        let designToPixel = CGFloat(BotFishRenderer.scale) * pixelScale
        // The eye texture and its clip move together by `gaze * 2` / `* 1.2`
        // design units; the iris gets an additional clamped `* 8` / `* 6`.
        let irisX = BotFishMath.clamp(p.gazeX, -1, 1) * 8
        let irisY = BotFishMath.clamp(p.gazeY, -1, 1) * 6
        let moving = abs(irisX) + abs(irisY) > 0.05
        let centerShift = CGPoint(
            x: CGFloat(p.gazeX * 2) * designToPixel,
            y: CGFloat(p.gazeY * 1.2) * designToPixel)

        cg.saveGState()
        cg.translateBy(x: center.x + centerShift.x, y: center.y + centerShift.y)
        cg.scaleBy(x: designToPixel, y: designToPixel)
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
        // Back to pixel units; the clip set above lives in device space and
        // therefore survives the inverse scale.
        cg.scaleBy(x: 1 / designToPixel, y: 1 / designToPixel)
        let crop = eyeCropRect(side: side)
        let eyeImageOrigin = CGPoint(
            x: (crop.minX - BotFishRenderer.cropOrigin.x) * pixelScale,
            y: (crop.minY - BotFishRenderer.cropOrigin.y) * pixelScale)
        // Both the upstream clip and the eye texture translate together, so
        // keeping the (cropped) texture at a fixed offset from the
        // gaze-translated eye centre is equivalent and keeps the cache small.
        let localOrigin = CGPoint(
            x: eyeImageOrigin.x - center.x,
            y: eyeImageOrigin.y - center.y)
        if let eye = eyeBaseImage(side: side, moving: moving, assets: assets) {
            drawUpright(eye, in: CGRect(x: localOrigin.x, y: localOrigin.y,
                                        width: CGFloat(eye.width),
                                        height: CGFloat(eye.height)), on: cg)
        }
        if moving {
            let iris = side < 0 ? assets.irisLeft : assets.irisRight
            if let irisImage = eyeBaseImage(image: iris, side: side, key: "iris") {
                cg.saveGState()
                cg.translateBy(x: CGFloat(irisX) * designToPixel,
                               y: CGFloat(irisY) * designToPixel)
                drawUpright(irisImage, in: CGRect(x: localOrigin.x, y: localOrigin.y,
                                                  width: CGFloat(irisImage.width),
                                                  height: CGFloat(irisImage.height)),
                            on: cg)
                cg.restoreGState()
            }
        }
        if p.love > 0.05 {
            cg.saveGState()
            let heartX = side < 0 ? 410.5 : 625.5
            cg.translateBy(x: CGFloat((heartX - designX)) * designToPixel, y: 0)
            cg.scaleBy(x: designToPixel, y: designToPixel)
            heart(cg, x: 0, y: 0, r: 24,
                  color: UIColor(red: 223.0 / 255.0, green: 77.0 / 255.0,
                                 blue: 136.0 / 255.0, alpha: 1),
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

    /// A source-space crop around one default eye. The crop includes enough
    /// margin for the gaze translation; both the clip and the iris move inside
    /// it exactly like the upstream full-sheet draw.
    private func eyeCropRect(side: Double) -> CGRect {
        let designX = side < 0 ? 399.0 : 624.0
        let designY = 603.0
        let centerX = BotFishRenderer.pad + BotFishRenderer.scale * CGFloat(designX)
        let centerY = BotFishRenderer.pad + BotFishRenderer.scale * CGFloat(designY)
        let margin: CGFloat = 18
        let halfWidth = 102 * BotFishRenderer.scale + margin
        let halfHeight = 96 * BotFishRenderer.scale + margin
        return CGRect(x: centerX - halfWidth, y: centerY - halfHeight,
                      width: halfWidth * 2, height: halfHeight * 2).integral
    }

    private func eyeBaseImage(side: Double, moving: Bool,
                              assets: BotFishAssets) -> CGImage? {
        let image = moving ? assets.eyesWhite : assets.eyesOpen
        return eyeBaseImage(image: image, side: side,
                            key: moving ? "eyes-white" : "eyes-open")
    }

    private func eyeBaseImage(image: UIImage, side: Double, key: String) -> CGImage? {
        guard let source = image.cgImage else { return nil }
        let rect = eyeCropRect(side: side)
        let width = max(1, Int((rect.width * pixelScale).rounded()))
        let height = max(1, Int((rect.height * pixelScale).rounded()))
        return BotFishImageCache.shared.croppedPart(
            source, sourceRect: rect,
            key: "\(key):\(side < 0 ? "l" : "r")@\(pixelSide)",
            width: width, height: height)
    }

    private func eyeCelImage(_ index: Int, sidePixels: Int,
                             assets: BotFishAssets) -> CGImage? {
        guard index < assets.eyeCels.count,
              let source = assets.eyeCels[index].cgImage else { return nil }
        return BotFishImageCache.shared.scaledSheet(
            source, key: "eye-cel:\(index)@\(pixelSide):\(sidePixels)",
            width: sidePixels, height: sidePixels)
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

    private func browImage(p: BotFishParams, assets: BotFishAssets) -> CGImage? {
        guard abs(p.browL) + abs(p.browR) + p.anger + p.sorrow >= 0.02,
              let layers = assets.layers(for: hairstyle),
              let maskSource = layers.faceMask.cgImage
        else { return nil }
        if browContext == nil {
            guard let context = makeContext(pixelSide) else { return nil }
            context.concatenate(baseTransform)
            context.saveGState()
            browContext = context
        }
        guard let b = browContext else { return nil }
        resetCTM(b)
        b.clear(fullPixelRect)
        b.saveGState()
        b.translateBy(x: (BotFishRenderer.pad - BotFishRenderer.cropOrigin.x) * pixelScale,
                      y: (BotFishRenderer.pad - BotFishRenderer.cropOrigin.y) * pixelScale)
        b.scaleBy(x: BotFishRenderer.scale * pixelScale,
                  y: BotFishRenderer.scale * pixelScale)
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
        guard let mask = BotFishImageCache.shared.croppedLayer(
            maskSource, key: "face-mask:\(hairstyle.rawValue)@\(pixelSide)",
            pixelSide: pixelSide) else { return nil }
        b.setBlendMode(.destinationIn)
        drawUpright(mask, in: fullPixelRect, on: b)
        b.setBlendMode(.normal)
        return b.makeImage()
    }

    // MARK: - Mouth

    private func paintMouthCrossfade(_ cg: CGContext, assets: BotFishAssets,
                                     p: BotFishParams) {
        if p.artMix < 1, p.mouthArtPrev != p.mouthArt {
            cg.saveGState()
            cg.setAlpha(CGFloat(1 - p.artMix))
            paintMouthLayer(cg, assets: assets, p: p, art: p.mouthArtPrev)
            cg.restoreGState()
            cg.saveGState()
            cg.setAlpha(CGFloat(p.artMix))
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
            let width = max(1, Int((w * Double(pixelScale)).rounded()))
            let height = max(1, Int((w / 2 * Double(pixelScale)).rounded()))
            let bucket = Int((p.mouthWidth / 0.02).rounded())
            if let image = mouthCelImage(index, bucket: bucket,
                                         width: width, height: height, assets: assets) {
                let x = (256 - w / 2 - Double(BotFishRenderer.cropOrigin.x)) * Double(pixelScale)
                let y = (335 - w / 4 - Double(BotFishRenderer.cropOrigin.y)) * Double(pixelScale)
                drawUpright(image, in: CGRect(x: x, y: y,
                                              width: CGFloat(width),
                                              height: CGFloat(height)), on: cg)
            }
            return
        }
        paintMouth(cg, p: p)
    }

    private func mouthCelImage(_ index: Int, bucket: Int, width: Int, height: Int,
                               assets: BotFishAssets) -> CGImage? {
        guard index < assets.mouthCels.count,
              let source = assets.mouthCels[index].cgImage else { return nil }
        return BotFishImageCache.shared.scaledSheet(
            source, key: "mouth-cel:\(index):\(bucket)@\(pixelSide):\(width)x\(height)",
            width: width, height: height)
    }

    private func paintMouth(_ cg: CGContext, p: BotFishParams) {
        withDesignSpace(cg) {
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
        }
    }

    // MARK: - Blush, tears, fins

    private func paintTears(_ cg: CGContext, p: BotFishParams, time: Double) {
        withDesignSpace(cg) {
            for (x, offset) in [(345.0, 0.0), (680.0, 0.45)] {
                let q = (time / 1900 + offset).truncatingRemainder(dividingBy: 1)
                let y = 658 + q * 75
                cg.setAlpha(CGFloat(p.tears * sin(q * Double.pi)))
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
            cg.setAlpha(1)
        }
    }

    private func paintFin(_ cg: CGContext, side: Double, amount: Double, wave: Double,
                          fold: Double) {
        guard amount >= 0.05 else { return }
        withSourceSpace(cg) {
            cg.setAlpha(CGFloat(BotFishMath.clamp((amount - 0.05) / 0.35, 0, 1)))
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
            cg.setAlpha(1)
        }
    }

    // MARK: - Decorations

    private func paintDecorations(_ cg: CGContext, p: BotFishParams) {
        let decoration = p.decoration
        guard !decoration.isEmpty else { return }
        let phase = p.phase
        let motion = p.motionScale
        withSourceSpace(cg) {
            cg.setLineCap(.round)
            cg.setLineJoin(.round)

            switch decoration {
            case "dots", "waiting":
                let x = decoration == "dots" ? 353.0 : 78.0
                let y = decoration == "dots" ? 64.0 : 369.0
                for index in 0..<3 {
                    cg.setAlpha(CGFloat(0.35 + 0.65 * (0.5 + 0.5 * sin(phase * BotFishRenderer.tau - Double(index) * 0.7))))
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
                        cg.setAlpha(CGFloat(0.35 + 0.4 * (0.5 + 0.5 * sin(phase * BotFishRenderer.tau - Double(index)))))
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
                    cg.setAlpha(CGFloat(0.25 + 0.75 * Double(index) / 8))
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
            cg.setAlpha(1)
        }
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

    // MARK: - Head slices

    private func sliceImage(_ source: CGImage, head: BotFishHeadSignature,
                            into context: CGContext?, target: Int) -> CGImage? {
        guard let cg = context else { return nil }
        resetCTM(cg)
        cg.clear(fullPixelRect)
        cg.setShouldAntialias(false)
        let scale = pixelScale
        let headX = Double(head.headX) * Self.headSliceQuantum
        let headY = Double(head.headY) * Self.headSliceQuantum
        let hairSway = Double(head.hairSway) * Self.headSliceQuantum
        let earFlutter = Double(head.earFlutter) * Self.headSliceQuantum
        var y = 0.0
        while y < Double(Self.size) {
            let nextY = min(Double(Self.size), y + 8)
            // The canvas starts at source y=30 (the circle crop).
            let yPixel = (CGFloat(y) - Self.cropOrigin.y) * scale
            let nextPixel = (CGFloat(nextY) - Self.cropOrigin.y) * scale
            // Snap both edges of every slice to whole output pixels so
            // adjacent slices share the same boundary: no antialiased hairline
            // and no double-composited translucent edge.
            let top = max(0, floor(yPixel))
            let bottom = min(CGFloat(target), floor(nextPixel))
            if bottom > top {
                let v = BotFishMath.clamp((y - 365) / 65, 0, 1)
                let headWeight = 1 - v * v * (3 - 2 * v)
                let dx = headX * (4.5 + (350 - y) * 0.009) * headWeight
                    + hairSway * max(0, (y - 310) / 160)
                let dy = headY * 2.8 * headWeight
                    + earFlutter * exp(-pow((y - 245) / 45, 2))
                cg.saveGState()
                cg.translateBy(x: CGFloat(dx) * scale, y: CGFloat(dy) * scale)
                cg.clip(to: CGRect(x: 0, y: top,
                                   width: CGFloat(target), height: bottom - top))
                drawUpright(source, in: fullPixelRect, on: cg)
                cg.restoreGState()
            }
            y = nextY
        }
        cg.setShouldAntialias(true)
        return cg.makeImage()
    }

    // MARK: - Space helpers

    private func designPoint(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: (BotFishRenderer.pad + BotFishRenderer.scale * CGFloat(x)
                    - BotFishRenderer.cropOrigin.x) * pixelScale,
                y: (BotFishRenderer.pad + BotFishRenderer.scale * CGFloat(y)
                    - BotFishRenderer.cropOrigin.y) * pixelScale)
    }

    private func withDesignSpace(_ cg: CGContext, _ body: () -> Void) {
        cg.saveGState()
        cg.translateBy(x: (BotFishRenderer.pad - BotFishRenderer.cropOrigin.x) * pixelScale,
                       y: (BotFishRenderer.pad - BotFishRenderer.cropOrigin.y) * pixelScale)
        cg.scaleBy(x: BotFishRenderer.scale * pixelScale,
                   y: BotFishRenderer.scale * pixelScale)
        body()
        cg.restoreGState()
    }

    private func withSourceSpace(_ cg: CGContext, _ body: () -> Void) {
        cg.saveGState()
        cg.translateBy(x: -BotFishRenderer.cropOrigin.x * pixelScale,
                       y: -BotFishRenderer.cropOrigin.y * pixelScale)
        cg.scaleBy(x: pixelScale, y: pixelScale)
        body()
        cg.restoreGState()
    }
}
