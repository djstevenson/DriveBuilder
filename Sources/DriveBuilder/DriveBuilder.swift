import ArgumentParser

// The entry point lives in the DriveBuilderCLI target's main.swift, which
// just calls DriveBuilder.main(); @main can't be used here now that this
// target is a library.
package struct DriveBuilder: AsyncParsableCommand {
    package static let configuration = CommandConfiguration(
        abstract: "Builds telemetry dials etc for driving videos",
        subcommands: [
            Dials.self, Speedo.self, Compass.self, Altitude.self, GForce.self,
            ProgressMap.self, ProgressMapZoomed.self,
            RouteMap.self, Annotations.self, Intro.self, Outro.self,
            Telemetry.self, RoadData.self, Final.self,
        ],
        defaultSubcommand: Dials.self)

    package init() {}

    /// Entry point for the CLI target. A distinct name because an
    /// unqualified `DriveBuilder.main()` resolves to ParsableCommand's
    /// synchronous main(), which refuses to run an async root command.
    package static func runCLI() async {
        do {
            var command = try parseAsRoot()
            if var asyncCommand = command as? any AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            exit(withError: error)
        }
    }
}
