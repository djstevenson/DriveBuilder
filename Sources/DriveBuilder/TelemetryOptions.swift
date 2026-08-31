import ArgumentParser
import Foundation

/// Options shared by every subcommand that works from journey telemetry.
///
/// Include with `@OptionGroup` so a subcommand picks up the flag and the
/// loading in one place. The database lives in this project (see
/// `Resources/telemetry.sqlite3`), not on the command line: a journey's
/// source footage, annotations, and output all live in the directory
/// recorded for it in the database, so the CLI only ever needs its id.
struct TelemetryOptions: ParsableArguments {
    @Option(
        name: [.customShort("j"), .customLong("journey-id")],
        help: "The journey to render.")
    var journeyID: Int64

    private static func databasePath() throws -> String {
        guard let url = Bundle.module.url(forResource: "telemetry", withExtension: "sqlite3")
        else {
            throw ValidationError("Bundled telemetry.sqlite3 resource is missing.")
        }
        return url.path(percentEncoded: false)
    }

    /// Every telemetry sample for the selected journey, in timestamp order.
    func load() throws -> [TelemetryRecord] {
        try TelemetryStore(path: Self.databasePath()).records(journeyID: journeyID)
    }

    /// The journey's directory: where its source footage, annotations, and
    /// output live.
    func journeyDirectory() throws -> String {
        guard
            let directory = try TelemetryStore(path: Self.databasePath())
                .journeyDirectory(journeyID: journeyID)
        else {
            throw ValidationError("Journey \(journeyID) has no directory recorded.")
        }
        return directory
    }

    /// The journey's title.
    func journeyTitle() throws -> String {
        guard
            let title = try TelemetryStore(path: Self.databasePath())
                .journeyTitle(journeyID: journeyID)
        else {
            throw ValidationError("Journey \(journeyID) has no title recorded.")
        }
        return title
    }

    /// Every road cached in the roads table, for cycling through during the
    /// intro's slot-machine spin.
    func allCachedRoads() throws -> [CachedRoad] {
        try TelemetryStore(path: Self.databasePath()).allCachedRoads()
    }

    /// The journey's road: type (e.g. "A") and number (e.g. 338).
    func journeyRoad() throws -> (type: String, number: Int) {
        guard
            let road = try TelemetryStore(path: Self.databasePath())
                .journeyRoad(journeyID: journeyID)
        else {
            throw ValidationError("Journey \(journeyID) has no road recorded.")
        }
        return road
    }
}
