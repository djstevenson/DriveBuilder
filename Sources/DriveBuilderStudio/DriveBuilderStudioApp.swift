import AppKit
import SwiftUI

@main
struct DriveBuilderStudioApp: App {
    @State private var model: StudioModel
    @State private var youtubeAccount: YouTubeAccountModel
    @State private var youtube: YouTubeModel

    init() {
        let model = StudioModel()
        let account = YouTubeAccountModel()
        _model = State(initialValue: model)
        _youtubeAccount = State(initialValue: account)
        _youtube = State(
            initialValue: YouTubeModel(account: account, databasePath: model.databasePath))

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
                .environment(youtubeAccount)
                .environment(youtube)
                .font(.appBody)
                // Wide enough for the status strip plus all three row
                // buttons (Extract Telemetry, Render All, Open).
                .frame(minWidth: 960, minHeight: 400)
                .onAppear {
                    NSApplication.shared.activate()
                }
                .task {
                    await youtubeAccount.task()
                    await youtube.task()
                }
        }
        // One window per journey, keyed by its id, so opening a journey
        // that's already open brings its window to the front.
        WindowGroup("Journey", for: Int64.self) { $journeyID in
            JourneyWindow(journeyID: journeyID)
                .environment(model)
                .environment(youtubeAccount)
                .environment(youtube)
                .font(.appBody)
                .frame(minWidth: 700, minHeight: 560)
        }
        // The settings window (⌘,): the YouTube account to upload to.
        Settings {
            YouTubeSettingsView()
                .environment(youtubeAccount)
                .font(.appBody)
        }
    }
}
