import SwiftUI
extension Text {
    func sheet<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: () -> Content) -> Content { content() }
}
struct FixturePage: View {
    var body: some View {
        Text("Root").sheet(isPresented: .constant(true)) {
            Text("Visible").navigationTitle("Fake")
        }
    }
}
