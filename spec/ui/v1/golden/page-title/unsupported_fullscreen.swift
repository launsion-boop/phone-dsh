import SwiftUI

struct FixturePage: View {
    var body: some View {
        Text("Root")
            .fullScreenCover(isPresented: .constant(true)) {
                Text("Child").navigationTitle("Child")
            }
            .navigationTitle("Parent")
    }
}
