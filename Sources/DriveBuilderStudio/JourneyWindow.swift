import DriveBuilder
import SwiftUI

/// The contents of one journey's window: its detail view, titled after the
/// journey, with this window's render options in the toolbar.
struct JourneyWindow: View {
    @Environment(StudioModel.self) private var model
    /// Nil only if the system restores a window without its value.
    let journeyID: Int64?

    @State private var renderSettings = RenderSettings()

    var body: some View {
        Group {
            if let journeyID, let journey = model.journey(id: journeyID) {
                JourneyDetailView(journey: journey)
                    .navigationTitle(journey.title)
                    .navigationSubtitle(journey.roadName)
            } else if model.hasLoaded {
                // A window restored for a journey deleted since.
                ContentUnavailableView(
                    "Journey not found", systemImage: "car",
                    description: Text("This journey is no longer in the database."))
            } else {
                ProgressView()
            }
        }
        .environment(\.renderSettings, renderSettings)
        .toolbar {
            ToolbarItem {
                Picker("Fast speed", selection: $renderSettings.fastDriveSpeed) {
                    ForEach([2.0, 3, 4, 5, 6, 8, 10], id: \.self) { speed in
                        Text("\(Int(speed))\u{00D7}").tag(speed)
                    }
                }
                .help("How much faster than real time the fast final video's drive plays.")
            }
            ToolbarItem {
                Toggle("Quick preview", isOn: $renderSettings.quickPreview)
                    .help(
                        "Render only the first 300 frames of a clip (and a 30-second "
                            + "drive segment for the final video), for a quick check.")
            }
        }
        // A journey window restored at launch can appear before the
        // journeys window has read the database.
        .task {
            if !model.hasLoaded {
                await model.reload()
            }
        }
        .alert(
            "Render failed",
            isPresented: Binding(
                get: {
                    model.renderError?.origin == .journeyWindow
                        && model.renderError?.journeyID == journeyID
                },
                set: { if !$0 { model.renderError = nil } }),
            presenting: model.renderError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text("\(failure.componentName): \(failure.message)")
        }
    }
}
