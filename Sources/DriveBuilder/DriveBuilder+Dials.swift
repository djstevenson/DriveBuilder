import ArgumentParser
import Foundation

extension DriveBuilder {
    struct Dials: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Build the combined telemetry video and the route map.",
            discussion: "Composites every dial into a single telemetry.mov, frame by frame, "
                + "rather than writing each dial's movie separately; use the individual "
                + "dial commands to inspect one dial on its own.")

        @OptionGroup var telemetry: TelemetryOptions

        @OptionGroup var video: VideoOptions

        @OptionGroup var map: MapOptions

        @OptionGroup var route: RouteMapOptions

        func validate() throws {
            // The composite's layout derives the inter-dial gap from the two
            // default edge lengths; a single override can't describe both.
            if video.pixelSize != nil {
                throw ValidationError(
                    "--size does not apply to the combined telemetry video; "
                        + "use the individual dial commands to render at another size.")
            }
        }

        /// Loads the journey once, then renders the combined telemetry video
        /// and the route map concurrently: each movie is an independent
        /// encoder session, so wall time approaches the slower of the two.
        mutating func run() async throws {
            let records = try telemetry.load()
            let video = video
            let journeyDirectory = try telemetry.journeyDirectory()
            let tileRenderer = map.tileRenderer
            let routeConfig = try route.loadConfig(journeyDirectory: journeyDirectory)
            var routeTileRenderer = tileRenderer
            routeTileRenderer.scaleFactor =
                Double(routeConfig.width) / RouteMapRenderer.mapXMLDesignWidth
            var nationalTileRenderer = tileRenderer
            nationalTileRenderer.stylesheet = "map-national.xml"
            nationalTileRenderer.scaleFactor =
                Double(routeConfig.width) / RouteMapRenderer.mapXMLDesignWidth
            var progressTileRenderer = tileRenderer
            progressTileRenderer.scaleFactor =
                Double(video.mapPixelSize) / ProgressMapRenderer.designPixelSize

            let renders: [@Sendable () async throws -> Void] = [
                { [progressTileRenderer] in
                    try await TelemetryVideoRenderer(
                        records: records,
                        dialPixelSize: video.dialPixelSize,
                        mapPixelSize: video.mapPixelSize,
                        tileRenderer: progressTileRenderer)
                        .writeMovie(
                            to: video.outputURL(
                                named: "telemetry", journeyDirectory: journeyDirectory),
                            framesPerSecond: video.framesPerSecond,
                            frameLimit: video.frameLimit)
                },
                { [routeTileRenderer, nationalTileRenderer] in
                    try await RouteMapRenderer(
                        records: records,
                        tileRenderer: routeTileRenderer,
                        config: routeConfig)
                        .writeMovie(
                            nationalTileRenderer: nationalTileRenderer,
                            to: video.outputURL(
                                named: "route_map", journeyDirectory: journeyDirectory),
                            frameLimit: video.frameLimit)
                },
            ]

            try await withThrowingTaskGroup(of: Void.self) { group in
                for render in renders {
                    group.addTask { try await render() }
                }
                try await group.waitForAll()
            }
        }
    }
}
