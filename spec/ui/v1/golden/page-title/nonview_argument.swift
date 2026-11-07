// SPDX-License-Identifier: MIT
import SwiftUI
enum Model { static func navigationTitle(_ title: String) -> String { title } }
struct FixturePage: View {
    var body: some View {
        Text(Model.navigationTitle("Fake"))
    }
}
