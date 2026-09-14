import ArgumentParser
import Foundation

extension DriveBuilder {
    struct Intro: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "intro",
            abstract: "Build the road-number intro badge.")

        @OptionGroup var telemetry: TelemetryOptions

        @OptionGroup var video: FrameLimitOptions

        mutating func run() async throws {
            var renderer = JourneyRenderer(
                journeyID: telemetry.journeyID,
                databasePath: try TelemetryOptions.databasePath())
            renderer.frameLimit = video.frameLimit
            _ = try await renderer.renderIntro()
        }
    }
}
