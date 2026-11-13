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
    case chapters
    case cameraOverrides

    var id: Self { self }

    var title: String {
        switch self {
        case .clips: "Clips"
        case .sources: "Sources"
        case .annotations: "Annotations"
        case .routeMapLabels: "Route Map Labels"
        case .chapters: "Chapters"
        case .cameraOverrides: "Secondary Cameras"
        }
    }

    var systemImage: String {
        switch self {
        case .clips: "film.stack"
        case .sources: "video"
        case .annotations: "text.bubble"
        case .routeMapLabels: "tag"
        case .chapters: "bookmark"
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
    @State private var chapters: [Chapter] = []
    @State private var cameraOverrides: [CameraOverride] = []
    /// The journey's track and timeline, for when items happen; nil while
    /// loading, or if the journey has no telemetry or its segments can't be
    /// joined (see `placementError`).
    @State private var placement: JourneyPlacement?
    @State private var placementError: String?
    /// Each output's state, keyed by `RenderComponent.id`; re-read whenever
    /// an output or anything it's rendered from changes.
    @State private var renderStates: [String: RenderState] = [:]

    @State private var editingJourney = false
    @State private var confirmingJourneyDelete = false
    /// What the sections have asked this window to present (see
    /// `JourneySheet` for why the window presents for them).
    @State private var sheet: JourneySheet?
    @State private var deletion: JourneyDeletion?
    @State private var failure: JourneyFailure?

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
                if model.activeRender?.journeyID == journey.id {
                    Divider()
                    HStack(spacing: 12) {
                        RenderProgressIndicator(style: .bar)
                        Button("Cancel") {
                            model.cancel()
                        }
                    }
                    .padding()
                }
            }
            .environment(\.renderStates, renderStates)
            .environment(
                \.journeyPresenter,
                JourneyPresenter(
                    showSheet: { sheet = $0 }, confirmDeletion: { deletion = $0 },
                    showFailure: { failure = $0 }))
        }
        .task(id: ItemsLoadKey(journeyID: journey.id, outputsVersion: model.outputsVersion)) {
            await loadSegments()
            await loadAnnotations()
            await loadRouteMapLabels()
            await loadChapters()
            await loadCameraOverrides()
            await loadRenderStates()
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
                "\u{201C}\(journey.title)\u{201D} and its telemetry, annotations, "
                    + "route map labels, chapters, and camera selections will be removed "
                    + "from the database. Source videos and rendered output on disk stay put.")
        }
        .sheet(item: $sheet) { sheet in
            sheetContent(sheet)
        }
        .alert(
            deletion?.title ?? "",
            isPresented: Binding(
                get: { deletion != nil },
                set: { if !$0 { deletion = nil } }),
            presenting: deletion
        ) { deletion in
            Button("Delete", role: .destructive) {
                Task { await perform(deletion) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { deletion in
            Text(deletion.message)
        }
        .alert(
            failure?.title ?? "",
            isPresented: Binding(
                get: { failure != nil },
                set: { if !$0 { failure = nil } }),
            presenting: failure
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(failure.message)
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
                reload: { await reload(.sources) })
        case .annotations:
            AnnotationsSection(journey: journey, annotations: annotations, placement: placement)
        case .routeMapLabels:
            RouteMapLabelsSection(labels: routeMapLabels, placement: placement)
        case .chapters:
            ChaptersSection(chapters: chapters, placement: placement)
        case .cameraOverrides:
            CameraOverridesSection(overrides: cameraOverrides, placement: placement)
        }
    }

    // MARK: - Presentations

    @ViewBuilder
    private func sheetContent(_ sheet: JourneySheet) -> some View {
        let path = model.databasePath
        switch sheet {
        case .addAnnotation:
            AnnotationForm(journey: journey, databasePath: path, placement: placement) {
                Task { await reload(.annotations) }
            }
        case .editAnnotation(let annotation):
            AnnotationForm(
                journey: journey, databasePath: path, annotation: annotation, placement: placement
            ) {
                Task { await reload(.annotations) }
            }
        case .addRouteMapLabel:
            RouteMapLabelForm(journey: journey, databasePath: path, placement: placement) {
                Task { await reload(.routeMapLabels) }
            }
        case .editRouteMapLabel(let label):
            RouteMapLabelForm(
                journey: journey, databasePath: path, label: label, placement: placement
            ) {
                Task { await reload(.routeMapLabels) }
            }
        case .addChapter:
            ChapterForm(journey: journey, databasePath: path, placement: placement) {
                Task { await reload(.chapters) }
            }
        case .editChapter(let chapter):
            ChapterForm(journey: journey, databasePath: path, chapter: chapter, placement: placement) {
                Task { await reload(.chapters) }
            }
        case .addCameraOverride:
            CameraOverrideForm(
                journey: journey, databasePath: path, otherOverrides: cameraOverrides,
                placement: placement
            ) {
                Task { await reload(.cameraOverrides) }
            }
        case .editCameraOverride(let cameraOverride):
            CameraOverrideForm(
                journey: journey, databasePath: path, cameraOverride: cameraOverride,
                otherOverrides: cameraOverrides, placement: placement
            ) {
                Task { await reload(.cameraOverrides) }
            }
        case .editSegment(let edit):
            SegmentForm(
                databasePath: path, segment: edit.segment, field: edit.field,
                isLast: edit.segment.id == segments.last?.id
            ) {
                Task { await reload(.sources) }
            }
        case .movie(let url, let title):
            MoviePlayerView(url: url, title: title)
        }
    }

    private func perform(_ deletion: JourneyDeletion) async {
        let library = JourneyLibrary(databasePath: model.databasePath)
        do {
            switch deletion {
            case .annotation(let annotation):
                try await library.deleteAnnotation(id: annotation.id)
                await reload(.annotations)
            case .routeMapLabel(let label):
                try await library.deleteRouteMapLabel(id: label.id)
                await reload(.routeMapLabels)
            case .chapter(let chapter):
                try await library.deleteChapter(id: chapter.id)
                await reload(.chapters)
            case .cameraOverride(let cameraOverride):
                try await library.deleteCameraOverride(id: cameraOverride.id)
                await reload(.cameraOverrides)
            case .segment(let segment):
                try await library.deleteSegment(segment)
                await reload(.sources)
            }
        } catch {
            failure = JourneyFailure(title: "Could not delete", message: String(describing: error))
        }
    }

    /// Re-reads one section's items after a change, then the output states
    /// that depend on them.
    private func reload(_ section: JourneySection) async {
        switch section {
        case .clips: break
        case .sources: await loadSegments()
        case .annotations: await loadAnnotations()
        case .routeMapLabels: await loadRouteMapLabels()
        case .chapters: await loadChapters()
        case .cameraOverrides: await loadCameraOverrides()
        }
        await loadRenderStates()
    }

    /// The sidebar row's badge: for the sections with movies, how many are
    /// up to date out of how many (red while any are missing, orange while
    /// any are out of date); otherwise how many items the section holds, a
    /// warning when the segments can't be joined, or nothing.
    private func badge(for section: JourneySection) -> Text? {
        func count(_ n: Int) -> Text? { n > 0 ? Text("\(n)") : nil }
        switch section {
        case .clips:
            return renderedBadge(RenderComponent.standardComponents)
        case .sources:
            if placementError != nil { return Text("\u{26A0}\u{FE0E}") }
            return segments.count > 1 ? Text("\(segments.count)") : nil
        case .annotations:
            return renderedBadge(annotations.map(RenderComponent.component(for:)))
        case .routeMapLabels:
            return count(routeMapLabels.count)
        case .chapters:
            return count(chapters.count)
        case .cameraOverrides:
            return count(cameraOverrides.count)
        }
    }

    /// "up-to-date/total" for these components' movies: red if any is
    /// missing, else orange if any is out of date; nil when there are none
    /// or the states haven't loaded.
    private func renderedBadge(_ components: [RenderComponent]) -> Text? {
        guard !components.isEmpty, !renderStates.isEmpty else { return nil }
        let states = components.map { renderStates[$0.id] ?? .missing }
        let text = Text("\(states.count { $0 == .upToDate })/\(components.count)")
        if states.contains(.missing) {
            return text.foregroundColor(.red)
        }
        if states.contains(where: { $0 != .upToDate }) {
            return text.foregroundColor(.orange)
        }
        return text
    }

    private func extractTelemetry() async {
        do {
            // Reloads the journey's sample count, span, and distance, which
            // hides this button and re-places the journey's items.
            try await model.extractTelemetry(journeyID: journey.id)
        } catch {
            failure = JourneyFailure(
                title: "Could not extract telemetry", message: String(describing: error))
        }
    }

    private func deleteJourney() async {
        do {
            try await JourneyLibrary(databasePath: model.databasePath)
                .deleteJourney(id: journey.id)
            await model.reload()
            dismiss()
        } catch {
            failure = JourneyFailure(title: "Could not delete", message: String(describing: error))
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

    private func loadChapters() async {
        chapters =
            (try? await JourneyLibrary(databasePath: model.databasePath)
                .chapters(journeyID: journey.id)) ?? []
    }

    private func loadRenderStates() async {
        renderStates =
            (try? await JourneyLibrary(databasePath: model.databasePath)
                .renderStates(journey: journey)) ?? [:]
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
}
