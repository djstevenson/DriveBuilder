import ArgumentParser
import Foundation
import Testing

@testable import DriveBuilder

/// The checked-in test database: journey 1 is the A338 Northbound drive,
/// independent of whatever journeys the real database holds.
private let fixtureDatabasePath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "Fixtures/A338 Northbound/telemetry.sqlite3")
    .path(percentEncoded: false)

@Test func journeyIDIsRequired() {
    #expect(throws: (any Error).self) {
        try TelemetryOptions.parse([])
    }
}

@Test func shortFlagIsEquivalentToTheLongForm() throws {
    let long = try TelemetryOptions.parse(["--journey-id", "1"])
    let short = try TelemetryOptions.parse(["-j", "1"])
    #expect(long.journeyID == short.journeyID)
}

/// The bundled `telemetry.sqlite3` resource resolves and opens. Its
/// journeys are real and come and go, so nothing about them is checked.
@Test func bundledDatabaseResolvesAndOpens() throws {
    _ = try TelemetryStore(path: TelemetryOptions.databasePath()).allJourneys()
}

/// The subcommands' loading, end to end, against the fixture database.
@Test func loadsRecordsAndDirectoryFromTheDatabase() throws {
    try TelemetryOptions.$databasePathOverride.withValue(fixtureDatabasePath) {
        let options = try TelemetryOptions.parse(["-j", "1"])
        #expect(try options.load().count == 38397)
        #expect(try options.journeyDirectory().hasSuffix("A338 Northbound"))
    }
}

@Test func loadThrowsJourneyNotFoundForAnUnknownJourneyID() throws {
    try TelemetryOptions.$databasePathOverride.withValue(fixtureDatabasePath) {
        let options = try TelemetryOptions.parse(["-j", "999999"])
        do {
            _ = try options.load()
            Issue.record("expected loading an unknown journey to throw")
        } catch TelemetryStoreError.journeyNotFound(let journeyID) {
            #expect(journeyID == 999_999)
        }
    }
}
