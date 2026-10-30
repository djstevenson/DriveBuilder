import Foundation

/// One road-sign placard on the route map, stored in the
/// `route_map_labels` table: revealed as the animated track reaches
/// `revealLocation` and left up thereafter. `location` and `distance`
/// position it relative to that track point; a nil `distance` means the
/// renderer's default gap.
package struct RouteMapLabel: Identifiable, Sendable {
    /// Which side of the track point the sign sits on (above/below for
    /// `top`/`bottom`, horizontally centred on the point).
    package enum Location: String, Sendable, CaseIterable {
        case left
        case right
        case top
        case bottom
    }

    package let id: Int64
    package let journeyID: Int64
    package let revealLocation: TrackLocation
    package let title: String
    package let subtitle: String
    package let location: Location
    package let distance: Double?
}
