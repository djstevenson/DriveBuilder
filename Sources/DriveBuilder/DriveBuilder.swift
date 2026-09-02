import ArgumentParser

@main
struct DriveBuilder: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Builds telemetry dials etc for driving videos",
        subcommands: [
            Dials.self, Speedo.self, Limit.self, Compass.self, Altitude.self, GForce.self,
            WallClock.self, RelativeClock.self, ProgressMap.self, ProgressMapZoomed.self,
            RouteMap.self, Annotations.self, Intro.self, Outro.self,
            Telemetry.self, RoadData.self,
        ],
        defaultSubcommand: Dials.self)
}
