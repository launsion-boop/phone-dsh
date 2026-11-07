// SPDX-License-Identifier: MIT
import SwiftUI

struct FixturePage: View {
    var body: some View {
        NavigationLink(value: "id") {
            Text("Label").navigationTitle("Label title")
        }
        .navigationTitle("Parent")
    }
}
