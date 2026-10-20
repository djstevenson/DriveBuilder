import Foundation

enum DriveRecordsError: Error, CustomStringConvertible, Equatable {
    case noSegments
    /// Only the last segment may leave its length to its sources: an
    /// earlier one's length decides where the next starts.
    case openEndedSegment(position: Int)
    /// The segment starts before the one before it ends, which would run
    /// the track backwards.
    case overlappingSegment(position: Int)
    case telemetryTooShort(position: Int, length: Double, available: Double, offset: Double)

    var description: String {
        switch self {
        case .noSegments:
            "The journey has no segments."
        case .openEndedSegment(let position):
            "Segment \(position + 1) has no length; only the last segment may run to the end "
                + "of its sources."
        case .overlappingSegment(let position):
            "Segment \(position + 1)'s telemetry starts before segment \(position)'s ends."
        case .telemetryTooShort(let position, let length, let available, let offset):
            String(
                format: "Segment %d's length is %.1fs, but its telemetry only has %.1fs "
                    + "after the %.1fs telemetry offset.",
                position + 1, length, available, offset)
        }
    }
}

extension TelemetryRecord {
    /// The part of a journey's `records` the final video shows, as one
    /// continuous drive: each segment's stretch of telemetry in turn, with
    /// whatever lies between them cut out.
    ///
    /// The first segment keeps its real timestamps and odometer readings;
    /// each later one is moved back in time to follow straight on from the
    /// one before, and its odometer continues from there (plus the
    /// straight-line distance across the join, which is about nothing when
    /// the drive picks up where it left off). So distances, the route, and
    /// the clock all read as if the cut-out part never happened.
    ///
    /// A segment's stretch starts `startOffsets.telemetry` seconds after the
    /// first sample and runs for its `length`, or to the end of the
    /// telemetry for a last segment with none. Throws if any segment but the
    /// last has no length, if segments overlap, or if the telemetry runs out
    /// before a segment's length.
    static func driveRecords(
        from records: [TelemetryRecord], segments: [JourneySegment]
    ) throws -> [TelemetryRecord] {
        guard let first = records.first, let last = records.last else { return records }
        guard let firstSegment = segments.first else { throw DriveRecordsError.noSegments }

        var drive: [TelemetryRecord] = []
        // Where the next segment starts on the drive clock, which is the
        // telemetry's own clock through the first segment.
        var driveStart = first.timestamp.addingTimeInterval(firstSegment.startOffsets.telemetry)
        var previousEnd: Date?

        for (index, segment) in segments.enumerated() {
            let isLast = index == segments.count - 1
            let offset = segment.startOffsets.telemetry
            let start = first.timestamp.addingTimeInterval(offset)
            if let previousEnd, start < previousEnd {
                throw DriveRecordsError.overlappingSegment(position: segment.position)
            }

            var end: Date?
            if let length = segment.length {
                // The dials clip holds each sample for one sample interval,
                // so the telemetry covers up to that much past its last
                // timestamp.
                let available = last.timestamp.timeIntervalSince(start) + sampleInterval
                guard available >= length else {
                    throw DriveRecordsError.telemetryTooShort(
                        position: segment.position, length: length, available: available,
                        offset: offset)
                }
                end = start.addingTimeInterval(length)
            } else if !isLast {
                throw DriveRecordsError.openEndedSegment(position: segment.position)
            }

            // Each segment but the last stops short of its end, where the
            // next one's first sample takes over.
            let kept = records.filter { record in
                guard record.timestamp >= start else { return false }
                guard let end else { return true }
                return isLast ? record.timestamp <= end : record.timestamp < end
            }
            // Zero for the first segment, which keeps its real readings.
            let timeShift = driveStart.timeIntervalSince(start)
            var odometerShift = 0.0
            if let joinFrom = drive.last, let joinTo = kept.first {
                let gap = TelemetrySample.haversineMetres(
                    latitude1: joinFrom.latitude, longitude1: joinFrom.longitude,
                    latitude2: joinTo.latitude, longitude2: joinTo.longitude)
                odometerShift = joinFrom.odometer + gap - joinTo.odometer
            }
            drive += kept.map { $0.moved(by: timeShift, odometerBy: odometerShift) }

            driveStart = driveStart.addingTimeInterval(segment.length ?? 0)
            previousEnd = end
        }
        return drive
    }

    /// The same sample, `seconds` later and `metres` further on.
    private func moved(by seconds: TimeInterval, odometerBy metres: Double) -> TelemetryRecord {
        TelemetryRecord(
            id: id, journeyID: journeyID, timestamp: timestamp.addingTimeInterval(seconds),
            latitude: latitude, longitude: longitude, altitude: altitude, speed: speed,
            heading: heading, accelForward: accelForward, accelLateral: accelLateral,
            speedLimit: speedLimit, file: file, source: source, odometer: odometer + metres)
    }
}
