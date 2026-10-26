import ArgumentParser
import Foundation

extension DriveBuilder {
    struct FastFinal: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "fast-final",
            abstract: "Assemble a sped-up version of the final video.",
            discussion: "Builds final_fast.mov just as the final command builds final.mov, "
                + "but with the route map at 2x speed and the drive (footage, rear view, "
                + "dials, and camera overrides) at --speed, silently and without the "
                + "annotation banners, which would scroll past too fast to read. The intro "
                + "and outro still play at real time. Requires intro.mov, route_map.mov, "
                + "dials.mov, and outro.mov to have been rendered already.")

        @OptionGroup var telemetry: TelemetryOptions

        @Option(
            name: [.customShort("s"), .customLong("speed")],
            help: "How many times faster than real time the drive plays.")
        var speed: Double = JourneyRenderer.defaultFastDriveSpeed

        @Option(
            name: [.customShort("l"), .customLong("length")],
            help: ArgumentHelp(
                "Cap the drive to at most this many seconds of driving (before speeding "
                    + "up), for a quick test render; the intro and outro still play in full. "
                    + "Omit for the full-length video."))
        var length: Double?

        func validate() throws {
            if speed <= 0 {
                throw ValidationError("--speed must be a positive multiple.")
            }
            if let length, length <= 0 {
                throw ValidationError("--length must be a positive number of seconds.")
            }
        }

        mutating func run() async throws {
            let renderer = JourneyRenderer(
                journeyID: telemetry.journeyID,
                databasePath: try TelemetryOptions.databasePath())
            _ = try await renderer.renderFastFinal(driveSpeed: speed, driveSegmentSeconds: length)
        }
    }
}
