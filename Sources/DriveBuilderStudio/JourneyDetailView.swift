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

struct JourneyDetailView: View {
    @Environment(StudioModel.self) private var model
    let journey: JourneySummary

    @State private var annotations: [Annotation] = []
    @State private var addingAnnotation = false
    @State private var editingAnnotation: Annotation?
    @State private var annotationToDelete: Annotation?
    @State private var deleteError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding()
            Divider()
            List {
                ForEach(RenderComponent.standardComponents) { component in
                    ComponentRow(component: component, journey: journey)
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
                        offset: journey.frontOffset)
                    SourceVideoRow(
                        name: "Rear camera",
                        url: URL(filePath: journey.directory).appending(path: "video/rear.mov"),
                        offset: journey.rearOffset)
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
        }
        .sheet(isPresented: $addingAnnotation) {
            AnnotationForm(journey: journey, databasePath: model.databasePath) {
                Task { await loadAnnotations() }
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

    private func loadAnnotations() async {
        annotations =
            (try? await JourneyLibrary(databasePath: model.databasePath)
                .annotations(journeyID: journey.id)) ?? []
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
