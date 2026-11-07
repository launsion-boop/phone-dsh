// SPDX-License-Identifier: MIT
import SwiftUI

struct FixturePage: View {
    var body: some View {
        Text("Root")
            .toolbar {
                ToolbarItem { Text("Tool").navigationTitle("Toolbar title") }
            }
            .navigationTitle("Parent")
    }
}
