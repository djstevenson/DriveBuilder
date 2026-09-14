import ArgumentParser
import Foundation

/// Options specific to the route map's config-driven rendering.
struct RouteMapOptions: ParsableArguments {
    @Option(
        name: .customLong("route-config"),
        help: ArgumentHelp(
            "JSON config for the route map: output size, phase timings, labels. "
                + "Defaults to route_map.json in the journey's source footage directory, "
                + "if present."))
    var routeConfigPath: String?

    /// Resolves the config like the Perl pipeline: an explicit path must
    /// exist, otherwise `route_map.json` beside the journey's source footage
    /// is used when present, otherwise the built-in defaults.
    func loadConfig(journeyDirectory: String?) throws -> RouteMapConfig {
        try JourneyRenderer.routeMapConfig(
            explicitPath: routeConfigPath, journeyDirectory: journeyDirectory)
    }
}

extension DriveBuilder {
    struct RouteMap: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "route-map",
            abstract: "Build the route overview map for a journey.",
            discussion: "Full-screen output (4K 30 fps by default): opens with the national "
                + "establishing shot (Great Britain zooming smoothly into the route's area), "
                + "then this journey's own static map, the route snaking out faster than "
                + "real time, and a hold on the completed track. Size, frame rate, phase "
                + "timings, and labels come from --route-config; the --size and --fps "
                + "options do not apply.")

        @OptionGroup var telemetry: TelemetryOptions

        @OptionGroup var video: VideoOptions

        @OptionGroup var map: MapOptions

        @OptionGroup var route: RouteMapOptions

        mutating func run() async throws {
            var renderer = JourneyRenderer(
                journeyID: telemetry.journeyID,
                databasePath: try TelemetryOptions.databasePath())
            renderer.frameLimit = video.frameLimit
            renderer.mapDirectory = map.mapDirectory
            _ = try await renderer.renderRouteMap(routeConfigPath: route.routeConfigPath)
        }
    }
}
