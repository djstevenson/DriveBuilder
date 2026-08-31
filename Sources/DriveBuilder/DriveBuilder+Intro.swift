import ArgumentParser
import Foundation

extension DriveBuilder {
    struct Intro: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "intro",
            abstract: "Build the road-number intro badge.")

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

            // Other real roads to cycle through during the spin, so its
            // title animates in step with the spinning number; the real
            // target is excluded so the spin never coincidentally shows it
            // early.
            let targetRoadName = "\(road.type)\(road.number)"
            let spinEntries = try telemetry.allCachedRoads()
                .filter { $0.roadName != targetRoadName }
                .map {
                    IntroRenderer.SpinEntry(
                        roadText: $0.roadName, title: "\($0.startName) to \($0.endName)")
                }

            // Rendered nearly full-screen, so sized well above the 420px
            // dials: 80% of a 4K screen's width.
            let size = IntroRenderer.wideScreenSize
            let renderer = IntroRenderer(
                roadType: road.type, roadNumber: road.number, title: title,
                spinEntries: spinEntries, width: size.width, height: size.height)
            try await renderer.writeMovie(
                to: outputDirectory.appending(path: "intro.mov"),
                frameLimit: frameLimit)
        }
    }
}
