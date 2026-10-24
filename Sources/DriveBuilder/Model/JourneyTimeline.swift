import CoreMedia
import Foundation

/// Converts a moment of a journey between the clocks it can be read off,
/// using its segments' sync offsets: the one place those conversions live,
/// so the renderers and Studio agree on them.
///
/// Everything pivots on drive seconds - time into the drive, the journey's
/// segments played one after another with whatever lay between them cut
/// out (see `TelemetryRecord.driveRecords(from:segments:)`). The drive and
/// final.mov run straight through every segment; each source's own clock
/// (and the raw telemetry's) belongs to one segment at a time, since a
/// segment starts its sources at its own offsets.
struct JourneyTimeline: Sendable {
    /// The clocks a time can be read off.
    enum Clock: Sendable, CaseIterable {
        /// Seconds since the journey's first telemetry sample, before any
        /// telemetry offset.
        case telemetry
        /// Seconds into a segment's raw front footage, before its start
        /// offset: what a player showing that file reads.
        case front
        /// Likewise for the rear and side cameras' raw footage; a side
        /// camera a segment doesn't have has no clock in that segment.
        case rear, left, right
        /// Seconds into the drive.
        case drive
        /// Seconds into final.mov, after the intro and route map.
        case final
    }

    /// One segment's place on the drive.
    struct Span: Sendable, Equatable {
        /// Drive seconds at which the segment starts.
        let driveStart: Double
        let segment: JourneySegment
    }

    /// The journey's segments in playback order; never empty.
    let spans: [Span]
    /// Seconds into final.mov at which the drive starts (see
    /// `driveSegmentStart(introDuration:routeMapDuration:crossFade:)`); nil
    /// while those clips' lengths aren't known, which leaves the final
    /// clock unavailable.
    var driveSegmentStart: Double?

    /// `segments` must be in playback order; each starts on the drive where
    /// the one before it ends. A journey with no segments is treated as one
    /// with no offsets.
    init(segments: [JourneySegment], driveSegmentStart: Double? = nil) {
        var driveStart = 0.0
        var spans: [Span] = []
        for segment in segments {
            spans.append(Span(driveStart: driveStart, segment: segment))
            driveStart += segment.length ?? 0
        }
        self.spans = spans.isEmpty ? [Span(driveStart: 0, segment: .single())] : spans
        self.driveSegmentStart = driveSegmentStart
    }

    /// A journey of one segment with these offsets.
    init(startOffsets: StartOffsets, driveSegmentStart: Double? = nil) {
        self.init(
            segments: [.single(startOffsets: startOffsets)], driveSegmentStart: driveSegmentStart)
    }

    /// Where final.mov's drive starts: the intro, then the route map, each
    /// overlapping its successor by one cross-fade.
    static func driveSegmentStart(
        introDuration: CMTime, routeMapDuration: CMTime, crossFade: CMTime
    ) -> CMTime {
        introDuration - crossFade + routeMapDuration - crossFade
    }

    /// Which segment (an index into `spans`) is playing `driveSeconds` into
    /// the drive: the first before the drive starts, the last after it ends.
    func segmentIndex(atDriveSeconds driveSeconds: Double) -> Int {
        spans.lastIndex { $0.driveStart <= driveSeconds } ?? 0
    }

    /// `seconds` read off `clock` in segment `segment` (an index into
    /// `spans`; it only matters for the per-segment clocks), as drive
    /// seconds; nil for a clock the segment doesn't have (see `start(of:)`).
    func driveSeconds(_ seconds: Double, on clock: Clock, segment: Int = 0) -> Double? {
        start(of: clock, segment: segment).map { seconds - $0 + spans[segment].driveStart }
    }

    /// `driveSeconds` as read off `clock`, in the segment playing then; nil
    /// for a clock that segment doesn't have (see `start(of:)`).
    func seconds(_ driveSeconds: Double, on clock: Clock) -> Double? {
        let segment = segmentIndex(atDriveSeconds: driveSeconds)
        return start(of: clock, segment: segment).map {
            driveSeconds - spans[segment].driveStart + $0
        }
    }

    /// Where segment `segment` (an index into `spans`) starts on `clock`:
    /// nil for the final clock while `driveSegmentStart` is unknown, and for
    /// a side camera the segment doesn't have.
    func start(of clock: Clock, segment: Int = 0) -> Double? {
        let span = spans[segment]
        let offsets = span.segment.startOffsets
        return switch clock {
        case .telemetry: offsets.telemetry
        case .front: offsets.front
        case .rear: offsets.rear
        case .left: offsets.left
        case .right: offsets.right
        case .drive: span.driveStart
        case .final: driveSegmentStart.map { $0 + span.driveStart }
        }
    }

    /// Whether any segment has `clock`.
    func hasClock(_ clock: Clock) -> Bool {
        spans.indices.contains { start(of: clock, segment: $0) != nil }
    }

    /// `seconds` read off one clock in segment `segment`, as read off
    /// another (in whichever segment is playing then).
    func convert(
        _ seconds: Double, from source: Clock, segment: Int = 0, to destination: Clock
    ) -> Double? {
        driveSeconds(seconds, on: source, segment: segment).flatMap {
            self.seconds($0, on: destination)
        }
    }
}

extension JourneySegment {
    /// A journey's only segment, over the default files, when there's no
    /// stored row to read it from.
    static func single(startOffsets: StartOffsets = StartOffsets()) -> JourneySegment {
        JourneySegment(
            id: 0, journeyID: 0, position: 0, frontFile: "front.mov", rearFile: "rear.mov",
            leftFile: "left.mov", rightFile: "right.mov", startOffsets: startOffsets, length: nil)
    }
}
