import Foundation

/// One scrolling annotation banner for a journey, stored in the
/// `annotations` table: `video` names the output movie (written to
/// `output/<video>.mov`), `text` is what scrolls across it, and
/// `endLocation` is where the journey should be as the banner finishes,
/// for `final` to place it by when the track passes there.
package struct Annotation: Identifiable, Sendable {
    package let id: Int64
    package let journeyID: Int64
    package let video: String
    package let text: String
    package let endLocation: TrackLocation
}
