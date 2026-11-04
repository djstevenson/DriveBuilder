import AppKit
import DriveBuilder
import SwiftUI

/// Keys the journey's lists reload to finished renders and the journeys
/// window's Reload button (via the outputs version).
private struct ItemsLoadKey: Equatable {
    let journeyID: Int64
    let outputsVersion: Int
}

/// Keys the journey's placement to everything it depends on: the track
/// (the journey), its segments, and the rendered intro and route map (via
/// the outputs version), which decide where final.mov's drive starts.
private struct PlacementLoadKey: Equatable {
    let journeyID: Int64
    let outputsVersion: Int
    let segments: [JourneySegment]
}

/// The sections of a journey window's sidebar, one shown at a time.
enum JourneySection: String, CaseIterable, Identifiable {
    case clips
    case sources
    case annotations
    case routeMapLabels
    case cameraOverrides

    var id: Self { self }

    var title: String {
        switch self {
        case .clips: "Clips"
        case .sources: "Sources"
        case .annotations: "Annotations"
        case .routeMapLabels: "Route Map Labels"
        case .cameraOverrides: "Secondary Cameras"
        }
    }

    var systemImage: String {
        switch self {
        case .clips: "film.stack"
        case .sources: "video"
        case .annotations: "text.bubble"
        case .routeMapLabels: "tag"
        case .cameraOverrides: "camera.viewfinder"
        }
    }
}

/// A journey window's contents: a sidebar of sections, with the journey's
/// header and journey-wide actions above whichever section is selected.
///
/// Loads everything the sections share (the item lists, for the sidebar's
/// counts, and the track placement they're all positioned on) and hands
/// each section its slice plus a way to re-read it.
struct JourneyDetailView: View {
    @Environment(StudioModel.self) private var model
    @Environment(\.renderSettings) private var renderSettings
    @Environment(\.dismiss) private var dismiss
    let journey: JourneySummary

    /// Per window, so each journey reopens on the section last shown.
    @SceneStorage("journeySection") private var section = JourneySection.clips

    @State private var segments: [JourneySegment] = []
    @State private var annotations: [Annotation] = []
    @State private var routeMapLabels: [RouteMapLabel] = []
    @State private var cameraOverrides: [CameraOverride] = []
    /// The journey's track and timeline, for when items happen; nil while
    /// loading, or if the journey has no telemetry or its segments can't be
    /// joined (see `placementError`).
    @State private var placement: JourneyPlacement?
    @State private var placementError: String?

    @State private var editingJourney = false
    @State private var confirmingJourneyDelete = false
    @State private var deleteError: String?
    @State private var extractError: String?

    var body: some View {
        NavigationSplitView {
            List(
                JourneySection.allCases,
                selection: Binding(get: { section }, set: { if let new = $0 { section = new } })
            ) { section in
                Label(section.title, systemImage: section.systemImage)
                    .badge(badge(for: section))
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding()
                Divider()
                sectionView
                if let active = model.activeRender, active.journeyID == journey.id {
                    Divider()
                    progressBar(for: active)
                        .padding()
                }
            }
        }
        .task(id: ItemsLoadKey(journeyID: journey.id, outputsVersion: model.outputsVersion)) {
            await loadSegments()
            await loadAnnotations()
            await loadRouteMapLabels()
            await loadCameraOverrides()
        }
        .task(
            id: PlacementLoadKey(
                journeyID: journey.id, outputsVersion: model.outputsVersion, segments: segments)
        ) {
            do {
                placement = try await JourneyLibrary(databasePath: model.databasePath)
                    .placement(journeyID: journey.id)
                placementError = nil
            } catch {
                placement = nil
                // A journey with no telemetry has nothing to place on; that
                // shows in the header, so isn't repeated here.
                placementError =
                    journey.sampleCount > 0 ? String(describing: error) : nil
            }
        }
        .sheet(isPresented: $editingJourney) {
            JourneyForm(databasePath: model.databasePath, journey: journey) { _ in
                Task { await model.reload() }
            }
        }
        .alert("Delete journey?", isPresented: $confirmingJourneyDelete) {
            Button("Delete", role: .destructive) {
                Task { await deleteJourney() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "\u{201C}\(journey.title)\u{201D} and its telemetry, annotations, and "
                    + "route map labels will be removed from the database. Source videos "
                    + "and rendered output on disk stay put.")
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
        .alert(
            "Could not delete",
            isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }),
            presenting: deleteError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder
    private var sectionView: some View {
        switch section {
        case .clips:
            ClipsSection(journey: journey)
        case .sources:
            SourcesSection(
                journey: journey, segments: segments, placementError: placementError,
                reload: loadSegments)
        case .annotations:
            AnnotationsSection(
                journey: journey, annotations: annotations, placement: placement,
                reload: loadAnnotations)
        case .routeMapLabels:
            RouteMapLabelsSection(
                journey: journey, labels: routeMapLabels, placement: placement,
                reload: loadRouteMapLabels)
        case .cameraOverrides:
            CameraOverridesSection(
                journey: journey, overrides: cameraOverrides, placement: placement,
                reload: loadCameraOverrides)
        }
    }

    /// The sidebar row's badge: how many items the section holds, a
    /// warning when the segments can't be joined, or nothing.
    private func badge(for section: JourneySection) -> Text? {
        func count(_ n: Int) -> Text? { n > 0 ? Text("\(n)") : nil }
        switch section {
        case .clips:
            return nil
        case .sources:
            if placementError != nil { return Text("\u{26A0}\u{FE0E}") }
            return segments.count > 1 ? Text("\(segments.count)") : nil
        case .annotations:
            return count(annotations.count)
        case .routeMapLabels:
            return count(routeMapLabels.count)
        case .cameraOverrides:
            return count(cameraOverrides.count)
        }
    }

    private func extractTelemetry() async {
        do {
            // Reloads the journey's sample count, span, and distance, which
            // hides this button and re-places the journey's items.
            try await model.extractTelemetry(journeyID: journey.id)
        } catch {
            extractError = String(describing: error)
        }
    }

    private func deleteJourney() async {
        do {
            try await JourneyLibrary(databasePath: model.databasePath)
                .deleteJourney(id: journey.id)
            await model.reload()
            dismiss()
        } catch {
            deleteError = String(describing: error)
        }
    }

    private func loadSegments() async {
        segments =
            (try? await JourneyLibrary(databasePath: model.databasePath)
                .segments(journeyID: journey.id)) ?? []
    }

    private func loadAnnotations() async {
        annotations =
            (try? await JourneyLibrary(databasePath: model.databasePath)
                .annotations(journeyID: journey.id)) ?? []
    }

    private func loadRouteMapLabels() async {
        routeMapLabels =
            (try? await JourneyLibrary(databasePath: model.databasePath)
                .routeMapLabels(journeyID: journey.id)) ?? []
    }

    private func loadCameraOverrides() async {
        cameraOverrides =
            (try? await JourneyLibrary(databasePath: model.databasePath)
                .cameraOverrides(journeyID: journey.id)) ?? []
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            journeySummaryHeader
            Spacer()
            if journey.sampleCount == 0 {
                if model.extractingJourneyID == journey.id {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 4)
                }
                Button("Extract Telemetry", systemImage: "location") {
                    Task { await extractTelemetry() }
                }
                .help(
                    "Read the GPS and accelerometer data from the NextBase/front clips in "
                        + "the journey's directory into the database. Takes a few minutes.")
                .disabled(model.extractingJourneyID != nil)
            }
            Button("Edit", systemImage: "pencil") {
                editingJourney = true
            }
            .help("Edit the journey's source directory, road, and title.")
            Button("Delete", systemImage: "trash", role: .destructive) {
                confirmingJourneyDelete = true
            }
            .help("Delete the journey from the database.")
            .disabled(model.isRendering)
            if isRendering(.project) {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 4)
            }
            Button("Render All") {
                model.render(
                    .project, journey: journey, settings: renderSettings, origin: .journeyWindow)
            }
            .disabled(model.isRendering)
        }
    }

    private func isRendering(_ component: RenderComponent) -> Bool {
        guard let active = model.activeRender else { return false }
        return active.journeyID == journey.id && active.componentID == component.id
    }

    private var journeySummaryHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(journey.title)
                    .font(.appTitle2.bold())
                Text(journey.roadName)
                    .font(.appHeadline)
                    .foregroundStyle(.secondary)
            }
            Text(summaryLine)
                .font(.appCallout)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(journey.directory)
                    .font(.appCaption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Reveal", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(filePath: journey.directory)])
                }
                .buttonStyle(.link)
                .font(.appCaption)
            }
        }
    }

    private var summaryLine: String {
        var parts: [String] = []
        if let start = journey.start {
            parts.append(start.formatted(date: .long, time: .shortened))
        }
        if let start = journey.start, let end = journey.end {
            let duration = Duration.seconds(end.timeIntervalSince(start))
            parts.append(duration.formatted(.time(pattern: .hourMinuteSecond)))
        }
        if journey.distanceMetres > 0 {
            parts.append(String(format: "%.1f miles", journey.distanceMetres / 1609.344))
        }
        parts.append("\(journey.sampleCount.formatted()) samples")
        return parts.joined(separator: " \u{00B7} ")
    }

    private func progressBar(for active: ActiveRender) -> some View {
        HStack(spacing: 12) {
            switch active.progress {
            case .preparing:
                ProgressView()
                    .controlSize(.small)
                Text("Preparing \(active.componentName)\u{2026}")
                    .foregroundStyle(.secondary)
            case .fraction(let fraction):
                ProgressView(value: fraction)
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            Button("Cancel") {
                model.cancel()
            }
        }
    }
}
