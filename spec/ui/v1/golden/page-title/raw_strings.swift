import SwiftUI

struct FixturePage: View {
    var body: some View {
        VStack {
            Text(#"note " .navigationTitle("Fake one") " trailer"#)
            Text(##"note "# .navigationTitle("Fake two") "# trailer"##)
            Text(##"""
                raw "# .navigationTitle("Fake three") "# content
                """##)
        }
        .navigationTitle("Parent")
    }
}
