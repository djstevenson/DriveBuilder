import ArgumentParser
import Foundation

extension DriveBuilder {
    struct ProgressMap: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "progress-map",
            abstract: "Build the overview progress map for a journey.")

        @OptionGroup var telemetry: TelemetryOptions

        @OptionGroup var video: VideoOptions

        @OptionGroup var map: MapOptions

        mutating func run() async throws {
            var tileRenderer = map.tileRenderer
            tileRenderer.scaleFactor =
                Double(video.mapPixelSize) / ProgressMapRenderer.designPixelSize
            let renderer = ProgressMapRenderer(
                records: try telemetry.load(),
                pixelSize: video.mapPixelSize,
                tileRenderer: tileRenderer)
            try await renderer.writeMovie(
                to: video.outputURL(
                    named: "progress_map", journeyDirectory: try telemetry.journeyDirectory()),
                framesPerSecond: video.framesPerSecond,
                frameLimit: video.frameLimit)
        }
    }
}
