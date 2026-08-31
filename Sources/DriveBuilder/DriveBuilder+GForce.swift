import ArgumentParser
import Foundation

extension DriveBuilder {
    struct GForce: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "gforce",
            abstract: "Build the g-force dial for a journey.")

        @OptionGroup var telemetry: TelemetryOptions

        @OptionGroup var video: VideoOptions

        mutating func run() async throws {
            let renderer = GForceRenderer(
                records: try telemetry.load(), pixelSize: video.pixelSize)
            try await renderer.writeMovie(
                to: video.outputURL(
                    named: "gforce", journeyDirectory: try telemetry.journeyDirectory()),
                framesPerSecond: video.framesPerSecond,
                frameLimit: video.frameLimit)
        }
    }
}
