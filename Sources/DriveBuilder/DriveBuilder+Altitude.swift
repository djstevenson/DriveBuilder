import ArgumentParser
import Foundation

extension DriveBuilder {
    struct Altitude: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Build the altitude indicator for a journey.")

        @OptionGroup var telemetry: TelemetryOptions

        @OptionGroup var video: VideoOptions

        mutating func run() async throws {
            let renderer = AltitudeRenderer(
                records: try telemetry.load(), pixelSize: video.pixelSize)
            try await renderer.writeMovie(
                to: video.outputURL(
                    named: "altitude", journeyDirectory: try telemetry.journeyDirectory()),
                framesPerSecond: video.framesPerSecond,
                frameLimit: video.frameLimit)
        }
    }
}
