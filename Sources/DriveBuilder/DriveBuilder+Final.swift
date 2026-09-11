import ArgumentParser
import Foundation

extension DriveBuilder {
    struct Final: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "final",
            abstract: "Assemble the final video from the rendered clips.",
            discussion: "Cross-fades the intro into the route map, the route map into the "
                + "journey's drive footage (video/front.mov beneath the journey "
                + "directory) with the rear-view camera (video/rear.mov) inset near the "
                + "top-left and the dial column (dials.mov) composited on top, right-"
                + "aligned, and that into the outro. The footage and the dial column run "
                + "for whichever of the three is shortest. Requires intro.mov, "
                + "telemetry/route_map.mov, telemetry/dials.mov, and outro.mov to have "
                + "been rendered already.")

        @OptionGroup var telemetry: TelemetryOptions

        mutating func run() async throws {
            let journeyDirectory = try telemetry.journeyDirectory()
            let outputDirectory = URL(filePath: journeyDirectory)
                .appending(path: "output")
            try FileManager.default.createDirectory(
                at: outputDirectory, withIntermediateDirectories: true)
            try FileManager.default.excludeFromBackup(outputDirectory)

            let composer = FinalVideoComposer(
                introURL: outputDirectory.appending(path: "intro.mov"),
                routeMapURL: outputDirectory.appending(path: "telemetry/route_map.mov"),
                dialsURL: outputDirectory.appending(path: "telemetry/dials.mov"),
                frontFootageURL: URL(filePath: journeyDirectory).appending(path: "video/front.mov"),
                rearFootageURL: URL(filePath: journeyDirectory).appending(path: "video/rear.mov"),
                outroURL: outputDirectory.appending(path: "outro.mov"))
            try await composer.writeMovie(to: outputDirectory.appending(path: "final.mov"))
        }
    }
}
