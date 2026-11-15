import AppKit
import DriveBuilder
import SwiftUI

/// Keys the status reload to everything that changes it: the journeys
/// themselves, finished renders and reloads (via the outputs version), and
/// the window coming back to the front, which picks up edits made in a
/// journey window since.
private struct StatusLoadKey: Equatable {
    let journeyIDs: [Int64]
    let outputsVersion: Int
    let appearsActive: Bool
}

/// The main window: every journey with its status at a glance, and the
/// journey-wide actions. Each journey's details open in a window of their
/// own.
struct JourneyListView: View {
    @Environment(StudioModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.appearsActive) private var appearsActive

    @State private var selection: Int64?
    @State private var statuses: [Int64: JourneyStatus] = [:]
    /// The journeys whose detail grids are open.
    @State private var expandedJourneyIDs: Set<Int64> = []
    @State private var showingNewJourney = false
    @State private var newJourneySource = ""
    @State private var isDropTargeted = false
    @State private var extractError: String?

    var body: some View {
        List(model.journeys, selection: $selection) { journey in
            JourneyRow(
                journey: journey, status: statuses[journey.id],
                isExpanded: Binding(
                    get: { expandedJourneyIDs.contains(journey.id) },
                    set: { expanded in
                        if expanded {
                            expandedJourneyIDs.insert(journey.id)
                        } else {
                            expandedJourneyIDs.remove(journey.id)
                        }
                    }),
                onOpen: { openWindow(value: journey.id) },
                onExtractTelemetry: { Task { await extractTelemetry(journey) } })
        }
        .contextMenu(forSelectionType: Int64.self) { ids in
            if let id = ids.first, let journey = model.journey(id: id) {
                Button("Open") {
                    openWindow(value: id)
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(filePath: journey.directory)])
                }
            }
        } primaryAction: { ids in
            // Double-click or Return opens the journey's window.
            for id in ids {
                openWindow(value: id)
            }
        }
        .navigationTitle("Journeys")
        .toolbar {
            ToolbarItem {
                let allExpanded = expandedJourneyIDs.isSuperset(of: model.journeys.map(\.id))
                Button(
                    allExpanded ? "Collapse All" : "Expand All",
                    systemImage: allExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical"
                ) {
                    expandedJourneyIDs = allExpanded ? [] : Set(model.journeys.map(\.id))
                }
                .help(allExpanded ? "Hide every journey's details." : "Show every journey's details.")
            }
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
        // Dropping a folder of dashcam footage starts a new journey with
        // its source pre-filled.
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
        .task { await model.reload() }
        .task(
            id: StatusLoadKey(
                journeyIDs: model.journeys.map(\.id), outputsVersion: model.outputsVersion,
                appearsActive: appearsActive)
        ) {
            // Losing focus changes nothing worth re-reading.
            guard appearsActive else { return }
            statuses = await JourneyStatus.load(
                journeys: model.journeys, databasePath: model.databasePath,
                outputPaths: RenderComponent.standardComponents.map(\.relativePath))
        }
        .sheet(isPresented: $showingNewJourney) {
            JourneyForm(databasePath: model.databasePath, initialSource: newJourneySource) { journeyID in
                Task {
                    await model.reload()
                    openWindow(value: journeyID)
                }
            }
        }
        .alert(
            "Render failed",
            isPresented: Binding(
                get: { model.renderError?.origin == .journeyList },
                set: { if !$0 { model.renderError = nil } }),
            presenting: model.renderError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text("\(failure.componentName): \(failure.message)")
        }
        .alert(
            "Could not extract telemetry",
            isPresented: Binding(
                get: { extractError != nil },
                set: { if !$0 { extractError = nil } }),
            presenting: extractError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    private func extractTelemetry(_ journey: JourneySummary) async {
        do {
            try await model.extractTelemetry(journeyID: journey.id)
        } catch {
            extractError = String(describing: error)
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

/// One journey in the list: a header with its title, road, and vital
/// statistics, coloured by how ready it is, with the journey-wide actions;
/// and, when expanded, the grid of everything that goes into it.
struct JourneyRow: View {
    @Environment(StudioModel.self) private var model
    let journey: JourneySummary
    /// Nil until the statuses load, or if the journey's rows can't be read.
    let status: JourneyStatus?
    @Binding var isExpanded: Bool
    let onOpen: () -> Void
    let onExtractTelemetry: () -> Void

    /// Width of the coloured bar down the header's leading edge.
    private let barWidth: CGFloat = 5

    var body: some View {
        let activeRender = model.activeRender.flatMap {
            $0.journeyID == journey.id ? $0 : nil
        }

        VStack(alignment: .leading, spacing: 0) {
            header(activeRender: activeRender)
            if isExpanded, let status {
                JourneyStatusGrid(journey: journey, status: status, activeRender: activeRender)
                    .padding(.leading, barWidth + 12 + 20 + 12)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier("journey-row-\(journey.id)")
    }

    private func header(activeRender: ActiveRender?) -> some View {
        HStack(spacing: 12) {
            // The readiness colour, as a bar the selection highlight can't
            // swallow. Grey until the status has loaded.
            RoundedRectangle(cornerRadius: barWidth / 2)
                .fill(status?.readiness.color ?? Color.secondary.opacity(0.3))
                .frame(width: barWidth)
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.appCaption.bold())
                    .rotationEffect(isExpanded ? .degrees(90) : .zero)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(isExpanded ? "Hide the journey's details." : "Show the journey's details.")
            .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(journey.roadName)
                        .font(.appCaption.bold())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    Text(journey.title)
                        .font(.appHeadline)
                        .lineLimit(1)
                }
                Text(summaryLine)
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let readiness = status?.readiness {
                Text(readiness.title)
                    .font(.appCaption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(readiness.color, in: Capsule())
                    .accessibilityLabel("Status: \(readiness.title)")
            }
            actions(activeRender: activeRender)
                .modifier(SelectedRowButtons())
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func actions(activeRender: ActiveRender?) -> some View {
        if journey.sampleCount == 0 {
            if model.extractingJourneyID == journey.id {
                ProgressView()
                    .controlSize(.small)
            }
            Button("Extract Telemetry", systemImage: "location", action: onExtractTelemetry)
                .help(
                    "Read the GPS and accelerometer data from the NextBase/front clips in "
                        + "the journey's directory into the database. Takes a few minutes.")
                .disabled(model.extractingJourneyID != nil)
        }
        if activeRender != nil {
            RenderProgressIndicator(style: .ringWithPercentage)
            Button("Cancel") {
                model.cancel()
            }
        } else {
            Button("Render All") {
                model.render(.project, journey: journey, origin: .journeyList)
            }
            .help("Render every component at full length, then assemble the final videos.")
            .disabled(model.isRendering)
        }
        Button("Open", action: onOpen)
            .accessibilityIdentifier("journey-open-\(journey.id)")
    }

    private var summaryLine: String {
        var parts: [String] = []
        if let start = journey.start {
            parts.append(start.formatted(date: .abbreviated, time: .shortened))
        }
        if let start = journey.start, let end = journey.end {
            parts.append(
                Duration.seconds(end.timeIntervalSince(start))
                    .formatted(.time(pattern: .hourMinuteSecond)))
        }
        if journey.distanceMetres > 0 {
            parts.append(String(format: "%.1f miles", journey.distanceMetres / 1609.344))
        }
        if parts.isEmpty {
            parts.append("No telemetry")
        }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// Keeps a selected row's buttons legible: macOS draws bordered buttons
/// on the selection highlight as translucent accent over accent, so swap
/// in solid ones drawn like an unselected row's while the row is selected.
private struct SelectedRowButtons: ViewModifier {
    @Environment(\.backgroundProminence) private var backgroundProminence

    func body(content: Content) -> some View {
        if backgroundProminence == .increased {
            content.buttonStyle(SelectedRowButtonStyle())
        } else {
            content
        }
    }
}

private struct SelectedRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SelectedRowButton(configuration: configuration)
    }

    /// A view rather than inline in `makeBody`, to read `isEnabled`.
    private struct SelectedRowButton: View {
        @Environment(\.isEnabled) private var isEnabled
        let configuration: ButtonStyleConfiguration

        var body: some View {
            configuration.label
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                // The system's control colours, as on an unselected row's
                // buttons, rather than inheriting the selection's white text.
                .foregroundStyle(Color(nsColor: .controlTextColor))
                .background(
                    Color(nsColor: .controlColor).opacity(configuration.isPressed ? 0.75 : 1),
                    in: RoundedRectangle(cornerRadius: 6))
                .opacity(isEnabled ? 1 : 0.5)
        }
    }
}
