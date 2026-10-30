import Foundation

/// One road-sign placard on the route map, stored in the
/// `route_map_labels` table: revealed as the animated track reaches
/// `revealLocation` and left up thereafter. `location` and `distance`
/// position it relative to that track point; a nil `distance` means the
/// renderer's default gap.
package struct RouteMapLabel: Identifiable, Sendable {
    /// Where the sign sits relative to the track point, as a compass
    /// direction (the map is north-up). The cardinal points centre the sign
    /// on that side; the intercardinal points put it off a corner, with the
    /// connector leaving from the sign's nearest corner.
    package enum Location: String, Sendable, CaseIterable {
        case n
        case ne
        case e
        case se
        case s
        case sw
        case w
        case nw
    }

    package let id: Int64
    package let journeyID: Int64
    package let revealLocation: TrackLocation
    package let title: String
    package let subtitle: String
    package let location: Location
    package let distance: Double?
}
