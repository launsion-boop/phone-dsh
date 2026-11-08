// SPDX-License-Identifier: MIT
import SwiftUI
extension String { func navigationTitle(_ title: String) -> String { title } }
struct FixturePage: View {
    var body: some View {
        let value = String("hello").navigationTitle("Fake")
        Text(value)
    }
}
