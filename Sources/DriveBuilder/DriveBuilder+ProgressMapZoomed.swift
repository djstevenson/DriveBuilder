import ArgumentParser
import Foundation

/// Where the Perl drive-builder checkout lives: the zoomed progress map
/// shells out to its `maprender.py` (Mapnik over a local OSM extract) so the
/// two pipelines produce identical cartography.
struct MapOptions: ParsableArguments {
    @Option(
        name: .customLong("map-dir"),
        help: "Directory containing maprender.py, map.xml, and the OSM data.")
    var mapDirectory: String = "/Users/davids/src/perl/drive-builder"

    var tileRenderer: MaprenderTileRenderer {
        MaprenderTileRenderer(directory: URL(filePath: mapDirectory))
    }
}

extension DriveBuilder {
    struct ProgressMapZoomed: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "progress-map-zoomed",
            abstract: "Build the zoomed progress map for a journey.",
            discussion: "Renders at a fixed 30 fps, interpolating three frames per record; "
                + "the --fps option does not apply.")

        @OptionGroup var telemetry: TelemetryOptions

        @OptionGroup var video: VideoOptions

        @OptionGroup var map: MapOptions

        mutating func run() async throws {
            var tileRenderer = map.tileRenderer
            tileRenderer.scaleFactor =
                Double(video.mapPixelSize) / ProgressMapZoomedRenderer.designPixelSize
            let renderer = ProgressMapZoomedRenderer(
                records: try telemetry.load(),
                pixelSize: video.mapPixelSize,
                tileRenderer: tileRenderer)
            try await renderer.writeMovie(
                to: video.outputURL(
                    named: "progress_map_zoomed", journeyDirectory: try telemetry.journeyDirectory()),
                frameLimit: video.frameLimit)
        }
    }
}
