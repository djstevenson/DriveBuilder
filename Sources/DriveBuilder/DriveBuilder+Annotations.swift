import ArgumentParser
import Foundation

extension DriveBuilder {
    struct Annotations: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "annotations",
            abstract: "Build the scrolling annotation banners for a journey.",
            discussion: "Reads the journey's rows from the database's \"annotations\" table: "
                + "each row's \"video\" names the output (output/<video>.mov) and \"text\" is "
                + "what scrolls across the banner.")

        @OptionGroup var telemetry: TelemetryOptions

        @OptionGroup var video: FrameLimitOptions

        /// The annotation's text: lines joined with single spaces, since the
        /// scroll is one long line. Blank lines and leading or trailing
        /// whitespace on each line are dropped.
        static func normalizedText(_ text: String) -> String {
            text
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        mutating func run() async throws {
            var renderer = JourneyRenderer(
                journeyID: telemetry.journeyID,
                databasePath: try TelemetryOptions.databasePath())
            renderer.frameLimit = video.frameLimit
            _ = try await renderer.renderAnnotations()
        }
    }
}
