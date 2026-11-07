// SPDX-License-Identifier: MIT
import SwiftUI

struct FixturePage: View {
    var body: some View {
        List {
            ScrollView { Text("Body") }.navigationTitle("Child")
        }.navigationTitle("Parent")
    }
}
