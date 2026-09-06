import Testing

@testable import DriveBuilder

@Test func parsesPlainAndMphMaxspeeds() {
    #expect(SpeedLimitLookup.parseMaxspeed("30 mph") == 30)
    #expect(SpeedLimitLookup.parseMaxspeed("50") == 50)
    #expect(SpeedLimitLookup.parseMaxspeed("  40 MPH ") == 40)
}

@Test func parsesNationalSpeedLimitTags() {
    #expect(SpeedLimitLookup.parseMaxspeed("GB:nsl_restricted") == 30)
    #expect(SpeedLimitLookup.parseMaxspeed("gb:nsl_single") == 60)
    #expect(SpeedLimitLookup.parseMaxspeed("gb:nsl_dual") == 70)
    #expect(SpeedLimitLookup.parseMaxspeed("none") == 70)
}

@Test func unparsableMaxspeedsAreNil() {
    #expect(SpeedLimitLookup.parseMaxspeed("") == nil)
    #expect(SpeedLimitLookup.parseMaxspeed("walk") == nil)
    #expect(SpeedLimitLookup.parseMaxspeed("30 km/h") == nil)
}

// MARK: - SQL construction

@Test func sqlLiteralFormatsFiniteValuesAsPlainFixedPointNumbers() {
    #expect(SpeedLimitLookup.sqlLiteral(51.5) == "51.5000000000")
    #expect(SpeedLimitLookup.sqlLiteral(-1.25) == "-1.2500000000")
    #expect(SpeedLimitLookup.sqlLiteral(0) == "0.0000000000")
    // Large enough that Double's default description would use scientific
    // notation ("1e+300") - still a plain decimal here.
    #expect(SpeedLimitLookup.sqlLiteral(1e300)?.contains("e") == false)
}

@Test func sqlLiteralRejectsNonFiniteValues() {
    #expect(SpeedLimitLookup.sqlLiteral(.nan) == nil)
    #expect(SpeedLimitLookup.sqlLiteral(.infinity) == nil)
    #expect(SpeedLimitLookup.sqlLiteral(-.infinity) == nil)
}

@Test func sqlEmbedsFiniteCoordinatesAsAScalarSubquery() {
    let sql = SpeedLimitLookup.sql(forLatitude: 51.5, longitude: -1.25)
    #expect(sql.contains("ST_MakePoint(-1.2500000000, 51.5000000000)"))
    #expect(sql.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(";"))
}

/// A non-finite coordinate - which should never happen from real GPS data,
/// but could from a parsing bug - degrades to a harmless literal `NULL`
/// instead of ever reaching the query text, so it can't break the SQL.
@Test func sqlFallsBackToLiteralNullForNonFiniteCoordinates() {
    #expect(SpeedLimitLookup.sql(forLatitude: .nan, longitude: -1.25) == "SELECT NULL;\n\n")
    #expect(SpeedLimitLookup.sql(forLatitude: 51.5, longitude: .infinity) == "SELECT NULL;\n\n")
}
