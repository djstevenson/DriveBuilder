import DriveBuilder
import SwiftUI

/// How one cell of the status grid stands.
private enum CellState {
    /// Rendered, extracted, or on disk.
    case done
    /// Not rendered yet.
    case notRendered
    /// Rendered, but out of date.
    case stale
    /// Needs attention, e.g. a source file the render needs is missing.
    case problem
    /// Not applicable, e.g. a side camera the journey doesn't use.
    case unused
    /// Rendering right now: a progress ring replaces the indicator,
    /// reading either the whole render's progress or the current step's.
    case rendering(RenderProgressIndicator.Source)
}

/// One row of a column: a named item with its state and a word or two of
/// detail.
private struct StatusItem: Identifiable {
    let name: String
    let detail: String
    let state: CellState

    var id: String { name }
}

extension JourneyStatus.Readiness {
    var title: String {
        switch self {
        case .complete: "Up to date"
        case .renderNeeded: "Render needed"
        case .missingData: "Missing data"
        }
    }

    var color: Color {
        switch self {
        case .complete: .green
        case .renderNeeded: .orange
        case .missingData: .red
        }
    }
}

/// A journey's expanded details in the journeys list: a column per stage
/// of the pipeline (sources, clips, final videos, authored items), each a
/// grid of named items with a coloured state indicator and a short detail,
/// so nothing needs a tooltip to be understood.
struct JourneyStatusGrid: View {
    @Environment(StudioModel.self) private var model
    let journey: JourneySummary
    let status: JourneyStatus
    /// The render in flight, if it's for this journey.
    let activeRender: ActiveRender?

    var body: some View {
        // Fixed column widths, so the columns line up from one journey to
        // the next like a table's.
        HStack(alignment: .top, spacing: 24) {
            column("Sources", sourceItems, width: 260)
            column("Clips", clipItems, width: 370)
            column("Final videos", outputItems, width: 370)
            column("Authored", authoredItems, width: 220)
            Spacer(minLength: 0)
        }
        .font(.appCaption)
    }

    private func column(_ title: String, _ items: [StatusItem], width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.appCaption.bold())
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 5) {
                ForEach(items) { item in
                    GridRow {
                        StateIndicator(state: item.state)
                        Text(item.name)
                        Text(item.detail)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(item.name): \(item.detail)")
                }
            }
        }
        .frame(width: width, alignment: .leading)
    }

    // MARK: Sources

    private var sourceItems: [StatusItem] {
        var items = JourneyStatus.Camera.allCases.map { camera -> StatusItem in
            let (state, detail): (CellState, String) =
                switch status.cameras[camera] ?? .unused {
                case .present: (.done, "On disk")
                case .missing: (.problem, "File missing")
                case .unused: (.unused, "Not used")
                }
            return StatusItem(name: camera.name, detail: detail, state: state)
        }
        items.append(
            StatusItem(
                name: "Telemetry",
                detail: status.hasTelemetry
                    ? "\(journey.sampleCount.formatted()) samples" : "Not extracted",
                state: status.hasTelemetry ? .done : .problem))
        items.append(
            StatusItem(
                name: "Segments",
                detail: status.segmentCount == 0 ? "None" : "\(status.segmentCount)",
                state: status.segmentCount == 0 ? .problem : .done))
        return items
    }

    // MARK: Clips and final videos

    private var clipItems: [StatusItem] {
        [
            outputItem(.intro),
            outputItem(.routeMap),
            outputItem(.dials),
            annotationsItem,
            outputItem(.outro),
        ].compactMap { $0 }
    }

    private var outputItems: [StatusItem] {
        [outputItem(.final), outputItem(.fastFinal), youtubeItem].compactMap { $0 }
    }

    /// The row for one of `RenderComponent.standardComponents`.
    private func outputItem(_ kind: RenderComponent.Kind) -> StatusItem? {
        guard let component = RenderComponent.standardComponents.first(where: { $0.kind == kind })
        else { return nil }
        let file = status.outputs[component.relativePath]
        let renderState = status.renderStates[component.relativePath] ?? .missing
        let state: CellState =
            if let source = model.progressSource(journeyID: journey.id, componentID: component.id) {
                .rendering(source)
            } else {
                switch renderState {
                case .missing: .notRendered
                case .upToDate: .done
                case .changed, .preview: .stale
                }
            }
        let detail = renderState.staleReason ?? file?.summary ?? "Not rendered"
        return StatusItem(name: component.name, detail: detail, state: state)
    }

    /// Whether the render in flight is one annotation banner or all of
    /// them: anything that isn't a standard output or the whole project.
    private var isRenderingAnnotations: Bool {
        guard let id = activeRender?.componentID else { return false }
        return id != RenderComponent.project.id
            && !RenderComponent.standardComponents.contains { $0.id == id }
    }

    private var annotationsItem: StatusItem {
        let total = status.annotationCount
        let states = status.annotationStates
        let upToDate = states.count { $0 == .upToDate }
        let missing = states.count { $0 == .missing }
        let stale = total - upToDate - missing
        let state: CellState =
            if isRenderingAnnotations {
                .rendering(.overall)
            } else if let source = model.progressSource(
                journeyID: journey.id, componentID: RenderComponent.allAnnotations.id)
            {
                .rendering(source)
            } else if total == 0 {
                .unused
            } else if missing > 0 {
                .notRendered
            } else {
                stale > 0 ? .stale : .done
            }
        var detail: String
        if total == 0 {
            detail = "None"
        } else {
            detail = "\(upToDate) of \(total) up to date"
            if missing > 0 { detail += ", \(missing) not rendered" }
            if stale > 0 { detail += ", \(stale) out of date" }
        }
        return StatusItem(name: "Annotations", detail: detail, state: state)
    }

    /// Which of the two final videos are on YouTube.
    private var youtubeItem: StatusItem {
        let uploaded = YouTubeVideo.Variant.allCases.filter { status.uploadedVariants.contains($0) }
        let names = uploaded.map(\.displayName)
        return StatusItem(
            name: "YouTube",
            detail: uploaded.isEmpty ? "Not uploaded" : names.joined(separator: ", "),
            state: uploaded.isEmpty ? .unused : .done)
    }

    // MARK: Authored items

    private var authoredItems: [StatusItem] {
        [
            countItem("Route map labels", status.routeMapLabelCount),
            countItem("Secondary cameras", status.cameraOverrideCount),
            countItem("Chapters", status.chapterCount),
        ]
    }

    private func countItem(_ name: String, _ count: Int) -> StatusItem {
        StatusItem(
            name: name, detail: count == 0 ? "None" : "\(count)",
            state: count == 0 ? .unused : .done)
    }
}

/// A cell's coloured dot: filled for a settled state, hollow for one
/// awaiting a render, and a progress ring while rendering.
private struct StateIndicator: View {
    let state: CellState

    var body: some View {
        Group {
            switch state {
            case .rendering(let source):
                RenderProgressIndicator(style: .ring, source: source)
            case .done:
                dot(.green)
            case .stale:
                dot(.orange)
            case .problem:
                dot(.red)
            case .notRendered:
                hollowDot(.orange)
            case .unused:
                // The same grey as the detail text beside it: quaternary all
                // but vanished against either appearance's background.
                hollowDot(.secondary)
            }
        }
        .frame(width: 16, height: 16)
    }

    private func dot(_ style: some ShapeStyle) -> some View {
        Circle().fill(style).frame(width: 10, height: 10)
    }

    private func hollowDot(_ style: some ShapeStyle) -> some View {
        Circle().strokeBorder(style, lineWidth: 2).frame(width: 10, height: 10)
    }
}
