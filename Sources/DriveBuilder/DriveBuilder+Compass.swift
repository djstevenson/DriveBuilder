import ArgumentParser
import Foundation

extension DriveBuilder {
    struct Compass: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Build the compass dial for a journey.")

        @OptionGroup var telemetry: TelemetryOptions

        @OptionGroup var video: VideoOptions

        mutating func run() async throws {
            let renderer = CompassRenderer(
                records: try telemetry.load(), pixelSize: video.pixelSize)
            try await renderer.writeMovie(
                to: video.outputURL(
                    named: "compass", journeyDirectory: try telemetry.journeyDirectory()),
                framesPerSecond: video.framesPerSecond,
                frameLimit: video.frameLimit)
        }
    }
}
