import ArgumentParser
import Foundation

extension DriveBuilder {
    struct Limit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Build the speed limit sign for a journey.")

        @OptionGroup var telemetry: TelemetryOptions

        @OptionGroup var video: VideoOptions

        mutating func run() async throws {
            let renderer = LimitRenderer(records: try telemetry.load(), pixelSize: video.pixelSize)
            try await renderer.writeMovie(
                to: video.outputURL(
                    named: "limit", journeyDirectory: try telemetry.journeyDirectory()),
                framesPerSecond: video.framesPerSecond,
                frameLimit: video.frameLimit)
        }
    }
}
