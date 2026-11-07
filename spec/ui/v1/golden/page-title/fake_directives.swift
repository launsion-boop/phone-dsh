// SPDX-License-Identifier: MIT
import SwiftUI

struct FixturePage: View {
    var body: some View {
        VStack {
            // .navigationTitle("Comment") NavigationLink { }
            /* .sheet(isPresented: x) { Text("Fake").navigationTitle("Bad") } */
            Text(#".navigationTitle("Fake") NavigationLink { }"#)
            Text("""
                .navigationTitle("Multiline fake")
                NavigationLink { }
                """)
        }.navigationTitle("Parent")
    }
}
