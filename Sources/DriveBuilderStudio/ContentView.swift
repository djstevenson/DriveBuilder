import DriveBuilder
import SwiftUI

struct ContentView: View {
    @Environment(StudioModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(model.journeys, selection: $model.selectedJourneyID) { journey in
                JourneyRow(journey: journey)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 280)
            .overlay {
                if let loadError = model.loadError {
                    ContentUnavailableView(
                        "Could not read journeys",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError))
                }
            }
        } detail: {
            if let journey = model.selectedJourney {
                JourneyDetailView(journey: journey)
            } else {
                ContentUnavailableView(
                    "Select a journey",
                    systemImage: "car",
                    description: Text("Pick a journey from the sidebar to see its video components."))
            }
        }
        .navigationTitle("DriveBuilder Studio")
        .toolbar {
            ToolbarItem {
                Toggle("Quick preview", isOn: $model.quickPreview)
                    .help(
                        "Render only the first 300 frames of a clip (and a 30-second "
                            + "drive segment for the final video), for a quick check.")
            }
            ToolbarItem {
                Button("Reload", systemImage: "arrow.clockwise") {
                    Task { await model.reload() }
                }
                .help("Re-read the journeys database and the output files on disk.")
            }
        }
        .task { await model.reload() }
        .alert(
            "Render failed",
            isPresented: Binding(
                get: { model.renderError != nil },
                set: { if !$0 { model.renderError = nil } }),
            presenting: model.renderError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text("\(failure.componentName): \(failure.message)")
        }
    }
}

struct JourneyRow: View {
    let journey: JourneySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(journey.title)
                .font(.appHeadline)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(journey.roadName)
                    .font(.appCaption.bold())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                if let start = journey.start {
                    Text(start, format: .dateTime.day().month().year())
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
