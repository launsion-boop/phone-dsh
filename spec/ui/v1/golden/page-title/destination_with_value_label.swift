import SwiftUI

struct FixturePage: View {
    var body: some View {
        NavigationLink(value: "id") { Text("Open") }
            .navigationDestination(for: String.self) { _ in
                Text("Child body").navigationTitle("Child")
            }
            .navigationTitle("Parent")
    }
}
