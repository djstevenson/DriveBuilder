import AppKit
import SwiftUI

@main
struct DriveBuilderStudioApp: App {
    @State private var model = StudioModel()

    init() {
        // Running as a bare SPM executable rather than an .app bundle:
        // promote the process to a regular app so it gets a Dock icon,
        // a menu bar, and key-window focus.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("DriveBuilder Studio") {
            ContentView()
                .environment(model)
                .font(.appBody)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear {
                    NSApplication.shared.activate()
                }
        }
    }
}
