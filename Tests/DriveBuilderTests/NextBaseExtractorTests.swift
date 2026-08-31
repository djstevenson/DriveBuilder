import Foundation
import Testing

@testable import DriveBuilder

private func sample(
    tick: Int64, latitude: Double = 50, longitude: Double = -1, altitude: Double = 20,
    speed: Double = 30, heading: Double = 0, accelForward: Double? = nil,
    accelLateral: Double? = nil, speedLimit: Int? = nil, file: String? = "clip.MP4",
    source: String = "GPS"
) -> TelemetrySample {
    TelemetrySample(
        tick: tick, latitude: latitude, longitude: longitude, altitude: altitude,
        speed: speed, heading: heading, accelForward: accelForward,
        accelLateral: accelLateral, speedLimit: speedLimit, file: file, source: source)
}

// MARK: - GPS timestamps

@Test func gpsDateTimeSnapsToTheTickGrid() throws {
    let epoch = try Date("2026-07-26T14:37:55Z", strategy: .iso8601).timeIntervalSince1970
    let baseTick = Int64(epoch) * 10

    // On-grid and off-grid fractions round to the nearest tenth.
    #expect(NextBaseExtractor.tick(fromGPSDateTime: "2026:07:26 14:37:55.100Z") == baseTick + 1)
    #expect(NextBaseExtractor.tick(fromGPSDateTime: "2026:07:26 14:37:55.109Z") == baseTick + 1)
    #expect(NextBaseExtractor.tick(fromGPSDateTime: "2026:07:26 14:37:55Z") == baseTick)

    // .95 and above rounds up into the next second.
    #expect(NextBaseExtractor.tick(fromGPSDateTime: "2026:07:26 14:37:55.950Z") == baseTick + 10)

    #expect(NextBaseExtractor.tick(fromGPSDateTime: "not a date") == nil)
}

@Test func timestampFormatsWithoutZoneDesignator() throws {
    let epoch = try Date("2026-07-26T14:37:55Z", strategy: .iso8601).timeIntervalSince1970
    let formatted = sample(tick: Int64(epoch) * 10 + 1).timestamp
    #expect(formatted == "2026-07-26T14:37:55.100")
}

// MARK: - Accelerometer decoding

@Test func decodesAccelerometerGroups() throws {
    // Two groups of six; lateral is axis 4, longitudinal is axis 5.
    let decoded = try #require(Accelerometer.decode("0 0 0 0 100 72 0 0 0 0 80 72"))
    // Mean lateral 90 is exactly the bias; mean longitudinal 72 is
    // (72 + 143.5) / 215 m/s² = 1.00233 m/s² = 0.10217 g.
    #expect(abs(decoded.lateral) < 1e-12)
    #expect(abs(decoded.forward - ((72.0 + 143.5) / 215.0 / 9.81)) < 1e-12)
}

@Test func accelerometerNeedsAFullGroup() {
    #expect(Accelerometer.decode("1 2 3 4 5") == nil)
    #expect(Accelerometer.decode("") == nil)
}

// MARK: - Dedupe and interpolation

@Test func dedupeKeepsTheFirstSamplePerTick() {
    let deduped = NextBaseExtractor.dedupe([
        sample(tick: 1, speed: 10), sample(tick: 1, speed: 99), sample(tick: 2, speed: 20),
    ])
    #expect(deduped.count == 2)
    #expect(deduped[0].speed == 10)
    #expect(deduped[1].tick == 2)
}

@Test func interpolateFillsGapsOnTheTickGrid() {
    let interpolated = NextBaseExtractor.interpolate([
        sample(tick: 103, latitude: 3, speedLimit: 40, file: nil),
        sample(tick: 100, latitude: 0, speedLimit: 30),
    ])

    #expect(interpolated.map(\.tick) == [100, 101, 102, 103])
    #expect(interpolated.map(\.source) == ["GPS", "Interpolated", "Interpolated", "GPS"])
    #expect(abs(interpolated[1].latitude - 1) < 1e-12)
    #expect(abs(interpolated[2].latitude - 2) < 1e-12)
    // Interpolated samples take the earlier sample's limit and either file.
    #expect(interpolated[1].speedLimit == 30)
    #expect(interpolated[1].file == "clip.MP4")
}

@Test func interpolateTakesTheShortWayRoundTheCompass() {
    let interpolated = NextBaseExtractor.interpolate([
        sample(tick: 0, heading: 350),
        sample(tick: 2, heading: 10),
    ])
    #expect(abs(interpolated[1].heading - 360) < 1e-12)
}

@Test func interpolateLeavesAccelerationNilAcrossAGapWithoutIt() {
    let interpolated = NextBaseExtractor.interpolate([
        sample(tick: 0, accelForward: 0.1, accelLateral: 0.2),
        sample(tick: 2),
    ])
    #expect(interpolated[1].accelForward == nil)
    #expect(interpolated[1].accelLateral == nil)
}

// MARK: - Speed limit smoothing

@Test func smoothCorrectsABriefSpeedLimitBlip() {
    let smoothed = NextBaseExtractor.smooth([
        sample(tick: 0, speedLimit: 30),
        sample(tick: 1, speedLimit: 30),
        sample(tick: 2, speedLimit: 40),
        sample(tick: 3, speedLimit: 40),
        sample(tick: 4, speedLimit: 30),
    ])
    #expect(smoothed.map(\.speedLimit) == [30, 30, 30, 30, 30])
}

@Test func smoothKeepsARealSpeedLimitChange() {
    let limits: [Int?] = [30, 30, 40, 40, 40, 30]
    let smoothed = NextBaseExtractor.smooth(
        limits.enumerated().map { sample(tick: Int64($0.offset), speedLimit: $0.element) })
    #expect(smoothed.map(\.speedLimit) == limits)
}
