import ArgumentParser
import Testing

@testable import DriveBuilder

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

/// An end-to-end check that the bundled `telemetry.sqlite3` resource
/// resolves and reads correctly. Journey 1 is the project's checked-in
/// database, so the record count only changes if that data is replaced.
///
/// `journeyDirectory()` records wherever the real footage currently lives
/// on disk (an external drive, a Movies folder, ...), which moves over
/// time, so this only checks the journey identity survives the round trip
/// rather than hardcoding today's location.
@Test func loadsRecordsAndDirectoryFromTheBundledDatabase() throws {
    let options = try TelemetryOptions.parse(["-j", "1"])
    #expect(try options.load().count == 38397)
    #expect(try options.journeyDirectory().hasSuffix("A338 Northbound"))
}

@Test func loadThrowsJourneyNotFoundForAnUnknownJourneyID() throws {
    let options = try TelemetryOptions.parse(["-j", "999999"])
    do {
        _ = try options.load()
        Issue.record("expected loading an unknown journey to throw")
    } catch TelemetryStoreError.journeyNotFound(let journeyID) {
        #expect(journeyID == 999_999)
    }
}
