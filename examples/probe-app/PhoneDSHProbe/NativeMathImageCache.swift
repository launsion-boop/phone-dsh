// SPDX-License-Identifier: MIT
// Inline-math bitmap cache.
//
// `MathImage.asImage()` rasterizes a LaTeX string into a UIImage on every call;
// the inline renderer used to do that inside the view body. The key carries
// exactly the inputs that change the bitmap: LaTeX, font size, display scale
// and the resolved light/dark palette.

import Foundation
import SwiftMath
import SwiftUI
import UIKit
import ProbeKit

enum NativeMathImageResult {
    case success(image: UIImage, ascent: CGFloat, descent: CGFloat)
    case failure
}

struct NativeMathImageKey: Hashable {
    let latex: String
    let fontSize: CGFloat
    let displayScale: CGFloat
    let colorScheme: Int
}

final class NativeMathImageCache {
    static let shared = NativeMathImageCache()
    static let countLimit = 256
    static let totalCostLimit = 32 * 1024 * 1024

    let cache: NativeBoundedCache<NativeMathImageKey, NativeMathImageResult>
    private(set) var rasterCount = 0

    init(countLimit: Int = NativeMathImageCache.countLimit,
         totalCostLimit: Int = NativeMathImageCache.totalCostLimit) {
        cache = NativeBoundedCache(name: "NativeMathImageCache",
                                   countLimit: countLimit,
                                   totalCostLimit: totalCostLimit)
    }

    func result(latex: String, fontSize: CGFloat, displayScale: CGFloat,
                colorScheme: ColorScheme) -> NativeMathImageResult {
        let scheme: Int
        switch colorScheme {
        case .dark: scheme = 2
        case .light: scheme = 1
        @unknown default: scheme = 0
        }
        let key = NativeMathImageKey(latex: latex, fontSize: fontSize,
                                     displayScale: displayScale, colorScheme: scheme)
        if let cached = cache.value(forKey: key) {
            return cached
        }
        rasterCount += 1
        NativePerfCounters.shared.mathRasterized()

        let style: UIUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        let traits = UITraitCollection(userInterfaceStyle: style)
        let color = UIColor(NativeChatTheme.primary).resolvedColor(with: traits)
        var renderer = MathImage(latex: latex, fontSize: fontSize, textColor: color,
                                 labelMode: .text, textAlignment: .left)
        let (error, image, layout) = renderer.asImage()
        let result: NativeMathImageResult
        if error == nil, let image {
            result = .success(image: image, ascent: layout?.ascent ?? 0, descent: layout?.descent ?? 0)
        } else {
            result = .failure
        }
        let cost: Int
        if case .success(let image, _, _) = result {
            cost = Int(image.size.width * image.scale
                       * image.size.height * image.scale * 4)
        } else {
            cost = 1
        }
        cache.insert(result, forKey: key, cost: cost)
        return result
    }

    func removeAll() {
        cache.removeAll()
    }

    func resetForTesting() {
        cache.removeAll()
        rasterCount = 0
    }
}
