// SPDX-License-Identifier: MIT
import SwiftUI

struct FixturePage: View {
    var body: some View {
        NavigationLink("Open") {
            Text("Child body").navigationTitle("Child")
        }
    }
}
