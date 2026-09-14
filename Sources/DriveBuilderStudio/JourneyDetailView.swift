import AppKit
import DriveBuilder
import SwiftUI

struct JourneyDetailView: View {
    @Environment(StudioModel.self) private var model
    let journey: JourneySummary

    var body: some View {
        let nodes = RenderComponent.nodes(for: journey)
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding()
            Divider()
            List {
                ForEach(nodes) { node in
                    ComponentTreeRow(node: node, journey: journey)
                }
            }
            if let active = model.activeRender, active.journeyID == journey.id {
                Divider()
                progressBar(for: active, nodes: nodes)
                    .padding()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            journeySummaryHeader
            Spacer()
            if isRenderingProject {
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

    private var isRenderingProject: Bool {
        guard let active = model.activeRender else { return false }
        return active.journeyID == journey.id
            && active.componentID == RenderComponent.project.id
    }

    private var journeySummaryHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(journey.title)
                    .font(.title2.bold())
                Text(journey.roadName)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Text(summaryLine)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(journey.directory)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Reveal", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(filePath: journey.directory)])
                }
                .buttonStyle(.link)
                .font(.caption)
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

    private func progressBar(
        for active: ActiveRender, nodes: [ComponentNode]
    ) -> some View {
        let name = (nodes.flatMap(\.allComponents) + [RenderComponent.project])
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
