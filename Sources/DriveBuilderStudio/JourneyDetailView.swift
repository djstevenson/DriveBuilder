import AppKit
import DriveBuilder
import SwiftUI

/// Keys the annotations reload to both the selected journey and the
/// toolbar's Reload button, so switching journeys or reloading always
/// re-reads the database rather than showing a stale list.
private struct AnnotationsLoadKey: Equatable {
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

extension RouteMapLabel {
    /// Namespaced row identity for the journey pane's List. Labels and
    /// annotations both use their SQLite row ids, which overlap (both
    /// count up from 1), and the List diffs rows by identity across the
    /// whole list — equal ids make it render one row's content in the
    /// other's place.
    fileprivate var listRowID: String { "route-map-label-\(id)" }
}

struct JourneyDetailView: View {
    @Environment(StudioModel.self) private var model
    let journey: JourneySummary

    @State private var annotations: [Annotation] = []
    @State private var addingAnnotation = false
    @State private var editingAnnotation: Annotation?
    @State private var annotationToDelete: Annotation?
    @State private var deleteError: String?
    @State private var segments: [JourneySegment] = []
    @State private var editingSegment: SegmentEdit?
    @State private var segmentToDelete: JourneySegment?
    @State private var segmentError: String?
    @State private var editingJourney = false
    @State private var confirmingJourneyDelete = false
    @State private var routeMapLabels: [RouteMapLabel] = []
    @State private var addingLabel = false
    @State private var editingLabel: RouteMapLabel?
    @State private var labelToDelete: RouteMapLabel?
    /// The journey's track and timeline, for when items happen; nil while
    /// loading, or if the journey has no telemetry or its segments can't be
    /// joined (see `placementError`).
    @State private var placement: JourneyPlacement?
    @State private var placementError: String?
    /// The journey whose telemetry is being extracted, if any; by id so the
    /// spinner stays with that journey if the selection changes meanwhile.
    @State private var extractingJourneyID: Int64?
    @State private var extractError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding()
            Divider()
            List {
                // In their own Section: unsectioned rows at the top of a
                // List can shift the following sections' header association
                // on macOS, putting each header above the wrong rows.
                Section {
                    ForEach(RenderComponent.standardComponents) { component in
                        ComponentRow(component: component, journey: journey)
                    }
                }
                Section {
                    if routeMapLabels.isEmpty {
                        Text("No route map labels yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sortedRouteMapLabels, id: \.listRowID) { label in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(label.title)
                                    Text(labelDetail(label))
                                        .font(.appCaption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Edit", systemImage: "pencil") {
                                    editingLabel = label
                                }
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    labelToDelete = label
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    HStack {
                        Text("Route Map Labels")
                        Spacer()
                        Button("Add", systemImage: "plus") {
                            addingLabel = true
                        }
                    }
                }
                CameraOverridesSection(journey: journey, placement: placement)
                Section {
                    if annotations.isEmpty {
                        Text("No annotations yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sortedAnnotations) { annotation in
                            HStack {
                                ComponentRow(
                                    component: .component(for: annotation), journey: journey,
                                    detail: annotationDetail(annotation))
                                Button("Edit", systemImage: "pencil") {
                                    editingAnnotation = annotation
                                }
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    annotationToDelete = annotation
                                }
                            }
                        }
                    }
                } header: {
                    annotationsHeader
                }
                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    Section {
                        segmentRows(segment, index: index)
                    } header: {
                        segmentHeader(segment, index: index)
                    }
                }
            }
            if let active = model.activeRender, active.journeyID == journey.id {
                Divider()
                progressBar(for: active)
                    .padding()
            }
        }
        .task(id: AnnotationsLoadKey(journeyID: journey.id, outputsVersion: model.outputsVersion)) {
            await loadSegments()
            await loadAnnotations()
            await loadRouteMapLabels()
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
        .sheet(isPresented: $addingLabel) {
            RouteMapLabelForm(
                journey: journey, databasePath: model.databasePath, placement: placement
            ) {
                Task { await loadRouteMapLabels() }
            }
        }
        .sheet(item: $editingLabel) { label in
            RouteMapLabelForm(
                journey: journey, databasePath: model.databasePath, label: label,
                placement: placement
            ) {
                Task { await loadRouteMapLabels() }
            }
        }
        .alert(
            "Delete route map label?",
            isPresented: Binding(
                get: { labelToDelete != nil },
                set: { if !$0 { labelToDelete = nil } }),
            presenting: labelToDelete
        ) { label in
            Button("Delete", role: .destructive) {
                Task { await delete(label) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { label in
            Text("\u{201C}\(label.title)\u{201D} will be removed from the database.")
        }
        .sheet(isPresented: $addingAnnotation) {
            AnnotationForm(
                journey: journey, databasePath: model.databasePath, placement: placement
            ) {
                Task { await loadAnnotations() }
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
        .sheet(item: $editingSegment) { edit in
            SegmentForm(
                databasePath: model.databasePath, segment: edit.segment, field: edit.field,
                isLast: edit.segment.id == segments.last?.id
            ) {
                Task { await loadSegments() }
            }
        }
        .alert(
            "Delete segment?",
            isPresented: Binding(
                get: { segmentToDelete != nil },
                set: { if !$0 { segmentToDelete = nil } }),
            presenting: segmentToDelete
        ) { segment in
            Button("Delete", role: .destructive) {
                Task { await changeSegments { try await $0.deleteSegment(segment) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { segment in
            Text(
                "Segment \(segment.position + 1) will be removed from the journey. Its "
                    + "source videos stay on disk.")
        }
        .sheet(item: $editingAnnotation) { annotation in
            AnnotationForm(
                journey: journey, databasePath: model.databasePath, annotation: annotation,
                placement: placement
            ) {
                Task { await loadAnnotations() }
            }
        }
        .alert(
            "Delete annotation?",
            isPresented: Binding(
                get: { annotationToDelete != nil },
                set: { if !$0 { annotationToDelete = nil } }),
            presenting: annotationToDelete
        ) { annotation in
            Button("Delete", role: .destructive) {
                Task { await delete(annotation) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { annotation in
            Text(
                "\u{201C}\(annotation.video)\u{201D} will be removed from the database. "
                    + "Its rendered movie, if any, stays on disk.")
        }
        .alert(
            "Could not change the segments",
            isPresented: Binding(
                get: { segmentError != nil },
                set: { if !$0 { segmentError = nil } }),
            presenting: segmentError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
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

    private func extractTelemetry() async {
        extractingJourneyID = journey.id
        defer { extractingJourneyID = nil }
        do {
            _ = try await JourneyLibrary(databasePath: model.databasePath)
                .extractTelemetry(journeyID: journey.id)
            // Re-reads the journey's sample count, span, and distance, which
            // hides this button and re-places the journey's items.
            await model.reload()
        } catch {
            extractError = String(describing: error)
        }
    }

    private func deleteJourney() async {
        do {
            try await JourneyLibrary(databasePath: model.databasePath)
                .deleteJourney(id: journey.id)
            // Reload moves the sidebar selection to the newest remaining
            // journey, since this one's id is gone.
            await model.reload()
        } catch {
            deleteError = String(describing: error)
        }
    }

    private func delete(_ annotation: Annotation) async {
        do {
            try await JourneyLibrary(databasePath: model.databasePath)
                .deleteAnnotation(id: annotation.id)
            await loadAnnotations()
        } catch {
            deleteError = String(describing: error)
        }
    }

    private func delete(_ label: RouteMapLabel) async {
        do {
            try await JourneyLibrary(databasePath: model.databasePath)
                .deleteRouteMapLabel(id: label.id)
            await loadRouteMapLabels()
        } catch {
            deleteError = String(describing: error)
        }
    }

    private func loadSegments() async {
        segments =
            (try? await JourneyLibrary(databasePath: model.databasePath)
                .segments(journeyID: journey.id)) ?? []
    }

    /// Runs a change to the journey's segments, then re-reads them (which
    /// re-places the journey's items on the new drive).
    private func changeSegments(_ change: (JourneyLibrary) async throws -> Void) async {
        do {
            try await change(JourneyLibrary(databasePath: model.databasePath))
        } catch {
            segmentError = String(describing: error)
        }
        await loadSegments()
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

    /// The annotations in the order they finish, once the track's loaded.
    private var sortedAnnotations: [Annotation] {
        placement?.sorted(annotations, by: \.endLocation) ?? annotations
    }

    /// The labels in the order the track reveals them, once it's loaded.
    private var sortedRouteMapLabels: [RouteMapLabel] {
        placement?.sorted(routeMapLabels, by: \.revealLocation) ?? routeMapLabels
    }

    /// The annotation row's extra caption: when the banner finishes (or
    /// where, until the track loads), or why it can't be placed.
    private func annotationDetail(_ annotation: Annotation) -> String {
        guard let placement else { return "Finishes at \(annotation.endLocation.text)" }
        return switch placement.place(annotation.endLocation) {
        case .success(let placed): "Finishes at \(placement.timeText(placed))"
        case .failure(let error): "Not placeable: \(error)"
        }
    }

    /// The label row's caption: when the sign appears (or where, until the
    /// track loads), which side it sits on, its gap from the track point
    /// when overridden, and the subtitle.
    private func labelDetail(_ label: RouteMapLabel) -> String {
        var parts = [
            placement?.caption(for: label.revealLocation) ?? label.revealLocation.text,
            label.location.rawValue,
        ]
        if let distance = label.distance {
            parts.append(
                "gap \(distance.formatted(.number.precision(.fractionLength(0...1))))")
        }
        if !label.subtitle.isEmpty {
            parts.append(label.subtitle)
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private var header: some View {
        HStack(alignment: .top) {
            journeySummaryHeader
            Spacer()
            if journey.sampleCount == 0 {
                if extractingJourneyID == journey.id {
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
                .disabled(extractingJourneyID != nil)
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
                model.render(.project, journey: journey)
            }
            .disabled(model.isRendering)
        }
    }

    private var annotationsHeader: some View {
        HStack {
            Text("Annotations")
            Spacer()
            if isRendering(.allAnnotations) {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 4)
            }
            Button("Add", systemImage: "plus") {
                addingAnnotation = true
            }
            Button("Render All") {
                model.render(.allAnnotations, journey: journey)
            }
            .disabled(model.isRendering || annotations.isEmpty)
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

    /// The span of the journey's telemetry samples, from the database's
    /// start/end timestamps, in the same format as the video lengths.
    private var telemetryLength: String? {
        guard let start = journey.start, let end = journey.end else { return nil }
        return Duration.seconds(end.timeIntervalSince(start))
            .formatted(.time(pattern: .hourMinuteSecond))
    }

    // MARK: - Segments

    /// A segment's section header: its number and where it sits on the
    /// drive, with buttons to reorder, remove, and (after the last) add.
    private func segmentHeader(_ segment: JourneySegment, index: Int) -> some View {
        HStack {
            Text(segments.count == 1 ? "Source Video and Telemetry" : "Segment \(index + 1)")
            Spacer()
            if segments.count > 1 {
                Button("Move Up", systemImage: "chevron.up") {
                    Task { await changeSegments { try await $0.moveSegment(segment, earlier: true) } }
                }
                .disabled(index == 0)
                Button("Move Down", systemImage: "chevron.down") {
                    Task {
                        await changeSegments { try await $0.moveSegment(segment, earlier: false) }
                    }
                }
                .disabled(index == segments.count - 1)
                Button("Delete", systemImage: "trash", role: .destructive) {
                    segmentToDelete = segment
                }
            }
            if index == segments.count - 1 {
                Button("Add Segment", systemImage: "plus") {
                    Task { await changeSegments { _ = try await $0.addSegment(journeyID: journey.id) } }
                }
                .help(
                    "Add a segment after this one, for footage after a break or a cut-out "
                        + "detour")
            }
        }
    }

    /// A segment's sources, telemetry, and length; each Edit opens the
    /// segment's form for just that row. After the last segment, why the segments can't be
    /// joined, if they can't.
    @ViewBuilder
    private func segmentRows(_ segment: JourneySegment, index: Int) -> some View {
        let video = URL(filePath: journey.directory).appending(path: "video")
        let offsets = segment.startOffsets
        let edit = { (field: SegmentField) in editingSegment = SegmentEdit(segment: segment, field: field) }
        SourceVideoRow(
            name: "Front camera", file: segment.frontFile,
            url: video.appending(path: segment.frontFile), offset: offsets.front,
            onEditOffset: { edit(.front) })
        SourceVideoRow(
            name: "Rear camera", file: segment.rearFile,
            url: video.appending(path: segment.rearFile), offset: offsets.rear,
            onEditOffset: { edit(.rear) })
        SourceVideoRow(
            name: "Left camera", file: segment.leftFile,
            url: video.appending(path: segment.leftFile), offset: offsets.left,
            onEditOffset: { edit(.left) })
        SourceVideoRow(
            name: "Right camera", file: segment.rightFile,
            url: video.appending(path: segment.rightFile), offset: offsets.right,
            onEditOffset: { edit(.right) })
        captionRow(
            "Telemetry",
            caption: "\(telemetryLength ?? "No telemetry") \u{00B7} "
                + SourceVideoRow.offsetText(offsets.telemetry),
            dimmed: telemetryLength == nil, onEdit: { edit(.telemetry) })
        captionRow(
            "Length", caption: lengthCaption(segment, index: index),
            onEdit: { edit(.length) })
        if index == segments.count - 1, let placementError {
            Text(placementError)
                .font(.appCallout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    private func captionRow(
        _ title: String, caption: String, dimmed: Bool = false, onEdit: @escaping () -> Void
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(caption)
                    .font(.appCaption)
                    .foregroundStyle(dimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            }
            Spacer()
            Button("Edit", systemImage: "pencil", action: onEdit)
        }
        .padding(.vertical, 4)
    }

    /// The length row's caption: how long the segment plays, and where it
    /// sits on the drive when there's more than one.
    private func lengthCaption(_ segment: JourneySegment, index: Int) -> String {
        func text(_ seconds: Double) -> String {
            Duration.seconds(seconds).formatted(.time(pattern: .hourMinuteSecond))
        }
        let length = segment.length.map(text) ?? "Shortest source"
        guard segments.count > 1 else { return length }
        let earlier = segments.prefix(index).map(\.length)
        guard !earlier.contains(nil) else { return length }
        let start = earlier.compactMap { $0 }.reduce(0, +)
        let span =
            segment.length.map { "drive \(text(start))\u{2013}\(text(start + $0))" }
            ?? "drive from \(text(start))"
        return "\(length) \u{00B7} \(span)"
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
        let name = (RenderComponent.standardComponents
            + annotations.map(RenderComponent.component(for:))
            + [RenderComponent.allAnnotations, RenderComponent.project])
            .first { $0.id == active.componentID }?.name ?? "component"
        return HStack(spacing: 12) {
            switch active.progress {
            case .preparing:
                ProgressView()
                    .controlSize(.small)
                Text("Preparing \(name)\u{2026}")
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
