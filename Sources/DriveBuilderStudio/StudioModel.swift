import DriveBuilder
import Foundation
import Observation

/// One render in flight: which journey and component, and how far along.
struct ActiveRender {
    let journeyID: Int64
    let componentID: String
    var progress: RenderProgress
}

struct RenderFailure {
    let componentName: String
    let message: String
}

/// The journeys list, the current selection, and the one-at-a-time render
/// queue for the Studio window. Renders run serially: parallelised export
/// has deadlocked on this machine before, and the frame renderers already
/// saturate the cores on their own.
@Observable
final class StudioModel {
    /// The canonical checked-in database rather than the bundled copy, so
    /// journeys added since the last build still appear.
    let databasePath = JourneyLibrary.sourceTreeDatabasePath

    private(set) var journeys: [JourneySummary] = []
    var selectedJourneyID: Int64?
    private(set) var loadError: String?

    /// Cap renders for a quick check: the first 300 frames of a clip, and
    /// a 30-second drive segment for the final video.
    var quickPreview = false

    private(set) var activeRender: ActiveRender?
    var renderError: RenderFailure?

    /// Bumped when a render finishes so file-status rows re-read the disk.
    private(set) var outputsVersion = 0

    private var renderTask: Task<Void, Never>?

    var isRendering: Bool { activeRender != nil }

    var selectedJourney: JourneySummary? {
        journeys.first { $0.id == selectedJourneyID }
    }

    func reload() {
        do {
            journeys = try JourneyLibrary(databasePath: databasePath).journeys()
            loadError = nil
            if selectedJourneyID == nil {
                selectedJourneyID = journeys.first?.id
            } else if !journeys.contains(where: { $0.id == selectedJourneyID }) {
                selectedJourneyID = journeys.first?.id
            }
        } catch {
            loadError = String(describing: error)
        }
        outputsVersion += 1
    }

    func render(_ component: RenderComponent, journey: JourneySummary) {
        guard renderTask == nil else { return }
        activeRender = ActiveRender(
            journeyID: journey.id, componentID: component.id, progress: .preparing)

        var renderer = JourneyRenderer(journeyID: journey.id, databasePath: databasePath)
        if quickPreview { renderer.frameLimit = 300 }
        let driveSegmentSeconds: Double? = quickPreview ? 30 : nil
        let kind = component.kind
        let name = component.name

        renderTask = Task {
            let progress: RenderProgressHandler = { update in
                Task { @MainActor in
                    self.activeRender?.progress = update
                }
            }
            do {
                switch kind {
                case .intro:
                    _ = try await renderer.renderIntro(progress: progress)
                case .outro:
                    _ = try await renderer.renderOutro(progress: progress)
                case .dials:
                    _ = try await renderer.renderDials(progress: progress)
                case .routeMap:
                    _ = try await renderer.renderRouteMap(progress: progress)
                case .annotation(let video):
                    _ = try await renderer.renderAnnotation(video: video, progress: progress)
                case .final:
                    _ = try await renderer.renderFinal(
                        driveSegmentSeconds: driveSegmentSeconds, progress: progress)
                }
            } catch is CancellationError {
                // Cancelled from the progress bar; nothing to report.
            } catch {
                renderError = RenderFailure(
                    componentName: name, message: String(describing: error))
            }
            activeRender = nil
            renderTask = nil
            outputsVersion += 1
        }
    }

    func cancel() {
        renderTask?.cancel()
    }
}
