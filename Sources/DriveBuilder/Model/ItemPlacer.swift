import Foundation

/// Places a journey's location-based items (annotations, camera overrides,
/// route-map labels) on its drive segment: finds when the whole recorded
/// track passes each location, then shifts that onto the synced timeline.
struct ItemPlacer {
    let locator: TrackLocator
    let timeline: JourneyTimeline

    /// `records` should be the journey's whole track, not the synced trim,
    /// so a location's time doesn't depend on the sync offsets or length.
    init(store: TelemetryStore, journeyID: Int64, records: [TelemetryRecord]) throws {
        locator = TrackLocator(records: records)
        timeline = JourneyTimeline(
            startOffsets: try store.journeyStartOffsets(journeyID: journeyID) ?? StartOffsets())
    }

    /// Drive seconds at which the track passes `location`. Throws, naming
    /// `item`, if it's off the track or passed more than once.
    func driveSeconds(at location: TrackLocation, for item: String) throws -> Double {
        do {
            return timeline.driveSeconds(at: try locator.locate(location))
        } catch {
            throw RenderSetupError(message: "\(item) at \(location.text): \(error)")
        }
    }
}
