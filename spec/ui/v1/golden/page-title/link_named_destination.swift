// SPDX-License-Identifier: MIT
import SwiftUI

struct FixturePage: View {
    var body: some View {
        List {
            NavigationLink(destination: Text("Child body").navigationTitle("Child")) {
                Text("Open")
            }
        }.navigationTitle("Parent")
    }
}
