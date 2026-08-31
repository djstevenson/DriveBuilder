import ArgumentParser
import Foundation

extension DriveBuilder {
    struct Speedo: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Build the speedometer dial for a journey.")

        @OptionGroup var telemetry: TelemetryOptions

        @OptionGroup var video: VideoOptions

        mutating func run() async throws {
            let renderer = SpeedoRenderer(records: try telemetry.load(), pixelSize: video.pixelSize)
            try await renderer.writeMovie(
                to: video.outputURL(
                    named: "speedo", journeyDirectory: try telemetry.journeyDirectory()),
                framesPerSecond: video.framesPerSecond,
                frameLimit: video.frameLimit)
        }
    }
}
