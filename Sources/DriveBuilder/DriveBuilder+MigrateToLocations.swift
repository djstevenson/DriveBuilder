import ArgumentParser
import Foundation

extension DriveBuilder {
    struct MigrateToLocations: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "migrate-to-locations",
            abstract: "Convert annotation, camera override, and route-map label times to locations.",
            discussion: """
                A one-off move from time offsets (raw front.mov seconds for annotations \
                and camera overrides, raw telemetry seconds for route-map labels) to \
                the locations the journey passes at those times, using each \
                journey's current sync offsets. Every converted location is turned \
                back into a time the way renders will, and the migration refuses to \
                run if any lands more than 0.5 s away. Without --apply it only \
                prints that report. With --apply it first copies the database to \
                <database>.pre-locations (which mustn't already exist), then \
                rebuilds the three tables in one transaction.
                """)

        @Option(help: "The database to migrate (default: the source tree's telemetry.sqlite3).")
        var database: String = TelemetryDatabase.sourceTreePath

        @Flag(help: "Back up and migrate, rather than just reporting.")
        var apply = false

        mutating func run() async throws {
            let store = TelemetryStore(path: database)
            guard try store.hasTimeOffsetColumns() else {
                print("\(database) already stores locations; nothing to do.")
                return
            }

            let items = try store.planLocationMigration()
            for item in items {
                let stored =
                    (item.table == .routeMapLabels ? "telemetry " : "front ")
                    + ClockTime.text(for: item.storedSeconds)
                let outcome =
                    item.problem.map { "PROBLEM: \($0)" }
                    ?? String(
                        format: "%@  drift %+.2fs", item.location?.text ?? "",
                        item.driftSeconds ?? 0)
                print(
                    "\(item.table.rawValue) \(item.id) (journey \(item.journeyID), "
                        + "\(item.name)) \(item.field.rawValue) at \(stored) -> \(outcome)")
            }
            let problems = items.filter { $0.problem != nil }.count
            print("\(items.count) times, \(problems) with problems.")

            guard problems == 0 else {
                print("Nothing changed; fix the problems above first.")
                throw ExitCode.failure
            }
            guard apply else {
                print("Dry run: nothing changed. Run again with --apply to migrate.")
                return
            }
            let backupPath = database + ".pre-locations"
            try store.applyLocationMigration(items, backupPath: backupPath)
            print("Migrated. The old database is at \(backupPath).")
        }
    }
}
