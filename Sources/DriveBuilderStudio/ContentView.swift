import DriveBuilder
import SwiftUI

struct ContentView: View {
    @Environment(StudioModel.self) private var model

    @State private var showingNewJourney = false
    @State private var newJourneySource = ""
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(model.journeys, selection: $model.selectedJourneyID) { journey in
                JourneyRow(journey: journey)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 280)
            // In the sidebar column so these land in the sidebar section
            // of the window toolbar: they act on the journeys list, not
            // the selected journey.
            .toolbar {
                ToolbarItem {
                    Button("New journey", systemImage: "plus") {
                        newJourneySource = ""
                        showingNewJourney = true
                    }
                    .help("Add a journey to the database.")
                }
                ToolbarItem {
                    Button("Reload", systemImage: "arrow.clockwise") {
                        Task { await model.reload() }
                    }
                    .help("Re-read the journeys database and the output files on disk.")
                }
            }
            .overlay {
                if let loadError = model.loadError {
                    ContentUnavailableView(
                        "Could not read journeys",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError))
                }
            }
            // Dropping a folder of dashcam footage starts a new journey
            // with its source pre-filled.
            .dropDestination(for: URL.self) { urls, _ in
                guard let source = Self.droppedDirectoryPath(urls) else { return false }
                newJourneySource = source
                showingNewJourney = true
                return true
            } isTargeted: {
                isDropTargeted = $0
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(4)
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
        }
        .task { await model.reload() }
        .sheet(isPresented: $showingNewJourney) {
            JourneyForm(databasePath: model.databasePath, initialSource: newJourneySource) { journeyID in
                Task {
                    await model.reload()
                    model.selectedJourneyID = journeyID
                }
            }
        }
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

    /// The dropped item's path if it is a single directory on disk;
    /// nil rejects the drop (plain files, multiple items).
    private static func droppedDirectoryPath(_ urls: [URL]) -> String? {
        guard urls.count == 1, let url = urls.first else { return nil }
        let path = url.standardizedFileURL.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }
        // Directory URLs carry a trailing slash the database rows don't.
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
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
