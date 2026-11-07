import SwiftUI

struct FixturePage: View {
    var body: some View {
        VStack {
            Text("é + e\u{301} + 🌱")
            Text("Root")
        }
        .navigationTitle("标题")
    }
}
