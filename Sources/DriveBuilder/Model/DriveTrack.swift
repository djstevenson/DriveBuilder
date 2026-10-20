import Foundation

/// A journey's track as the final video shows it - its segments' telemetry
/// joined into one drive (see `TelemetryRecord.driveRecords(from:segments:)`)
/// - for placing location-based items on, with the timeline to read their
/// times off any clock.
///
/// Locating on the drive rather than the whole recording means a stretch
/// cut out between segments can't make a location ambiguous: a wrong turn
/// that doubles back past a place no longer passes it twice. The recording
/// before the first segment and after the last stays, as lead-in and
/// run-out, so an item there (a route-map label at the very first sample,
/// say) places outside the drive's 0...end as it did before segments.
struct DriveTrack: Sendable {
    let timeline: JourneyTimeline
    /// The drive with its lead-in and run-out, its fixes' seconds being
    /// drive seconds.
    private let drive: TrackLocator
    /// The whole recording, to tell a location only passed between
    /// segments from one off the route altogether.
    private let wholeTrack: TrackLocator

    /// `records` is the journey's whole track and `segments` its segments
    /// in playback order. Throws if the segments can't be joined.
    init(
        records: [TelemetryRecord], segments: [JourneySegment],
        driveSegmentStart: Double? = nil
    ) throws {
        let driveRecords = try TelemetryRecord.driveRecords(
            from: records, segments: segments, keepingEnds: true)
        // The drive starts at the first segment's telemetry offset, which
        // keeps its real timestamps.
        let origin = records.first?.timestamp.addingTimeInterval(
            segments.first?.startOffsets.telemetry ?? 0)
        drive = TrackLocator(records: driveRecords, origin: origin)
        wholeTrack = TrackLocator(records: records)
        timeline = JourneyTimeline(segments: segments, driveSegmentStart: driveSegmentStart)
    }

    /// When the drive passes `location`. A location only passed between
    /// segments throws `cutOut` rather than `tooFar`.
    func locate(_ location: TrackLocation) throws(TrackLocatorError) -> TrackFix {
        do {
            return try drive.locate(location)
        } catch .tooFar(let nearest, let threshold) {
            if wholeTrackPasses(location) { throw .cutOut }
            throw .tooFar(nearestMetres: nearest, thresholdMetres: threshold)
        }
    }

    /// Where the drive was `driveSeconds` in; nil outside the recording.
    func location(atDriveSeconds driveSeconds: Double) -> TrackLocation? {
        drive.location(atSeconds: driveSeconds)
    }

    private func wholeTrackPasses(_ location: TrackLocation) -> Bool {
        do {
            _ = try wholeTrack.locate(location)
            return true
        } catch .ambiguous {
            return true
        } catch {
            return false
        }
    }
}
