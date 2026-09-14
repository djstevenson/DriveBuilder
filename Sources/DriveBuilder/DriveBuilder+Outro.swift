import ArgumentParser
import Foundation

extension DriveBuilder {
    struct Outro: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "outro",
            abstract: "Build the road-number outro badge.")

        @OptionGroup var telemetry: TelemetryOptions

        @OptionGroup var video: FrameLimitOptions

        mutating func run() async throws {
            var renderer = JourneyRenderer(
                journeyID: telemetry.journeyID,
                databasePath: try TelemetryOptions.databasePath())
            renderer.frameLimit = video.frameLimit
            _ = try await renderer.renderOutro()
        }
    }
}
