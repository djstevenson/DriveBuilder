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
    @State private var editingOffsetSource: StartOffsetSource?
    @State private var routeMapLabels: [RouteMapLabel] = []
    @State private var addingLabel = false
    @State private var editingLabel: RouteMapLabel?
    @State private var labelToDelete: RouteMapLabel?

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
                        ForEach(routeMapLabels, id: \.listRowID) { label in
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
                Section {
                    if annotations.isEmpty {
                        Text("No annotations yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(annotations) { annotation in
                            HStack {
                                ComponentRow(
                                    component: .component(for: annotation), journey: journey)
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
                Section("Source Video and Telemetry") {
                    SourceVideoRow(
                        name: "Front camera",
                        url: URL(filePath: journey.directory).appending(path: "video/front.mov"),
                        offset: journey.frontOffset
                    ) {
                        editingOffsetSource = .front
                    }
                    SourceVideoRow(
                        name: "Rear camera",
                        url: URL(filePath: journey.directory).appending(path: "video/rear.mov"),
                        offset: journey.rearOffset
                    ) {
                        editingOffsetSource = .rear
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Telemetry")
                            Text(
                                "\(telemetryLength ?? "No telemetry") \u{00B7} "
                                    + SourceVideoRow.offsetText(journey.telemetryOffset))
                                .font(.appCaption)
                                .foregroundStyle(
                                    telemetryLength != nil
                                        ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                        }
                        Spacer()
                        Button("Edit", systemImage: "pencil") {
                            editingOffsetSource = .telemetry
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            if let active = model.activeRender, active.journeyID == journey.id {
                Divider()
                progressBar(for: active)
                    .padding()
            }
        }
        .task(id: AnnotationsLoadKey(journeyID: journey.id, outputsVersion: model.outputsVersion)) {
            await loadAnnotations()
            await loadRouteMapLabels()
        }
        .sheet(isPresented: $addingLabel) {
            RouteMapLabelForm(journey: journey, databasePath: model.databasePath) {
                Task { await loadRouteMapLabels() }
            }
        }
        .sheet(item: $editingLabel) { label in
            RouteMapLabelForm(journey: journey, databasePath: model.databasePath, label: label) {
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
            AnnotationForm(journey: journey, databasePath: model.databasePath) {
                Task { await loadAnnotations() }
            }
        }
        .sheet(item: $editingOffsetSource) { source in
            OffsetForm(journey: journey, databasePath: model.databasePath, source: source) {
                Task { await model.reload() }
            }
        }
        .sheet(item: $editingAnnotation) { annotation in
            AnnotationForm(
                journey: journey, databasePath: model.databasePath, annotation: annotation
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
            "Could not delete annotation",
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

    /// The label row's caption: when the sign appears, which side it sits
    /// on, its gap from the track point when overridden, and the subtitle.
    private func labelDetail(_ label: RouteMapLabel) -> String {
        var parts = [SourceVideoRow.offsetText(label.offset), label.location.rawValue]
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
