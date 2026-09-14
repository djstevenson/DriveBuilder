import Foundation

/// How far through a render we are, for a front end to display.
package enum RenderProgress: Sendable {
    /// Setup with no measurable fraction yet: loading telemetry, rasterizing
    /// artwork, rendering map tiles.
    case preparing
    /// Frames written (or export completed), as a 0...1 fraction.
    case fraction(Double)
}

package typealias RenderProgressHandler = @Sendable (RenderProgress) -> Void

/// One journey's row for the Studio sidebar: the journeys table columns
/// plus cheap aggregates over its telemetry.
package struct JourneySummary: Identifiable, Sendable {
    package let id: Int64
    package let title: String
    package let roadType: String
    package let roadNumber: Int
    /// The journey's directory, where its source footage, annotations, and
    /// output live.
    package let directory: String
    package let sampleCount: Int
    package let start: Date?
    package let end: Date?
    package let distanceMetres: Double

    package var roadName: String { "\(roadType)\(roadNumber)" }
}

/// Read access to the journeys a front end can list.
package struct JourneyLibrary: Sendable {
    package var databasePath: String

    /// The canonical checked-in database. The Studio GUI reads this rather
    /// than the bundled copy, which is only recreated from it at build time
    /// and so wouldn't show journeys added since.
    package static var sourceTreeDatabasePath: String { TelemetryDatabase.sourceTreePath }

    package init(databasePath: String) {
        self.databasePath = databasePath
    }

    /// `@concurrent` for the same reason as the `JourneyRenderer` methods:
    /// keep the database read off the caller's (GUI main) actor.
    @concurrent
    package func journeys() async throws -> [JourneySummary] {
        try TelemetryStore(path: databasePath).allJourneys()
    }
}

/// Something needed by a render is missing or malformed (a journey column,
/// a main.json entry); the render never started.
package struct RenderSetupError: Error, CustomStringConvertible {
    package let message: String
    package var description: String { message }
}

/// Renders a journey's video components: the one recipe per component,
/// shared by the CLI subcommands and the Studio GUI. Each method returns
/// the URL of the movie it wrote.
package struct JourneyRenderer: Sendable {
    /// Frame size for the telemetry dials (speedo, compass, altitude, g-force).
    package static let defaultDialPixelSize = 345
    /// Frame size for the progress maps: the footprint of a 2x2 dial grid,
    /// two 345px dials plus a 18px gap.
    package static let defaultMapPixelSize = 708
    /// Directory containing maprender.py, map.xml, and the OSM data
    /// (see MapOptions).
    package static let defaultMapDirectory = "/Users/davids/src/perl/drive-builder"

    package var journeyID: Int64
    package var databasePath: String
    package var mapDirectory = Self.defaultMapDirectory
    /// Render only the first N frames, for a quick check.
    package var frameLimit: Int?

    package init(journeyID: Int64, databasePath: String) {
        self.journeyID = journeyID
        self.databasePath = databasePath
    }

    // MARK: - Components

    // The render methods are `@concurrent`: under ApproachableConcurrency a
    // plain nonisolated async function runs on the *caller's* actor, so the
    // Studio GUI (main-actor by default isolation) would do all the slow
    // setup — telemetry loads, map tile subprocesses — on the main thread
    // and beachball until the first progress callback.

    /// The road-number intro badge: `output/intro.mov`.
    @concurrent
    package func renderIntro(progress: RenderProgressHandler? = nil) async throws -> URL {
        progress?(.preparing)
        let road = try journeyRoad()
        let title = try journeyTitle()
        let outputDirectory = try makeOutputDirectory()

        // Other real roads to cycle through during the spin, so its
        // title animates in step with the spinning number; the real
        // target is excluded so the spin never coincidentally shows it
        // early.
        let targetRoadName = "\(road.type)\(road.number)"
        let spinEntries = try store.allCachedRoads()
            .filter { $0.roadName != targetRoadName }
            .map {
                IntroRenderer.SpinEntry(
                    roadText: $0.roadName, title: "\($0.startName) to \($0.endName)")
            }

        // Rendered nearly full-screen, so sized well above the 420px
        // dials: 80% of a 4K screen's width.
        let size = IntroRenderer.wideScreenSize
        let renderer = IntroRenderer(
            roadType: road.type, roadNumber: road.number, title: title,
            spinEntries: spinEntries, width: size.width, height: size.height)
        let url = outputDirectory.appending(path: "intro.mov")
        return try await write(url) {
            try await renderer.writeMovie(to: url, frameLimit: frameLimit, progress: progress)
        }
    }

    /// The road-number outro badge: `output/outro.mov`.
    @concurrent
    package func renderOutro(progress: RenderProgressHandler? = nil) async throws -> URL {
        progress?(.preparing)
        let road = try journeyRoad()
        let title = try journeyTitle()
        let outputDirectory = try makeOutputDirectory()

        // Rendered nearly full-screen, matching the intro's size so the
        // two clips line up when cross-faded.
        let size = IntroRenderer.wideScreenSize
        let renderer = OutroRenderer(
            roadType: road.type, roadNumber: road.number, title: title,
            width: size.width, height: size.height)
        let url = outputDirectory.appending(path: "outro.mov")
        return try await write(url) {
            try await renderer.writeMovie(to: url, frameLimit: frameLimit, progress: progress)
        }
    }

    /// The combined telemetry video: `output/telemetry/dials.mov`.
    @concurrent
    package func renderDials(progress: RenderProgressHandler? = nil) async throws -> URL {
        progress?(.preparing)
        let records = try records()
        let journeyDirectory = try journeyDirectory()
        var tileRenderer = MaprenderTileRenderer(directory: URL(filePath: mapDirectory))
        tileRenderer.scaleFactor =
            Double(Self.defaultMapPixelSize) / ProgressMapRenderer.designPixelSize

        let renderer = TelemetryVideoRenderer(
            records: records,
            dialPixelSize: Self.defaultDialPixelSize,
            mapPixelSize: Self.defaultMapPixelSize,
            tileRenderer: tileRenderer)
        let url = try Self.telemetryOutputURL(named: "dials", journeyDirectory: journeyDirectory)
        return try await write(url) {
            try await renderer.writeMovie(to: url, frameLimit: frameLimit, progress: progress)
        }
    }

    /// The route overview map: `output/telemetry/route_map.mov`.
    @concurrent
    package func renderRouteMap(
        routeConfigPath: String? = nil, progress: RenderProgressHandler? = nil
    ) async throws -> URL {
        progress?(.preparing)
        let journeyDirectory = try journeyDirectory()
        let config = try Self.routeMapConfig(
            explicitPath: routeConfigPath, journeyDirectory: journeyDirectory)

        var tileRenderer = MaprenderTileRenderer(directory: URL(filePath: mapDirectory))
        tileRenderer.scaleFactor =
            Double(config.width) / RouteMapRenderer.mapXMLDesignWidth

        var nationalTileRenderer = MaprenderTileRenderer(directory: URL(filePath: mapDirectory))
        nationalTileRenderer.stylesheet = "map-national.xml"
        nationalTileRenderer.scaleFactor =
            Double(config.width) / RouteMapRenderer.mapXMLDesignWidth

        let renderer = RouteMapRenderer(
            records: try records(),
            tileRenderer: tileRenderer,
            config: config)
        let url = try Self.telemetryOutputURL(
            named: "route_map", journeyDirectory: journeyDirectory)
        return try await write(url) {
            try await renderer.writeMovie(
                nationalTileRenderer: nationalTileRenderer,
                to: url, frameLimit: frameLimit, progress: progress)
        }
    }

    /// Every scrolling annotation banner from main.json, in order:
    /// `output/<video>.mov` each.
    @concurrent
    package func renderAnnotations(
        progress: RenderProgressHandler? = nil
    ) async throws -> [URL] {
        progress?(.preparing)
        let directory = try journeyDirectory()
        let annotations = try DriveBuilder.Annotations.annotations(in: directory)
        let outputDirectory = try makeOutputDirectory()

        var urls: [URL] = []
        for (index, annotation) in annotations.enumerated() {
            // Scale each banner's own fraction into its slice of the whole.
            var slice: RenderProgressHandler?
            if let progress {
                slice = { update in
                    if case .fraction(let f) = update {
                        progress(.fraction((Double(index) + f) / Double(annotations.count)))
                    }
                }
            }
            urls.append(
                try await render(annotation, to: outputDirectory, progress: slice))
        }
        return urls
    }

    /// One annotation banner, picked out of main.json by its output name.
    @concurrent
    package func renderAnnotation(
        video: String, progress: RenderProgressHandler? = nil
    ) async throws -> URL {
        progress?(.preparing)
        let directory = try journeyDirectory()
        let annotations = try DriveBuilder.Annotations.annotations(in: directory)
        guard let annotation = annotations.first(where: { $0.video == video }) else {
            throw RenderSetupError(
                message: "No annotation named \"\(video)\" in \(directory)/main.json.")
        }
        return try await render(annotation, to: try makeOutputDirectory(), progress: progress)
    }

    private func render(
        _ annotation: MainConfig.Annotation, to outputDirectory: URL,
        progress: RenderProgressHandler?
    ) async throws -> URL {
        let text = DriveBuilder.Annotations.normalizedText(annotation.text)
        guard !text.isEmpty else {
            throw RenderSetupError(
                message: "Annotation \"\(annotation.video)\" in main.json has no text.")
        }
        let renderer = AnnotationRenderer(text: text)
        let url = outputDirectory.appending(path: "\(annotation.video).mov")
        return try await write(url) {
            try await renderer.writeMovie(to: url, frameLimit: frameLimit, progress: progress)
        }
    }

    /// The assembled final video: `output/final.mov`. Requires intro.mov,
    /// telemetry/route_map.mov, telemetry/dials.mov, outro.mov, and every
    /// annotation banner to have been rendered already.
    ///
    /// `driveSegmentSeconds` caps the drive segment for a quick sync check,
    /// like the CLI's --length; the intro and outro still play in full.
    @concurrent
    package func renderFinal(
        driveSegmentSeconds: Double? = nil, progress: RenderProgressHandler? = nil
    ) async throws -> URL {
        progress?(.preparing)
        let journeyDirectory = try journeyDirectory()
        let outputDirectory = try makeOutputDirectory()

        var composer = FinalVideoComposer(
            introURL: outputDirectory.appending(path: "intro.mov"),
            routeMapURL: outputDirectory.appending(path: "telemetry/route_map.mov"),
            dialsURL: outputDirectory.appending(path: "telemetry/dials.mov"),
            frontFootageURL: URL(filePath: journeyDirectory).appending(path: "video/front.mov"),
            rearFootageURL: URL(filePath: journeyDirectory).appending(path: "video/rear.mov"),
            outroURL: outputDirectory.appending(path: "outro.mov"))
        let mainConfig = try MainConfig.load(journeyDirectory: journeyDirectory)
        composer.startOffsets = mainConfig.startOffsets
        composer.maxDriveSegmentSeconds = driveSegmentSeconds
        composer.annotationClips = try mainConfig.annotations.map { annotation in
            guard let offset = annotation.offset else {
                throw RenderSetupError(
                    message: "Annotation \"\(annotation.video)\" in main.json has no \"offset\".")
            }
            return FinalVideoComposer.AnnotationClip(
                url: outputDirectory.appending(path: "\(annotation.video).mov"),
                rawEndOffsetSeconds: offset)
        }
        if let progress {
            composer.progressHandler = { fraction in progress(.fraction(fraction)) }
        }
        let url = outputDirectory.appending(path: "final.mov")
        return try await write(url) {
            try await composer.writeMovie(to: url)
        }
    }

    /// The whole programme in order — intro, route map, dials, every
    /// annotation, outro — then the final assembly. Each component gets an
    /// equal slice of the progress fraction. Returns the final video's URL.
    @concurrent
    package func renderProject(
        driveSegmentSeconds: Double? = nil, progress: RenderProgressHandler? = nil
    ) async throws -> URL {
        progress?(.preparing)
        let steps: [(RenderProgressHandler?) async throws -> Void] = [
            { _ = try await self.renderIntro(progress: $0) },
            { _ = try await self.renderRouteMap(progress: $0) },
            { _ = try await self.renderDials(progress: $0) },
            { _ = try await self.renderAnnotations(progress: $0) },
            { _ = try await self.renderOutro(progress: $0) },
        ]
        let count = steps.count + 1
        for (phase, step) in steps.enumerated() {
            try await step(Self.slice(progress, phase: phase, of: count))
        }
        return try await renderFinal(
            driveSegmentSeconds: driveSegmentSeconds,
            progress: Self.slice(progress, phase: steps.count, of: count))
    }

    /// Maps one phase's progress into its 1/count slice of the whole; a
    /// phase's `.preparing` shows as the fraction reached so far rather
    /// than dropping the bar back to indeterminate.
    private static func slice(
        _ progress: RenderProgressHandler?, phase: Int, of count: Int
    ) -> RenderProgressHandler? {
        guard let progress else { return nil }
        return { update in
            switch update {
            case .preparing:
                progress(.fraction(Double(phase) / Double(count)))
            case .fraction(let fraction):
                progress(.fraction((Double(phase) + fraction) / Double(count)))
            }
        }
    }

    // MARK: - Shared paths

    /// Destination for a named clip under the journey's `output/telemetry`
    /// directory. Creates that directory if it doesn't exist yet, and
    /// removes any existing movie of the same name so the render always
    /// starts from a clean slate.
    static func telemetryOutputURL(named name: String, journeyDirectory: String) throws -> URL {
        let outputDirectory = URL(filePath: journeyDirectory).appending(path: "output")
        let directory = outputDirectory.appending(path: "telemetry")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.excludeFromBackup(outputDirectory)

        let url = directory.appending(path: "\(name).mov")
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: url)
        }
        return url
    }

    /// Resolves the route-map config like the Perl pipeline: an explicit
    /// path must exist, otherwise `route_map.json` beside the journey's
    /// source footage is used when present, otherwise the built-in defaults.
    static func routeMapConfig(
        explicitPath: String?, journeyDirectory: String?
    ) throws -> RouteMapConfig {
        if let explicitPath {
            return try RouteMapConfig.load(path: explicitPath)
        }
        if let journeyDirectory {
            let conventional = URL(filePath: journeyDirectory).appending(path: "route_map.json")
                .path(percentEncoded: false)
            if FileManager.default.fileExists(atPath: conventional) {
                return try RouteMapConfig.load(path: conventional)
            }
        }
        return RouteMapConfig()
    }

    // MARK: - Journey lookups

    private var store: TelemetryStore { TelemetryStore(path: databasePath) }

    private func records() throws -> [TelemetryRecord] {
        try store.records(journeyID: journeyID)
    }

    private func journeyDirectory() throws -> String {
        guard let directory = try store.journeyDirectory(journeyID: journeyID) else {
            throw RenderSetupError(message: "Journey \(journeyID) has no directory recorded.")
        }
        return directory
    }

    private func journeyTitle() throws -> String {
        guard let title = try store.journeyTitle(journeyID: journeyID) else {
            throw RenderSetupError(message: "Journey \(journeyID) has no title recorded.")
        }
        return title
    }

    private func journeyRoad() throws -> (type: String, number: Int) {
        guard let road = try store.journeyRoad(journeyID: journeyID) else {
            throw RenderSetupError(message: "Journey \(journeyID) has no road recorded.")
        }
        return road
    }

    /// The journey's plain `output` directory, created (and excluded from
    /// backup) if needed.
    private func makeOutputDirectory() throws -> URL {
        let outputDirectory = URL(filePath: try journeyDirectory()).appending(path: "output")
        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true)
        try FileManager.default.excludeFromBackup(outputDirectory)
        return outputDirectory
    }

    /// Runs one movie write, deleting the partial output if it's cancelled
    /// so a half-written .mov never masquerades as a finished component.
    private func write(_ url: URL, _ body: () async throws -> Void) async throws -> URL {
        do {
            try await body()
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: url)
            throw CancellationError()
        }
        return url
    }
}
