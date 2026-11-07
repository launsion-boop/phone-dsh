// SPDX-License-Identifier: MIT
import SwiftUI
struct NavigationLink<Content: View>: View {
    let content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View { content }
}
struct FixturePage: View {
    var body: some View {
        NavigationLink("Open") {
            Text("Body").navigationTitle("Child")
        }
    }
}
