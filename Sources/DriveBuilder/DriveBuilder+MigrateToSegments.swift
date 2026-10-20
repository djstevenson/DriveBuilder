import ArgumentParser
import Foundation

extension DriveBuilder {
    struct MigrateToSegments: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "migrate-to-segments",
            abstract: "Move each journey's sync offsets and length into a journey segment.",
            discussion: """
                A one-off move of the journeys table's front_offset, rear_offset, \
                telemetry_offset, left_offset, right_offset, and length columns into \
                a new journey_segments table, giving every journey one segment over \
                the default files (video/front.mov, rear.mov, left.mov, right.mov). \
                It first copies the database to <database>.pre-segments (which \
                mustn't already exist), then migrates in one transaction.
                """)

        @Option(help: "The database to migrate (default: the source tree's telemetry.sqlite3).")
        var database: String = TelemetryDatabase.sourceTreePath

        mutating func run() async throws {
            let store = TelemetryStore(path: database)
            guard try store.needsSegmentMigration() else {
                print("\(database) already has journey segments; nothing to do.")
                return
            }
            let backupPath = database + ".pre-segments"
            let count = try store.applySegmentMigration(backupPath: backupPath)
            print("Migrated \(count) journeys. The old database is at \(backupPath).")
        }
    }
}
