import Foundation

/// Places a journey's location-based items (annotations, camera overrides,
/// route-map labels) on its drive: when the drive passes each location
/// (see `DriveTrack`).
struct ItemPlacer {
    let track: DriveTrack

    /// `records` should be the journey's whole track, not the synced trim:
    /// the journey's segments pick the drive out of it.
    init(store: TelemetryStore, journeyID: Int64, records: [TelemetryRecord]) throws {
        track = try DriveTrack(
            records: records, segments: try store.journeySegments(journeyID: journeyID))
    }

    /// Drive seconds at which the drive passes `location`. Throws, naming
    /// `item`, if it's off the track, passed more than once, or only passed
    /// where the video doesn't show.
    func driveSeconds(at location: TrackLocation, for item: String) throws -> Double {
        do {
            return try track.locate(location).seconds
        } catch {
            throw RenderSetupError(message: "\(item) at \(location.text): \(error)")
        }
    }
}
