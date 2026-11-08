// SPDX-License-Identifier: MIT
import SwiftUI

struct FixturePage: View { @State private var selection: String? = nil
    var body: some View {
        Text("Root")
            .navigationDestination(item: $selection) { item in
                Text("Child").navigationTitle("Child")
            }
            .navigationTitle("Parent")
    }
}
