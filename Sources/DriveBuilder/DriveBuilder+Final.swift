import ArgumentParser
import Foundation

extension DriveBuilder {
    struct Final: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "final",
            abstract: "Assemble the final video from the rendered clips.",
            discussion: "Cross-fades the intro into the route map, the route map into a "
                + "placeholder for the drive footage (a 10-second black screen for now), "
                + "and the placeholder into the outro. Requires intro.mov, "
                + "telemetry/route_map.mov, and outro.mov to have been rendered already.")

        @OptionGroup var telemetry: TelemetryOptions

        mutating func run() async throws {
            let outputDirectory = URL(filePath: try telemetry.journeyDirectory())
                .appending(path: "output")
            try FileManager.default.createDirectory(
                at: outputDirectory, withIntermediateDirectories: true)
            try FileManager.default.excludeFromBackup(outputDirectory)

            let composer = FinalVideoComposer(
                introURL: outputDirectory.appending(path: "intro.mov"),
                routeMapURL: outputDirectory.appending(path: "telemetry/route_map.mov"),
                outroURL: outputDirectory.appending(path: "outro.mov"))
            try await composer.writeMovie(to: outputDirectory.appending(path: "final.mov"))
        }
    }
}
