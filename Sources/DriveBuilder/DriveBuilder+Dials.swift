import ArgumentParser
import Foundation

extension DriveBuilder {
    struct Dials: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Build the combined telemetry video for a journey.",
            discussion: "Composites every dial into a single telemetry.mov, frame by frame, "
                + "rather than writing each dial's movie separately; use the individual "
                + "dial commands to inspect one dial on its own. Run RouteMap separately "
                + "for the route summary clip.")

        @OptionGroup var telemetry: TelemetryOptions

        @OptionGroup var video: VideoOptions

        @OptionGroup var map: MapOptions

        func validate() throws {
            // The composite's layout derives the inter-dial gap from the two
            // default edge lengths; a single override can't describe both.
            if video.pixelSize != nil {
                throw ValidationError(
                    "--size does not apply to the combined telemetry video; "
                        + "use the individual dial commands to render at another size.")
            }
        }

        mutating func run() async throws {
            let records = try telemetry.load()
            let journeyDirectory = try telemetry.journeyDirectory()
            var progressTileRenderer = map.tileRenderer
            progressTileRenderer.scaleFactor =
                Double(video.mapPixelSize) / ProgressMapRenderer.designPixelSize

            try await TelemetryVideoRenderer(
                records: records,
                dialPixelSize: video.dialPixelSize,
                mapPixelSize: video.mapPixelSize,
                tileRenderer: progressTileRenderer)
                .writeMovie(
                    to: video.outputURL(named: "telemetry", journeyDirectory: journeyDirectory),
                    framesPerSecond: video.framesPerSecond,
                    frameLimit: video.frameLimit)
        }
    }
}
