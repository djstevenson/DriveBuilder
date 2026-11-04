import DriveBuilder
import Foundation
import Observation
import Synchronization
import SwiftUI

/// One render in flight: which journey and component. How far along it is
/// lives apart, in `StudioModel.renderProgress`, so the many views that
/// only ask what's rendering aren't rebuilt on every progress update.
struct ActiveRender: Equatable {
    let journeyID: Int64
    let componentID: String
    let componentName: String
}

/// Thins a renderer's per-frame progress reports down to ones worth
/// redrawing for: each change of phase, and every 0.2% of the way.
nonisolated private final class ProgressThrottle: Sendable {
    private let lastReported = Mutex<Double?>(nil)

    func shouldReport(_ update: RenderProgress) -> Bool {
        lastReported.withLock { last in
            switch update {
            case .preparing:
                last = nil
                return true
            case .fraction(let fraction):
                if let previous = last, fraction < 1, fraction - previous < 0.002 {
                    return false
                }
                last = fraction
                return true
            }
        }
    }
}

/// Where a render was started, so its failure is reported in that window.
enum RenderOrigin {
    case journeyList
    case journeyWindow
}

struct RenderFailure {
    let journeyID: Int64
    let origin: RenderOrigin
    let componentName: String
    let message: String
}

/// A journey window's render options. Each window has its own, so a quick
/// preview set in one never silently applies to a render started elsewhere
/// (the journeys list always renders with the defaults).
struct RenderSettings: Equatable {
    /// Cap renders for a quick check: the first 300 frames of a clip, and
    /// the first 30 seconds of drive for the dials and the final video.
    var quickPreview = false

    /// How many times faster than real time the fast final video's drive
    /// plays.
    var fastDriveSpeed = JourneyRenderer.defaultFastDriveSpeed
}

extension EnvironmentValues {
    /// The enclosing journey window's render options, for the component
    /// rows' Render buttons.
    @Entry var renderSettings = RenderSettings()
}

/// The journeys list and the one-at-a-time render queue, shared by the
/// journeys window and every journey window. Renders run serially: parallelised export
/// has deadlocked on this machine before, and the frame renderers already
/// saturate the cores on their own.
@Observable
final class StudioModel {
    /// The canonical checked-in database rather than the bundled copy, so
    /// journeys added since the last build still appear.
    let databasePath = JourneyLibrary.sourceTreeDatabasePath

    private(set) var journeys: [JourneySummary] = []
    private(set) var loadError: String?
    /// Whether `journeys` has been read at least once, so a journey window
    /// restored at launch can tell "not loaded yet" from "deleted".
    private(set) var hasLoaded = false

    /// The journey whose telemetry is being extracted, if any. One at a
    /// time: extraction reads every clip and saturates the drive.
    private(set) var extractingJourneyID: Int64?

    private(set) var activeRender: ActiveRender?
    /// How far along `activeRender` is. Read it only from the progress
    /// indicators themselves (see `RenderProgressIndicator`): it changes
    /// hundreds of times a render.
    private(set) var renderProgress = RenderProgress.preparing
    var renderError: RenderFailure?

    /// Bumped when a render finishes, on Reload, and when files change in a
    /// journey's output directory, so file-status rows re-read the disk.
    private(set) var outputsVersion = 0

    private var renderTask: Task<Void, Never>?

    @ObservationIgnored private var outputWatcher: OutputDirectoryWatcher?

    init() {
        outputWatcher = OutputDirectoryWatcher { [weak self] in
            self?.outputsChangedOnDisk()
        }
    }

    var isRendering: Bool { activeRender != nil }

    func journey(id: Int64) -> JourneySummary? {
        journeys.first { $0.id == id }
    }

    func reload() async {
        do {
            journeys = try await JourneyLibrary(databasePath: databasePath).journeys()
            loadError = nil
        } catch {
            loadError = String(describing: error)
        }
        hasLoaded = true
        outputsVersion += 1
        watchOutputDirectories()
    }

    /// Something outside the Studio (or a render) added, removed, or
    /// renamed an output file.
    private func outputsChangedOnDisk() {
        outputsVersion += 1
        // Drops the watch on a directory that was itself deleted.
        watchOutputDirectories()
    }

    private func watchOutputDirectories() {
        outputWatcher?.watch(
            Set(journeys.map {
                URL(filePath: $0.directory).appending(path: "output").path(percentEncoded: false)
            }))
    }

    /// Reads the journey's GPS and accelerometer data from its dashcam
    /// clips into the database, then reloads so its sample count, span,
    /// and distance update everywhere. Takes a few minutes.
    func extractTelemetry(journeyID: Int64) async throws {
        guard extractingJourneyID == nil else { return }
        extractingJourneyID = journeyID
        defer { extractingJourneyID = nil }
        _ = try await JourneyLibrary(databasePath: databasePath)
            .extractTelemetry(journeyID: journeyID)
        await reload()
    }

    func render(
        _ component: RenderComponent, journey: JourneySummary,
        settings: RenderSettings = RenderSettings(), origin: RenderOrigin
    ) {
        guard renderTask == nil else { return }
        activeRender = ActiveRender(
            journeyID: journey.id, componentID: component.id, componentName: component.name)
        renderProgress = .preparing

        var renderer = JourneyRenderer(journeyID: journey.id, databasePath: databasePath)
        let driveSegmentSeconds: Double? = settings.quickPreview ? 30 : nil
        if settings.quickPreview {
            renderer.frameLimit = 300
            renderer.dialsSecondsLimit = driveSegmentSeconds
        }
        let kind = component.kind
        let name = component.name
        let fastDriveSpeed = settings.fastDriveSpeed

        renderTask = Task {
            let throttle = ProgressThrottle()
            let progress: RenderProgressHandler = { update in
                guard throttle.shouldReport(update) else { return }
                Task { @MainActor in
                    self.renderProgress = update
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
                case .allAnnotations:
                    _ = try await renderer.renderAnnotations(progress: progress)
                case .final:
                    _ = try await renderer.renderFinal(
                        driveSegmentSeconds: driveSegmentSeconds, progress: progress)
                case .fastFinal:
                    _ = try await renderer.renderFastFinal(
                        driveSpeed: fastDriveSpeed, driveSegmentSeconds: driveSegmentSeconds,
                        progress: progress)
                case .project:
                    _ = try await renderer.renderProject(
                        driveSegmentSeconds: driveSegmentSeconds, progress: progress)
                }
            } catch is CancellationError {
                // Cancelled from the progress bar; nothing to report.
            } catch {
                renderError = RenderFailure(
                    journeyID: journey.id, origin: origin, componentName: name,
                    message: String(describing: error))
            }
            activeRender = nil
            renderTask = nil
            outputsVersion += 1
            // The render may have created the journey's output directory.
            watchOutputDirectories()
        }
    }

    func cancel() {
        renderTask?.cancel()
    }
}
