import Foundation

/// One window during which the camera slot (top-left of the drive segment)
/// shows a camera other than its default rear view - or the rear view with
/// its own label - stored in the `camera_overrides` table.
///
/// `start`/`end` are seconds from the start of the raw front.mov, before
/// its own start offset is applied: the same convention as annotation
/// offsets, so a side view and the annotation explaining it can be read off
/// the same player.
package struct CameraOverride: Identifiable, Sendable, Equatable {
    /// A camera that can fill the slot. The raw value is the `camera`
    /// column's text.
    package enum Camera: String, Sendable, CaseIterable {
        case rear
        case left
        case right

        /// The slot's label when the override doesn't supply its own.
        package var defaultLabel: String {
            switch self {
            case .rear: "Rear view"
            case .left: "Left view"
            case .right: "Right view"
            }
        }
    }

    package let id: Int64
    package let journeyID: Int64
    package let camera: Camera
    package let start: Double
    package let end: Double
    /// Custom label text; nil means `camera.defaultLabel`.
    package let label: String?

    package init(
        id: Int64, journeyID: Int64, camera: Camera, start: Double, end: Double, label: String?
    ) {
        self.id = id
        self.journeyID = journeyID
        self.camera = camera
        self.start = start
        self.end = end
        self.label = label
    }

    /// The label actually shown.
    package var displayLabel: String { label ?? camera.defaultLabel }

    /// How long a side camera takes to push into (or out of) the slot.
    package static let slideSeconds = 1.0
    /// How long the slot's label takes to pop in (with a slight overshoot)
    /// and to shrink away.
    package static let labelPopSeconds = 0.35
    package static let labelHideSeconds = 0.15

    /// The shortest window that fits the push in, the new label's pop, and
    /// the push back out; shorter windows are skipped when rendering.
    package static var minimumDuration: Double { 2 * slideSeconds + labelPopSeconds }
}
