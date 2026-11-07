import SwiftUI

struct FixturePage: View {
    var body: some View {
        let first = #/\{ .navigationTitle("Fake one")/#
        let second = ##/\} /# .navigationTitle("Fake two")/##
        Text("Root")
            .navigationTitle("Parent")
    }
}
