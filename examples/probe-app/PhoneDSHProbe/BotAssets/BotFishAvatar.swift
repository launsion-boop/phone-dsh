// SPDX-License-Identifier: MIT

import SwiftUI
import UIKit
import PhoneDSHBot

public enum BotFishImageLoader {
    public static func resourceURL(for state: BotFishLifecycle, bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: state.rawValue, withExtension: "png", subdirectory: "BotAssets/expressions")
    }

    public static func image(for state: BotFishLifecycle, bundle: Bundle = .main) -> UIImage? {
        guard let url = resourceURL(for: state, bundle: bundle) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}

public struct BotFishAvatar: View {
    public let state: BotFishLifecycle
    public let size: CGFloat

    public init(state: BotFishLifecycle, size: CGFloat = 60) {
        self.state = state
        self.size = size
    }

    public var body: some View {
        if let image = BotFishImageLoader.image(for: state) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityLabel("大肥鱼，\(state.rawValue)")
        } else {
            ContentUnavailableView("头像资源缺失", systemImage: "exclamationmark.triangle")
                .frame(width: size, height: size)
                .accessibilityLabel("大肥鱼头像资源缺失：\(state.rawValue)")
        }
    }
}
