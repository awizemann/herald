import SwiftUI
import HeraldKit

@main
struct HeraldApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        Text("Herald \(HeraldKit.version)")
            .frame(minWidth: 400, minHeight: 300)
    }
}
