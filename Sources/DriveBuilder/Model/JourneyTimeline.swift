import CoreMedia
import Foundation

/// Converts a moment of a journey between the clocks it can be read off,
/// using the journey's sync offsets: the one place those conversions live,
/// so the renderers and Studio agree on them.
///
/// Everything pivots on drive seconds - time into the synced drive segment,
/// where every source has skipped its own start offset.
struct JourneyTimeline: Sendable {
    /// The clocks a time can be read off.
    enum Clock: Sendable, CaseIterable {
        /// Seconds since the journey's first telemetry sample, before the
        /// telemetry offset: what `TrackFix.telemetrySeconds` measures.
        case telemetry
        /// Seconds into the raw front.mov, before its start offset: what a
        /// player showing the front footage reads.
        case front
        /// Seconds into the synced drive segment.
        case drive
        /// Seconds into final.mov, after the intro and route map.
        case final
    }

    var startOffsets: StartOffsets
    /// Seconds into final.mov at which the drive segment starts (see
    /// `driveSegmentStart(introDuration:routeMapDuration:crossFade:)`); nil
    /// while those clips' lengths aren't known, which leaves the final
    /// clock unavailable.
    var driveSegmentStart: Double?

    init(startOffsets: StartOffsets, driveSegmentStart: Double? = nil) {
        self.startOffsets = startOffsets
        self.driveSegmentStart = driveSegmentStart
    }

    /// Where final.mov's drive segment starts: the intro, then the route
    /// map, each overlapping its successor by one cross-fade.
    static func driveSegmentStart(
        introDuration: CMTime, routeMapDuration: CMTime, crossFade: CMTime
    ) -> CMTime {
        introDuration - crossFade + routeMapDuration - crossFade
    }

    /// `seconds` read off `clock`, as drive seconds; nil for the final
    /// clock while `driveSegmentStart` is unknown.
    func driveSeconds(_ seconds: Double, on clock: Clock) -> Double? {
        switch clock {
        case .telemetry: seconds - startOffsets.telemetry
        case .front: seconds - startOffsets.front
        case .drive: seconds
        case .final: driveSegmentStart.map { seconds - $0 }
        }
    }

    /// `driveSeconds` as read off `clock`; nil for the final clock while
    /// `driveSegmentStart` is unknown.
    func seconds(_ driveSeconds: Double, on clock: Clock) -> Double? {
        switch clock {
        case .telemetry: driveSeconds + startOffsets.telemetry
        case .front: driveSeconds + startOffsets.front
        case .drive: driveSeconds
        case .final: driveSegmentStart.map { driveSeconds + $0 }
        }
    }

    /// `seconds` read off one clock, as read off another.
    func convert(_ seconds: Double, from source: Clock, to destination: Clock) -> Double? {
        driveSeconds(seconds, on: source).flatMap { self.seconds($0, on: destination) }
    }
}
