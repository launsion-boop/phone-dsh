// SPDX-License-Identifier: MIT
import SwiftUI
extension Text {
    func navigationTitle(_ title: String) -> Text { self }
}
struct FixturePage: View {
    var body: some View {
        Text("Root").navigationTitle("Not a title")
    }
}
