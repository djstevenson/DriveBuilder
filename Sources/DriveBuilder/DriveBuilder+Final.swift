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
                + "aligned, and that into the outro. The drive plays the journey's "
                + "segments in turn, each from its own files with its own start offsets "
                + "bringing the separately started recordings into sync, dipping to black "
                + "at each join; the last runs for whichever of its sources is shortest "
                + "after its offset unless it has a length. Annotation banners (the database's \"annotations\" "
                + "table, already rendered by the annotations command) composite over the "
                + "bottom of the drive segment, each ending as the journey passes its end "
                + "location; camera overrides likewise run between the locations bounding "
                + "them. Requires "
                + "intro.mov, route_map.mov, dials.mov, and outro.mov "
                + "to have been rendered already.")

        @OptionGroup var telemetry: TelemetryOptions

        @Option(
            name: [.customShort("l"), .customLong("length")],
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
            let renderer = JourneyRenderer(
                journeyID: telemetry.journeyID,
                databasePath: try TelemetryOptions.databasePath())
            _ = try await renderer.renderFinal(driveSegmentSeconds: length)
        }
    }
}
