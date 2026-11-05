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
        // The main window, opened at launch: every journey and its status.
        Window("Journeys", id: "journeys") {
            JourneyListView()
                .environment(model)
                .font(.appBody)
                // Wide enough for the status strip plus all three row
                // buttons (Extract Telemetry, Render All, Open).
                .frame(minWidth: 960, minHeight: 400)
                .onAppear {
                    NSApplication.shared.activate()
                }
        }
        // One window per journey, keyed by its id, so opening a journey
        // that's already open brings its window to the front.
        WindowGroup("Journey", for: Int64.self) { $journeyID in
            JourneyWindow(journeyID: journeyID)
                .environment(model)
                .font(.appBody)
                .frame(minWidth: 700, minHeight: 560)
        }
    }
}
