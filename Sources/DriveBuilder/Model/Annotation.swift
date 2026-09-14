import Foundation

/// One scrolling annotation banner for a journey, stored in the
/// `annotations` table: `video` names the output movie (written to
/// `output/<video>.mov`), `text` is what scrolls across it, and `offset`
/// says when it should end (seconds from the start of the raw front.mov
/// file, before that file's own start offset is applied), for `final` to
/// place it.
package struct Annotation: Identifiable, Sendable {
    package let id: Int64
    package let journeyID: Int64
    package let video: String
    package let text: String
    package let offset: Double
}
