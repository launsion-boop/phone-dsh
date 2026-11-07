import SwiftUI
struct FixturePage: View {
    private var content: some View { Text("Hidden").navigationTitle("Fake") }
    var body: some View {
        let _ = content
        Text("Root")
    }
}
