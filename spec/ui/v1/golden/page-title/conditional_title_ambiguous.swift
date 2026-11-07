import SwiftUI

struct FixturePage: View {
    var body: some View {
        Group {
#if DEBUG
            Text("Debug").navigationTitle("Debug")
#else
            Text("Release").navigationTitle("Release")
#endif
        }
    }
}
