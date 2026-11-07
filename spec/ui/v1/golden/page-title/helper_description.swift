import SwiftUI
struct FixturePage: View {
    private var content: some View { Text("Hidden").navigationTitle("Fake") }
    var body: some View {
        Text(String(describing: content))
    }
}
