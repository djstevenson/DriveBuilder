import AppKit
import Foundation
import Testing

@testable import DriveBuilder

private func record(timestamp: Date) -> TelemetryRecord {
    TelemetryRecord(
        id: 1,
        journeyID: 1,
        timestamp: timestamp,
        latitude: 0,
        longitude: 0,
        altitude: 0,
        speed: 0,
        heading: 0,
        accelForward: nil,
        accelLateral: nil,
        speedLimit: nil,
        file: nil,
        source: "test")
}

@Test func handAnglesSweepContinuously() {
    let midnight = ClockFace.handAngles(forSeconds: 0)
    #expect(midnight.hour == 0)
    #expect(midnight.minute == 0)
    #expect(midnight.second == 0)

    // 01:01:01.5 — every hand is partway to its next mark.
    let angles = ClockFace.handAngles(forSeconds: 3661.5)
    #expect(abs(angles.hour - 30.5125) < 0.0001)
    #expect(abs(angles.minute - 6.15) < 0.0001)
    #expect(abs(angles.second - 9) < 0.0001)

    // The hour hand wraps at 12 hours, not 24.
    let afternoon = ClockFace.handAngles(forSeconds: 43_200 + 3_600)
    #expect(abs(afternoon.hour - 30) < 0.0001)
}

@Test func wallClockReadsUTCTimeOfDay() {
    // 09:30:15.25 UTC on an arbitrary day.
    let timestamp = Date(timeIntervalSince1970: 12_345 * 86_400 + 34_215.25)
    let seconds = WallClockRenderer.secondsOfDay(for: record(timestamp: timestamp))
    #expect(abs(seconds - 34_215.25) < 0.000_001)
}

@Test func relativeClockMeasuresFromTheFirstRecord() {
    let start = Date(timeIntervalSince1970: 1_775_000_000)
    let renderer = RelativeClockRenderer(records: [
        record(timestamp: start),
        record(timestamp: start.addingTimeInterval(90.4)),
    ])
    #expect(renderer.elapsedSeconds(for: renderer.records[0]) == 0)
    #expect(abs(renderer.elapsedSeconds(for: renderer.records[1]) - 90.4) < 0.000_001)
}

/// The dial artwork has no red, so red pixels belong to the hands.
private func redHalves(_ frame: NSBitmapImageRep) -> (left: Int, right: Int) {
    let size = frame.pixelsWide
    var left = 0
    var right = 0
    for y in 0..<size {
        for x in 0..<size {
            guard let colour = frame.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                colour.alphaComponent > 0.5,
                colour.redComponent > 0.5,
                colour.greenComponent < 0.35
            else { continue }
            if x < size / 2 { left += 1 } else { right += 1 }
        }
    }
    return (left, right)
}

@Test func hourHandFollowsTheUTCTime() throws {
    let renderer = WallClockRenderer(records: [])
    let artwork = try ClockFace.Artwork(pixelSize: 420)

    // At 03:00 and 09:00 the minute and second hands point straight up,
    // splitting evenly across the centre line; the hour hand tips the
    // balance right or left.
    let three = try renderer.frame(
        for: record(timestamp: Date(timeIntervalSince1970: 3 * 3_600)), artwork: artwork)
    let nine = try renderer.frame(
        for: record(timestamp: Date(timeIntervalSince1970: 9 * 3_600)), artwork: artwork)

    let threeCounts = redHalves(three)
    let nineCounts = redHalves(nine)

    #expect(threeCounts.right > threeCounts.left + 200)
    #expect(nineCounts.left > nineCounts.right + 200)
}

@Test func clockFrameKeepsSizeAndTransparentCorners() throws {
    let renderer = RelativeClockRenderer(records: [], pixelSize: 200)
    let artwork = try ClockFace.Artwork(pixelSize: 200)
    let frame = try renderer.frame(
        for: record(timestamp: .distantPast), artwork: artwork)

    #expect(frame.pixelsWide == 200)
    #expect(frame.pixelsHigh == 200)
    let corner = try #require(frame.colorAt(x: 2, y: 2))
    #expect(corner.alphaComponent < 0.01)
}
