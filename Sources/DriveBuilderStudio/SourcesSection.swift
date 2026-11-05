import DriveBuilder
import SwiftUI

/// The journey window's Sources section: each segment's camera files,
/// telemetry offset, and length, with reordering and adding segments.
struct SourcesSection: View {
    @Environment(StudioModel.self) private var model
    @Environment(\.journeyPresenter) private var presenter
    let journey: JourneySummary
    let segments: [JourneySegment]
    /// Why the segments can't be joined into one drive, if they can't.
    let placementError: String?
    /// Re-reads the segments after a change (which re-places the journey's
    /// items on the new drive).
    let reload: () async -> Void

    var body: some View {
        SectionPage(title: "Sources") {
            Button("Add Segment", systemImage: "plus") {
                Task { await changeSegments { _ = try await $0.addSegment(journeyID: journey.id) } }
            }
            .help(
                "Add a segment after the last one, for footage after a break or a cut-out "
                    + "detour")
        } content: {
            List {
                if let placementError {
                    Text(placementError)
                        .font(.appCallout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    Section {
                        segmentRows(segment, index: index)
                    } header: {
                        segmentHeader(segment, index: index)
                    }
                }
            }
        }
    }

    /// Runs a change to the journey's segments, then re-reads them.
    private func changeSegments(_ change: (JourneyLibrary) async throws -> Void) async {
        do {
            try await change(JourneyLibrary(databasePath: model.databasePath))
        } catch {
            presenter.showFailure(
                JourneyFailure(
                    title: "Could not change the segments", message: String(describing: error)))
        }
        await reload()
    }

    /// A segment's section header: its number and where it sits on the
    /// drive, with buttons to reorder and remove it.
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
                    presenter.confirmDeletion(.segment(segment))
                }
            }
        }
    }

    /// A segment's sources, telemetry, and length; each Edit opens the
    /// segment's form for just that row.
    @ViewBuilder
    private func segmentRows(_ segment: JourneySegment, index: Int) -> some View {
        let video = URL(filePath: journey.directory).appending(path: "video")
        let offsets = segment.startOffsets
        let edit = { (field: SegmentField) in
            presenter.showSheet(.editSegment(SegmentEdit(segment: segment, field: field)))
        }
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

    /// The span of the journey's telemetry samples, from the database's
    /// start/end timestamps, in the same format as the video lengths.
    private var telemetryLength: String? {
        guard let start = journey.start, let end = journey.end else { return nil }
        return Duration.seconds(end.timeIntervalSince(start))
            .formatted(.time(pattern: .hourMinuteSecond))
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
}
