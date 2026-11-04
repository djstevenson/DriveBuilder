import DriveBuilder
import SwiftUI

/// How one status icon is drawn.
private enum IconState {
    /// Rendered, extracted, or on disk: filled and tinted.
    case done
    /// Not there yet: outlined and dimmed.
    case missing
    /// Needs attention, e.g. a source file the render needs is missing.
    case problem
    /// Not applicable, e.g. a side camera the journey doesn't use.
    case unused
    /// Rendering right now: a progress ring replaces the icon.
    case rendering(RenderProgress)
}

/// The journeys list's pipeline-order row of status icons: source cameras
/// and telemetry, then each clip, then the final videos, then counts of
/// authored items. Each icon's tooltip and accessibility label carry the
/// detail the journey window shows as text.
struct JourneyStatusStrip: View {
    let journey: JourneySummary
    let status: JourneyStatus
    /// The render in flight, if it's for this journey.
    let activeRender: ActiveRender?

    var body: some View {
        HStack(spacing: 14) {
            group {
                ForEach(JourneyStatus.Camera.allCases, id: \.self) { camera in
                    cameraIcon(camera)
                }
                StatusIcon(
                    systemImage: "location", state: journey.sampleCount > 0 ? .done : .missing,
                    help: journey.sampleCount > 0
                        ? "Telemetry: \(journey.sampleCount.formatted()) samples"
                        : "Telemetry: not extracted")
                if status.segmentCount > 1 {
                    StatusIcon(
                        systemImage: "scissors", state: .done,
                        count: "\(status.segmentCount)",
                        help: "\(status.segmentCount) segments")
                }
            }
            Divider().frame(height: 16)
            group {
                outputIcon(.intro, systemImage: "signpost.right")
                outputIcon(.routeMap, systemImage: "map")
                outputIcon(.dials, systemImage: "speedometer")
                annotationsIcon
                outputIcon(.outro, systemImage: "flag.checkered")
            }
            Divider().frame(height: 16)
            group {
                outputIcon(.final, systemImage: "film")
                outputIcon(.fastFinal, systemImage: "hare")
            }
            Divider().frame(height: 16)
            group {
                StatusIcon(
                    systemImage: "tag",
                    state: status.routeMapLabelCount > 0 ? .done : .unused,
                    count: "\(status.routeMapLabelCount)",
                    help: "\(status.routeMapLabelCount) route map labels")
                StatusIcon(
                    systemImage: "camera.viewfinder",
                    state: status.cameraOverrideCount > 0 ? .done : .unused,
                    count: "\(status.cameraOverrideCount)",
                    help: "\(status.cameraOverrideCount) camera overrides")
            }
        }
        .font(.appCallout)
    }

    private func group(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 6, content: content)
    }

    private func cameraIcon(_ camera: JourneyStatus.Camera) -> some View {
        let symbol =
            switch camera {
            case .front: "arrow.up.circle"
            case .rear: "arrow.down.circle"
            case .left: "arrow.left.circle"
            case .right: "arrow.right.circle"
            }
        let presence = status.cameras[camera] ?? .unused
        let (state, detail): (IconState, String) =
            switch presence {
            case .present: (.done, "on disk")
            case .missing: (.problem, "source file missing")
            case .unused: (.unused, "not used")
            }
        return StatusIcon(systemImage: symbol, state: state, help: "\(camera.name): \(detail)")
    }

    /// An icon for one of `RenderComponent.standardComponents`.
    @ViewBuilder
    private func outputIcon(_ kind: RenderComponent.Kind, systemImage: String) -> some View {
        if let component = RenderComponent.standardComponents.first(where: { $0.kind == kind }) {
            let file = status.outputs[component.relativePath]
            let state: IconState =
                if let activeRender, activeRender.componentID == component.id {
                    .rendering(activeRender.progress)
                } else {
                    file == nil ? .missing : .done
                }
            StatusIcon(
                systemImage: systemImage, state: state,
                help: "\(component.name): \(file?.summary ?? "not rendered")")
        }
    }

    /// Whether the render in flight is one annotation banner or all of
    /// them: anything that isn't a standard output or the whole project.
    private var isRenderingAnnotations: Bool {
        guard let id = activeRender?.componentID else { return false }
        return id != RenderComponent.project.id
            && !RenderComponent.standardComponents.contains { $0.id == id }
    }

    private var annotationsIcon: some View {
        let total = status.annotationCount
        let rendered = status.renderedAnnotationCount
        let state: IconState =
            if let activeRender, isRenderingAnnotations {
                .rendering(activeRender.progress)
            } else if total == 0 {
                .unused
            } else {
                rendered == total ? .done : .missing
            }
        return StatusIcon(
            systemImage: "text.bubble", state: state,
            count: total == 0 ? "0" : "\(rendered)/\(total)",
            help: total == 0
                ? "No annotations" : "Annotations: \(rendered) of \(total) rendered")
    }
}

/// One status icon, with an optional count after it.
private struct StatusIcon: View {
    /// `.increased` on a selected row, whose accent-coloured highlight
    /// would swallow the tint.
    @Environment(\.backgroundProminence) private var backgroundProminence

    let systemImage: String
    let state: IconState
    var count: String?
    let help: String

    var body: some View {
        HStack(spacing: 2) {
            icon
                .frame(width: 20, height: 20)
            if let count {
                Text(count)
                    .font(.appCaption.monospacedDigit())
            }
        }
        .foregroundStyle(style)
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .rendering(.preparing):
            ProgressView()
                .controlSize(.small)
        case .rendering(.fraction(let fraction)):
            ProgressView(value: fraction)
                .progressViewStyle(.circular)
                .controlSize(.small)
        case .done:
            Image(systemName: systemImage)
                .symbolVariant(.fill)
        case .problem:
            Image(systemName: systemImage)
                .symbolVariant(.fill)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                        .offset(x: 4, y: -4)
                }
        case .missing, .unused:
            Image(systemName: systemImage)
        }
    }

    private var style: AnyShapeStyle {
        switch state {
        case .done:
            backgroundProminence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint)
        case .problem: AnyShapeStyle(.orange)
        case .missing: AnyShapeStyle(.secondary)
        case .unused: AnyShapeStyle(.quaternary)
        case .rendering: AnyShapeStyle(.primary)
        }
    }
}
