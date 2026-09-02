import ArgumentParser
import Foundation

extension DriveBuilder {
    struct Outro: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "outro",
            abstract: "Build the road-number outro badge.")

        @OptionGroup var telemetry: TelemetryOptions

        @Option(
            name: .customLong("frame-limit"),
            help: "Render only the first N frames, for a quick check.")
        var frameLimit: Int?

        mutating func run() async throws {
            let road = try telemetry.journeyRoad()
            let title = try telemetry.journeyTitle()
            let outputDirectory = URL(filePath: try telemetry.journeyDirectory())
                .appending(path: "output")
            try FileManager.default.createDirectory(
                at: outputDirectory, withIntermediateDirectories: true)
            try FileManager.default.excludeFromBackup(outputDirectory)

            // Rendered nearly full-screen, matching the intro's size so the
            // two clips line up when cross-faded.
            let size = IntroRenderer.wideScreenSize
            let renderer = OutroRenderer(
                roadType: road.type, roadNumber: road.number, title: title,
                width: size.width, height: size.height)
            try await renderer.writeMovie(
                to: outputDirectory.appending(path: "outro.mov"),
                frameLimit: frameLimit)
        }
    }
}
