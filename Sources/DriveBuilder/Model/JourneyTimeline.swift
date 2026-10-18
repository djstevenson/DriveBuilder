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
        /// Likewise for the rear and side cameras' raw footage; a side
        /// camera the journey doesn't have has no clock.
        case rear, left, right
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

    /// When the drive segment reaches `fix`, in drive seconds (negative if
    /// the fix comes before the synced start).
    func driveSeconds(at fix: TrackFix) -> Double {
        fix.telemetrySeconds - startOffsets.telemetry
    }

    /// `seconds` read off `clock`, as drive seconds; nil for a clock the
    /// journey doesn't have (see `start(of:)`).
    func driveSeconds(_ seconds: Double, on clock: Clock) -> Double? {
        start(of: clock).map { seconds - $0 }
    }

    /// `driveSeconds` as read off `clock`; nil for a clock the journey
    /// doesn't have (see `start(of:)`).
    func seconds(_ driveSeconds: Double, on clock: Clock) -> Double? {
        start(of: clock).map { driveSeconds + $0 }
    }

    /// Where the drive segment starts on `clock`: nil for the final clock
    /// while `driveSegmentStart` is unknown, and for a missing side camera.
    func start(of clock: Clock) -> Double? {
        switch clock {
        case .telemetry: startOffsets.telemetry
        case .front: startOffsets.front
        case .rear: startOffsets.rear
        case .left: startOffsets.left
        case .right: startOffsets.right
        case .drive: 0
        case .final: driveSegmentStart
        }
    }

    /// `seconds` read off one clock, as read off another.
    func convert(_ seconds: Double, from source: Clock, to destination: Clock) -> Double? {
        driveSeconds(seconds, on: source).flatMap { self.seconds($0, on: destination) }
    }
}
