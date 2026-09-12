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
                + "aligned, and that into the outro. Per-component start offsets from the "
                + "journey's main.json bring the separately started recordings into sync, "
                + "and the drive segment runs for whichever of the three is shortest "
                + "after its offset. Requires intro.mov, telemetry/route_map.mov, "
                + "telemetry/dials.mov, and outro.mov to have been rendered already.")

        @OptionGroup var telemetry: TelemetryOptions

        @Option(
            name: .customLong("length"),
            help: ArgumentHelp(
                "Cap the drive segment to at most this many seconds, for a quick test "
                    + "render while checking sync; the intro and outro still play in full. "
                    + "Omit for the full-length final video."))
        var length: Double?

        func validate() throws {
            if let length, length <= 0 {
                throw ValidationError("--length must be a positive number of seconds.")
            }
        }

        mutating func run() async throws {
            let journeyDirectory = try telemetry.journeyDirectory()
            let outputDirectory = URL(filePath: journeyDirectory)
                .appending(path: "output")
            try FileManager.default.createDirectory(
                at: outputDirectory, withIntermediateDirectories: true)
            try FileManager.default.excludeFromBackup(outputDirectory)

            var composer = FinalVideoComposer(
                introURL: outputDirectory.appending(path: "intro.mov"),
                routeMapURL: outputDirectory.appending(path: "telemetry/route_map.mov"),
                dialsURL: outputDirectory.appending(path: "telemetry/dials.mov"),
                frontFootageURL: URL(filePath: journeyDirectory).appending(path: "video/front.mov"),
                rearFootageURL: URL(filePath: journeyDirectory).appending(path: "video/rear.mov"),
                outroURL: outputDirectory.appending(path: "outro.mov"))
            composer.startOffsets = try MainConfig.load(journeyDirectory: journeyDirectory)
                .startOffsets
            composer.maxDriveSegmentSeconds = length
            try await composer.writeMovie(to: outputDirectory.appending(path: "final.mov"))
        }
    }
}
