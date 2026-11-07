// SPDX-License-Identifier: MIT
import SwiftUI

struct FixturePage: View {
    var body: some View {
        List {
            NavigationLink {
                Text("Child body").navigationTitle("Child")
            } label: {
                Text("Open")
            }
        }.navigationTitle("Parent")
    }
}
