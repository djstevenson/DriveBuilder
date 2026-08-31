import AppKit
import CoreGraphics
import Foundation

/// The analogue clock face shared by the wall and relative clocks: a static
/// dial with hour, minute, and second hands swept continuously from a single
/// seconds value.
enum ClockFace {
    /// Hand angles in degrees for a time expressed in seconds. All three
    /// hands sweep continuously rather than tick: the hour hand covers the
    /// 12-hour dial, and fractional seconds move the second hand.
    static func handAngles(forSeconds seconds: Double)
        -> (hour: Double, minute: Double, second: Double)
    {
        (
            hour: seconds.truncatingRemainder(dividingBy: 43_200) / 120,
            minute: seconds.truncatingRemainder(dividingBy: 3_600) / 10,
            second: seconds.truncatingRemainder(dividingBy: 60) * 6
        )
    }

    /// Artwork rasterized once and reused for every frame. The hands are
    /// drawn pointing at 12 and rotated per frame.
    struct Artwork {
        let dial: CGImage
        let hour: CGImage
        let minute: CGImage
        let second: CGImage

        init(pixelSize: Int) throws {
            func layer(_ name: String) throws -> CGImage {
                let bitmap = try SVGRasterizer.bitmap(
                    from: BundledArtwork.svg(name, dial: "clock"),
                    width: pixelSize,
                    height: pixelSize)
                guard let image = bitmap.cgImage else {
                    throw SVGRasterizerError.undecodableArtwork
                }
                return image
            }

            dial = try layer("dial")
            hour = try layer("hour")
            minute = try layer("minute")
            second = try layer("second")
        }
    }

    static func draw(seconds: Double, into context: CGContext, artwork: Artwork, pixelSize: Int) {
        let angles = handAngles(forSeconds: seconds)
        LayerCompositor.draw(
            [
                .init(artwork.dial),
                .init(artwork.hour, rotationDegrees: angles.hour),
                .init(artwork.minute, rotationDegrees: angles.minute),
                .init(artwork.second, rotationDegrees: angles.second),
            ],
            into: context, width: pixelSize, height: pixelSize)
    }
}

/// Builds the wall clock for a journey, showing the time of day in UTC.
struct WallClockRenderer: DialRenderer {
    static let dialName = "WallClock"

    let records: [TelemetryRecord]

    /// Edge length of the rendered frame, in pixels.
    var pixelSize = 420

    /// Seconds since midnight UTC. The Unix epoch is midnight UTC, so the
    /// remainder of a day gives the UTC time of day directly.
    static func secondsOfDay(for record: TelemetryRecord) -> Double {
        record.timestamp.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400)
    }

    func makeArtwork() throws -> ClockFace.Artwork {
        try ClockFace.Artwork(pixelSize: pixelSize)
    }

    func draw(_ record: TelemetryRecord, into context: CGContext, artwork: ClockFace.Artwork) {
        ClockFace.draw(
            seconds: Self.secondsOfDay(for: record),
            into: context, artwork: artwork, pixelSize: pixelSize)
    }

    func summaryLines(artwork: ClockFace.Artwork, frameCount: Int, concurrency: Int) -> [String] {
        guard let first = records.first?.timestamp,
            let last = records.prefix(frameCount).last?.timestamp
        else {
            return ["  \(concurrency)-way compositing"]
        }
        let clock = Date.FormatStyle(timeZone: .gmt)
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
        return [
            "  \(first.formatted(clock))-\(last.formatted(clock)) UTC, "
                + "\(concurrency)-way compositing"
        ]
    }
}

/// Builds the relative clock for a journey, showing time elapsed since the
/// first telemetry record.
struct RelativeClockRenderer: DialRenderer {
    static let dialName = "RelativeClock"

    let records: [TelemetryRecord]

    /// Edge length of the rendered frame, in pixels.
    var pixelSize = 420

    /// The journey's start; elapsed time is measured from here.
    let baseTime: Date

    init(records: [TelemetryRecord], pixelSize: Int = 420) {
        self.records = records
        self.pixelSize = pixelSize
        self.baseTime = records.first?.timestamp ?? .distantPast
    }

    func elapsedSeconds(for record: TelemetryRecord) -> Double {
        record.timestamp.timeIntervalSince(baseTime)
    }

    func makeArtwork() throws -> ClockFace.Artwork {
        try ClockFace.Artwork(pixelSize: pixelSize)
    }

    func draw(_ record: TelemetryRecord, into context: CGContext, artwork: ClockFace.Artwork) {
        ClockFace.draw(
            seconds: elapsedSeconds(for: record),
            into: context, artwork: artwork, pixelSize: pixelSize)
    }

    func summaryLines(artwork: ClockFace.Artwork, frameCount: Int, concurrency: Int) -> [String] {
        let total = records.prefix(frameCount).last.map(elapsedSeconds(for:)) ?? 0
        return [
            String(format: "  %.1f s of journey, %d-way compositing", total, concurrency)
        ]
    }
}
