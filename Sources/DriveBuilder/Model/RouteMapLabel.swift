import Foundation

/// One road-sign placard on the route map, stored in the
/// `route_map_labels` table: revealed as the animated track reaches
/// `offset` (seconds from the start of the telemetry) and left up
/// thereafter. `location` and `distance` position it relative to that
/// track point; a nil `distance` means the renderer's default gap.
package struct RouteMapLabel: Identifiable, Sendable {
    /// Which side of the track point the sign sits on.
    package enum Location: String, Sendable, CaseIterable {
        case left
        case right
    }

    package let id: Int64
    package let journeyID: Int64
    package let offset: Double
    package let title: String
    package let subtitle: String
    package let location: Location
    package let distance: Double?
}
