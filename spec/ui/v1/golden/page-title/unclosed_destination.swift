import SwiftUI

struct FixturePage: View {
    var body: some View {
        List {
            NavigationLink("Open") {
                Text("Child").navigationTitle("Child")
        }.navigationTitle("Parent")
    }
}
