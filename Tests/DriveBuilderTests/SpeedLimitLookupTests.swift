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
