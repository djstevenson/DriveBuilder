import Testing

@testable import DriveBuilder

@Test func clockTimeParsesClockAndPlainSeconds() {
    #expect(ClockTime.seconds(from: "25:03") == 1503)
    #expect(ClockTime.seconds(from: " 1:02:03.5 ") == 3723.5)
    #expect(ClockTime.seconds(from: "1503.5") == 1503.5)
    #expect(ClockTime.seconds(from: "0:07") == 7)
    // Seconds past 59 only make sense without a clock.
    #expect(ClockTime.seconds(from: "90") == 90)
    #expect(ClockTime.seconds(from: "1:75") == nil)
    #expect(ClockTime.seconds(from: "1:60:00") == nil)
    #expect(ClockTime.seconds(from: "") == nil)
    #expect(ClockTime.seconds(from: "abc") == nil)
    #expect(ClockTime.seconds(from: "-5") == nil)
    #expect(ClockTime.seconds(from: "1:2:3:4") == nil)
}

@Test func clockTimeFormatsLikeAPlayer() {
    #expect(ClockTime.text(for: 1503) == "25:03")
    #expect(ClockTime.text(for: 1503.25) == "25:03.3")
    #expect(ClockTime.text(for: 7) == "0:07")
    #expect(ClockTime.text(for: 3723.5) == "1:02:03.5")
    // Round-trips.
    #expect(ClockTime.seconds(from: ClockTime.text(for: 1503.5)) == 1503.5)
}
