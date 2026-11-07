import SwiftUI

struct FixturePage: View {
    var body: some View {
        Text("Root").navigationTitle("Parent")
    }
    private struct ChildPage: View {
        var body: some View { Text("Child").navigationTitle("Child") }

    }
}
