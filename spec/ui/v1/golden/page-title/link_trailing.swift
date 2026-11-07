import SwiftUI

struct FixturePage: View {
    var body: some View {
        List {
            NavigationLink("Open") {
                ScrollView { Text("Body") }.navigationTitle("Child")
            }
        }.navigationTitle("Parent")
    }
}
