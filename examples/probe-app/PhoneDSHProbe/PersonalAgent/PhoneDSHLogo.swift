// SPDX-License-Identifier: MIT

import SwiftUI

struct PhoneDSHLogo: View {
    let size: CGFloat

    init(size: CGFloat = 32) {
        self.size = size
    }

    var body: some View {
        Image("LogoBackground")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
