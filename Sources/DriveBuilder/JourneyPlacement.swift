import AVFoundation
import Foundation
import Synchronization

/// A journey's track and timeline, for a front end to show when its
/// location-based items (annotations, camera overrides, route-map labels)
/// happen, and to turn a time read off any of its players into a location.
package struct JourneyPlacement: Sendable {
    /// The players a time can be read off.
    package enum Clock: String, CaseIterable, Identifiable, Sendable {
        case final, dials, front, rear, left, right

        package var id: Self { self }

        /// The movie the clock belongs to, for pickers and captions.
        package var movieName: String {
            switch self {
            case .final: "final.mov"
            case .dials: "dials.mov"
            case .front: "front.mov"
            case .rear: "rear.mov"
            case .left: "left.mov"
            case .right: "right.mov"
            }
        }

        fileprivate var timelineClock: JourneyTimeline.Clock {
            switch self {
            case .final: .final
            case .dials: .drive
            case .front: .front
            case .rear: .rear
            case .left: .left
            case .right: .right
            }
        }
    }

    /// When the track passes a location.
    package struct Placement: Sendable, Equatable {
        /// Seconds into the synced drive segment (dials.mov's clock); the
        /// order items happen in.
        package let driveSeconds: Double
        /// How far the location is from the track, in metres.
        package let distanceMetres: Double
    }

    let locator: TrackLocator
    let timeline: JourneyTimeline
    /// Each location's placement, as found: placing scans the whole track,
    /// and a front end's lists and captions ask again on every redraw.
    private let cache = Cache()

    init(locator: TrackLocator, timeline: JourneyTimeline) {
        self.locator = locator
        self.timeline = timeline
    }

    private final class Cache: Sendable {
        let placements = Mutex<[TrackLocation: Result<Placement, TrackLocatorError>]>([:])
    }

    /// The clocks this journey has: final.mov's only once the intro and
    /// route map have been rendered (their lengths decide where its drive
    /// segment starts), and a side camera's only if the journey has one.
    package var clocks: [Clock] {
        Clock.allCases.filter { timeline.start(of: $0.timelineClock) != nil }
    }

    /// When the track passes `location`, or why it can't be pinned down.
    package func place(_ location: TrackLocation) -> Result<Placement, TrackLocatorError> {
        if let cached = cache.placements.withLock({ $0[location] }) { return cached }
        let result = Result { () throws(TrackLocatorError) in
            let fix = try locator.locate(location)
            return Placement(
                driveSeconds: timeline.driveSeconds(at: fix), distanceMetres: fix.distanceMetres)
        }
        cache.placements.withLock { $0[location] = result }
        return result
    }

    /// `placement` as read off `clock`; nil for a clock the journey doesn't
    /// have.
    package func seconds(_ placement: Placement, on clock: Clock) -> Double? {
        timeline.seconds(placement.driveSeconds, on: clock.timelineClock)
    }

    /// Where the track was `seconds` into `clock`'s movie; nil for a clock
    /// the journey doesn't have, or a time outside the recorded track.
    package func location(atSeconds seconds: Double, on clock: Clock) -> TrackLocation? {
        timeline.convert(seconds, from: clock.timelineClock, to: .telemetry)
            .flatMap { locator.location(atTelemetrySeconds: $0) }
    }

    /// `items` in the order the track passes their locations; any that
    /// can't be placed go last, in their original order.
    package func sorted<Item>(
        _ items: [Item], by location: (Item) -> TrackLocation
    ) -> [Item] {
        let keyed = items.enumerated().map { index, item in
            (item, index, try? place(location(item)).get().driveSeconds)
        }
        return keyed.sorted { a, b in
            switch (a.2, b.2) {
            case let (x?, y?): x < y || (x == y && a.1 < b.1)
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): a.1 < b.1
            }
        }
        .map(\.0)
    }
}

extension JourneyLibrary {
    /// A journey's placement: its whole track, sync offsets, and - if
    /// intro.mov and route_map.mov have been rendered - where final.mov's
    /// drive segment starts. Throws if the journey has no telemetry.
    @concurrent
    package func placement(journeyID: Int64) async throws -> JourneyPlacement {
        let store = TelemetryStore(path: databasePath)
        let records = try store.records(journeyID: journeyID)
        var timeline = JourneyTimeline(
            startOffsets: try store.journeyStartOffsets(journeyID: journeyID) ?? StartOffsets())

        if let directory = try store.journeyDirectory(journeyID: journeyID) {
            let output = URL(filePath: directory).appending(path: "output")
            if let intro = await Self.duration(of: output.appending(path: "intro.mov")),
                let routeMap = await Self.duration(of: output.appending(path: "route_map.mov"))
            {
                timeline.driveSegmentStart =
                    JourneyTimeline.driveSegmentStart(
                        introDuration: intro, routeMapDuration: routeMap,
                        crossFade: CMTime(
                            seconds: FinalVideoComposer.defaultCrossFadeSeconds,
                            preferredTimescale: intro.timescale)
                    ).seconds
            }
        }
        return JourneyPlacement(locator: TrackLocator(records: records), timeline: timeline)
    }

    /// The movie's length, or nil if it's missing or unreadable.
    private static func duration(of url: URL) async -> CMTime? {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
            let duration = try? await AVURLAsset(url: url).load(.duration), duration.isNumeric
        else { return nil }
        return duration
    }
}
