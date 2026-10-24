import Foundation

/// One kept stretch of a journey, a row of the `journey_segments` table:
/// the final video plays a journey's segments in `position` order, cutting
/// out whatever happened between them (a break, a traffic stall, a wrong
/// turn).
///
/// Each segment names its own source files, beneath the journey's `video`
/// directory, and the offsets that sync them. Segments may share a file -
/// a rear camera left running through a break is one file, with the later
/// segment's offset further in. The telemetry is one recording for the
/// whole journey, so a segment's telemetry offset picks out its stretch of
/// it, measured from the journey's first sample.
package struct JourneySegment: Sendable, Identifiable, Equatable {
    package let id: Int64
    package let journeyID: Int64
    /// Playback order within the journey, from 0.
    package var position: Int
    package var frontFile: String
    package var rearFile: String
    /// The side cameras' files; only used when `startOffsets` has the
    /// camera's offset, a nil offset meaning the segment has no such view.
    package var leftFile: String
    package var rightFile: String
    package var startOffsets: StartOffsets
    /// The segment's length in seconds from its synced start; nil means it
    /// runs for the shortest of its synced sources.
    package var length: Double?
}
