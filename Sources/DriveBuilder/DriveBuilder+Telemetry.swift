import ArgumentParser
import Foundation

/// The canonical telemetry database is the one checked into this source
/// tree. The copy the render subcommands read from `Bundle.module` is
/// recreated from it on every build, so inserts must land here (and want a
/// rebuild afterwards) to be seen and to survive.
private let sourceTreeDatabasePath = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "Resources/telemetry.sqlite3")
    .path(percentEncoded: false)

extension DriveBuilder {
    struct Telemetry: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "telemetry",
            abstract: "Extract a journey's telemetry from its dashcam footage into the database.",
            discussion: """
                Runs exiftool over the NextBase front-camera clips beneath the journey \
                directory, decodes the GPS and accelerometer streams, looks up speed \
                limits from the local OSM database, and stores the result as a new \
                journey. Rebuild before rendering so the bundled database copy picks \
                up the new journey.
                """)

        @Option(help: "The journey directory, containing NextBase/front video files.")
        var directory: String

        @Option(help: "The road the journey was driven on, e.g. A338.")
        var road: String

        @Option(help: "A human-readable title for the journey.")
        var title: String

        @Option(help: "The telemetry database to insert into.")
        var database: String = sourceTreeDatabasePath

        mutating func run() async throws {
            // The journey is named by its directory path, trailing slashes
            // stripped, to match what the render subcommands expect to find
            // in journeys.source.
            var source = directory
            while source.count > 1, source.hasSuffix("/") { source.removeLast() }

            var isDirectory = ObjCBool(false)
            guard
                FileManager.default.fileExists(atPath: source, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                throw ValidationError("\(source) is not a directory.")
            }

            guard let match = road.uppercased().wholeMatch(of: /([A-Z]+)(\d+)/),
                let roadNumber = Int(match.2)
            else {
                throw ValidationError("\"\(road)\" is not a road like A338 or M27.")
            }
            let roadType = String(match.1)

            let store = TelemetryStore(path: database)
            if let journeyID = try store.journeyID(source: source) {
                throw ValidationError("\(source) is already stored as journey \(journeyID).")
            }
            if let journeyID = try store.journeyID(roadType: roadType, roadNumber: roadNumber) {
                throw ValidationError(
                    "\(roadType)\(roadNumber) is already stored as journey \(journeyID).")
            }

            Self.log("Extract telemetry data")
            let extractor = NextBaseExtractor(videoPath: source) { points in
                try SpeedLimitLookup().limits(for: points)
            }
            let samples = try extractor.samples()

            Self.log("Store telemetry in SQLite")
            let journeyID = try store.insertJourney(
                source: source, roadType: roadType, roadNumber: roadNumber, title: title,
                samples: samples)

            Self.log("Done")
            print("Journey \(journeyID): \(samples.count) records for \(roadType)\(roadNumber)")
        }

        /// Progress goes to stderr, timestamped, as the Perl pipeline does.
        private static func log(_ message: String) {
            let now = Date.now.formatted(date: .abbreviated, time: .standard)
            FileHandle.standardError.write(Data("\(now) \(message)\n".utf8))
        }
    }
}
