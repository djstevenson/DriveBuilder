import Foundation

/// Interpolating between consecutive telemetry samples, so a movie can be
/// rendered at a higher frame rate than the underlying 10 Hz telemetry.
extension TelemetryRecord {
    /// Interpolates headings across the 0/360 wrap by the shortest arc.
    static func interpolateHeading(from previous: Double, to current: Double, fraction: Double)
        -> Double
    {
        var delta = current - previous
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        return previous + delta * fraction
    }

    /// A record `fraction` of the way from `previous` to `current`.
    ///
    /// Position, altitude, speed, and acceleration are lerped linearly
    /// (acceleration is nil if either endpoint lacks it); heading takes the
    /// shortest arc across the 0/360 wrap. The speed limit and file don't
    /// vary continuously, so they're carried forward from `previous`.
    static func interpolated(
        from previous: TelemetryRecord, to current: TelemetryRecord, fraction: Double
    ) -> TelemetryRecord {
        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * fraction }
        func lerp(_ a: Double?, _ b: Double?) -> Double? {
            guard let a, let b else { return nil }
            return a + (b - a) * fraction
        }
        return TelemetryRecord(
            id: previous.id,
            journeyID: previous.journeyID,
            timestamp: previous.timestamp.addingTimeInterval(
                current.timestamp.timeIntervalSince(previous.timestamp) * fraction),
            latitude: lerp(previous.latitude, current.latitude),
            longitude: lerp(previous.longitude, current.longitude),
            altitude: lerp(previous.altitude, current.altitude),
            speed: lerp(previous.speed, current.speed),
            heading: interpolateHeading(
                from: previous.heading, to: current.heading, fraction: fraction),
            accelForward: lerp(previous.accelForward, current.accelForward),
            accelLateral: lerp(previous.accelLateral, current.accelLateral),
            speedLimit: previous.speedLimit,
            file: previous.file ?? current.file,
            source: "Interpolated")
    }

    /// Expands `records` to a higher frame rate by inserting
    /// `subframesPerRecord - 1` interpolated records between each
    /// consecutive pair. The original records themselves are always
    /// included unchanged.
    static func subframeSequence(_ records: [TelemetryRecord], subframesPerRecord: Int)
        -> [TelemetryRecord]
    {
        guard subframesPerRecord > 1, !records.isEmpty else { return records }
        var frames: [TelemetryRecord] = []
        frames.reserveCapacity(records.count * subframesPerRecord - (subframesPerRecord - 1))
        var previous: TelemetryRecord?
        for record in records {
            if let previous {
                for step in 1..<subframesPerRecord {
                    let fraction = Double(step) / Double(subframesPerRecord)
                    frames.append(interpolated(from: previous, to: record, fraction: fraction))
                }
            }
            frames.append(record)
            previous = record
        }
        return frames
    }
}
