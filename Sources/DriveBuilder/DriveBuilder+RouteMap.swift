import ArgumentParser
import Foundation

extension DriveBuilder {
    struct RouteMap: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "route-map",
            abstract: "Build the route overview map for a journey.",
            discussion: "Full-screen output (4K 30 fps): opens with the national "
                + "establishing shot (Great Britain zooming smoothly into the route's area), "
                + "then this journey's own static map, the route snaking out faster than "
                + "real time, and a hold on the completed track. Size, frame rate, and phase "
                + "timings are built in; the labels popping in along the track come from "
                + "the database's \"route_map_labels\" table. The --size and --fps options "
                + "do not apply.")

        @OptionGroup var telemetry: TelemetryOptions

        @OptionGroup var video: VideoOptions

        @OptionGroup var map: MapOptions

        mutating func run() async throws {
            var renderer = JourneyRenderer(
                journeyID: telemetry.journeyID,
                databasePath: try TelemetryOptions.databasePath())
            renderer.frameLimit = video.frameLimit
            renderer.mapDirectory = map.mapDirectory
            _ = try await renderer.renderRouteMap()
        }
    }
}
