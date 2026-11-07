import SwiftUI

struct FixturePage: View {
    var body: some View {
        Text("Root")
            .navigationDestination(item: $selection) { item in
                Text("Child").navigationTitle("Child")
            }
            .navigationTitle("Parent")
    }
}
