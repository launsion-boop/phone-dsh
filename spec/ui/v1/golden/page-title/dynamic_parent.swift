// SPDX-License-Identifier: MIT
import SwiftUI

struct FixturePage: View {
    var body: some View {
        Text("Root")
            .sheet(isPresented: .constant(true)) {
                Text("Child body").navigationTitle("Child")
            }
            .navigationTitle(model.title)
    }
}
