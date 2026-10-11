import SwiftUI

@main
struct VEOAv1anApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 640, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
    }
}
