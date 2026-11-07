import SwiftUI
func ~=<Output>(_ regex: Regex<Output>, _ input: String) -> Bool { true }
struct FixturePage: View {
    var body: some View {
        let count = { () -> Int in
            var n = 0
            for x in [1] where /abc.navigationTitle("Fake")/ ~= "abc" {
                n += x
            }
            return n
        }()
        Text("\(count)")
    }
}
