import ArgumentParser
import Foundation

extension DriveBuilder {
    struct Dials: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Rebuild all telemetry dials.")

        @OptionGroup var telemetry: TelemetryOptions

        @OptionGroup var video: VideoOptions

        @OptionGroup var map: MapOptions

        @OptionGroup var route: RouteMapOptions

        /// Loads the journey once and hands the same records to every renderer.
        ///
        /// The dials all render concurrently: each movie is an independent
        /// encoder session, so wall time approaches the slowest dial rather
        /// than the sum. Capping the number of concurrent dials was tried and
        /// measured slower than letting them all run.
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

            let dials: [@Sendable () async throws -> Void] = [
                {
                    try await SpeedoRenderer(records: records, pixelSize: video.dialPixelSize)
                        .writeMovie(
                            to: video.outputURL(
                                named: "speedo", journeyDirectory: journeyDirectory),
                            framesPerSecond: video.framesPerSecond,
                            frameLimit: video.frameLimit)
                },
                {
                    try await CompassRenderer(records: records, pixelSize: video.dialPixelSize)
                        .writeMovie(
                            to: video.outputURL(
                                named: "compass", journeyDirectory: journeyDirectory),
                            framesPerSecond: video.framesPerSecond,
                            frameLimit: video.frameLimit)
                },
                {
                    try await AltitudeRenderer(records: records, pixelSize: video.dialPixelSize)
                        .writeMovie(
                            to: video.outputURL(
                                named: "altitude", journeyDirectory: journeyDirectory),
                            framesPerSecond: video.framesPerSecond,
                            frameLimit: video.frameLimit)
                },
                {
                    try await GForceRenderer(records: records, pixelSize: video.dialPixelSize)
                        .writeMovie(
                            to: video.outputURL(
                                named: "gforce", journeyDirectory: journeyDirectory),
                            framesPerSecond: video.framesPerSecond,
                            frameLimit: video.frameLimit)
                },
                {
                    try await ProgressMapRenderer(
                        records: records,
                        pixelSize: video.mapPixelSize,
                        tileRenderer: tileRenderer)
                        .writeMovie(
                            to: video.outputURL(
                                named: "progress_map", journeyDirectory: journeyDirectory),
                            framesPerSecond: video.framesPerSecond,
                            frameLimit: video.frameLimit)
                },
                {
                    try await ProgressMapZoomedRenderer(
                        records: records,
                        pixelSize: video.mapPixelSize,
                        tileRenderer: tileRenderer)
                        .writeMovie(
                            to: video.outputURL(
                                named: "progress_map_zoomed", journeyDirectory: journeyDirectory),
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
                for dial in dials {
                    group.addTask { try await dial() }
                }
                try await group.waitForAll()
            }
        }
    }
}
