import AVFoundation
import Foundation
import Synchronization

/// A journey's drive and timeline, for a front end to show when its
/// location-based items (annotations, camera overrides, route-map labels)
/// happen, and to turn a time read off any of its players into a location.
package struct JourneyPlacement: Sendable {
    /// The players a time can be read off.
    package enum Clock: String, CaseIterable, Identifiable, Sendable {
        case final, dials, front, rear, left, right

        package var id: Self { self }

        /// The movie the clock belongs to, for pickers and captions; a
        /// segment's own file for the cameras is `movieName(on:at:)`.
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
        /// Seconds into the drive (dials.mov's clock); the order items
        /// happen in.
        package let driveSeconds: Double
        /// How far the location is from the track, in metres.
        package let distanceMetres: Double
    }

    let track: DriveTrack
    var timeline: JourneyTimeline { track.timeline }
    /// Each location's placement, as found: placing scans the whole track,
    /// and a front end's lists and captions ask again on every redraw.
    private let cache = Cache()

    init(track: DriveTrack) {
        self.track = track
    }

    private final class Cache: Sendable {
        let placements = Mutex<[TrackLocation: Result<Placement, TrackLocatorError>]>([:])
    }

    /// The clocks this journey has: final.mov's only once the intro and
    /// route map have been rendered (their lengths decide where its drive
    /// segment starts), and a side camera's only if a segment has one.
    package var clocks: [Clock] {
        Clock.allCases.filter { timeline.hasClock($0.timelineClock) }
    }

    /// How many segments the drive plays.
    package var segmentCount: Int { timeline.spans.count }

    /// Which segment (from 0) is playing `driveSeconds` into the drive: the
    /// first before the drive starts, the last after it ends.
    package func segmentIndex(atDriveSeconds driveSeconds: Double) -> Int {
        timeline.segmentIndex(atDriveSeconds: driveSeconds)
    }

    /// Whether segment `index` has `clock`: a side camera it has no offset
    /// for doesn't.
    package func segment(_ index: Int, has clock: Clock) -> Bool {
        timeline.start(of: clock.timelineClock, segment: index) != nil
    }

    /// When the track passes `location`, or why it can't be pinned down.
    package func place(_ location: TrackLocation) -> Result<Placement, TrackLocatorError> {
        if let cached = cache.placements.withLock({ $0[location] }) { return cached }
        let result = Result { () throws(TrackLocatorError) in
            let fix = try track.locate(location)
            return Placement(driveSeconds: fix.seconds, distanceMetres: fix.distanceMetres)
        }
        cache.placements.withLock { $0[location] = result }
        return result
    }

    /// `placement` as read off `clock`, in the movie of the segment playing
    /// then (see `movieName(on:at:)`); nil for a clock that segment doesn't
    /// have.
    package func seconds(_ placement: Placement, on clock: Clock) -> Double? {
        timeline.seconds(placement.driveSeconds, on: clock.timelineClock)
    }

    /// The movie `seconds(_:on:)` reads `placement` off: a camera's file in
    /// the segment playing then.
    package func movieName(on clock: Clock, at placement: Placement) -> String {
        let segment = timeline.spans[
            timeline.segmentIndex(atDriveSeconds: placement.driveSeconds)
        ].segment
        return Self.fileName(of: clock, in: segment)
    }

    /// A movie a time can be read off, for a front end's picker: a clock,
    /// and for a camera, which segment's file.
    package struct Movie: Hashable, Identifiable, Sendable {
        package let clock: Clock
        /// An index into the journey's segments; 0 for final.mov and
        /// dials.mov, which run through them all.
        package let segment: Int
        /// The file, with its segment when another segment shares the name
        /// ("rear.mov (segment 2)").
        package let name: String

        package var id: Self { self }
    }

    /// Every movie this journey has: final.mov (once known), dials.mov, and
    /// each segment's camera files.
    package var movies: [Movie] {
        clocks.flatMap { clock -> [Movie] in
            if clock == .final || clock == .dials {
                return [Movie(clock: clock, segment: 0, name: clock.movieName)]
            }
            let files = timeline.spans.indices.compactMap { index -> (Int, String)? in
                guard timeline.start(of: clock.timelineClock, segment: index) != nil else {
                    return nil
                }
                return (index, Self.fileName(of: clock, in: timeline.spans[index].segment))
            }
            return files.map { index, name in
                let isShared = files.filter { $0.1 == name }.count > 1
                return Movie(
                    clock: clock, segment: index,
                    name: isShared ? "\(name) (segment \(index + 1))" : name)
            }
        }
    }

    private static func fileName(of clock: Clock, in segment: JourneySegment) -> String {
        switch clock {
        case .final, .dials: clock.movieName
        case .front: segment.frontFile
        case .rear: segment.rearFile
        case .left: segment.leftFile
        case .right: segment.rightFile
        }
    }

    /// Where the drive was `seconds` into `clock`'s movie in segment
    /// `segment` (which only matters for the cameras); nil for a clock that
    /// segment doesn't have, or a time outside the drive.
    package func location(
        atSeconds seconds: Double, on clock: Clock, segment: Int = 0
    ) -> TrackLocation? {
        timeline.driveSeconds(seconds, on: clock.timelineClock, segment: segment)
            .flatMap { track.location(atDriveSeconds: $0) }
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
    /// A journey's placement: its drive, segments, and - if intro.mov and
    /// route_map.mov have been rendered - where final.mov's drive starts.
    /// Throws if the journey has no telemetry, or its segments can't be
    /// joined.
    @concurrent
    package func placement(journeyID: Int64) async throws -> JourneyPlacement {
        let store = TelemetryStore(path: databasePath)
        let records = try store.records(journeyID: journeyID)
        var driveSegmentStart: Double?

        if let directory = try store.journeyDirectory(journeyID: journeyID) {
            let output = URL(filePath: directory).appending(path: "output")
            if let intro = await Self.duration(of: output.appending(path: "intro.mov")),
                let routeMap = await Self.duration(of: output.appending(path: "route_map.mov"))
            {
                driveSegmentStart =
                    JourneyTimeline.driveSegmentStart(
                        introDuration: intro, routeMapDuration: routeMap,
                        crossFade: CMTime(
                            seconds: FinalVideoComposer.defaultCrossFadeSeconds,
                            preferredTimescale: intro.timescale)
                    ).seconds
            }
        }
        return JourneyPlacement(
            track: try DriveTrack(
                records: records, segments: try store.journeySegments(journeyID: journeyID),
                driveSegmentStart: driveSegmentStart))
    }

    /// The movie's length, or nil if it's missing or unreadable.
    private static func duration(of url: URL) async -> CMTime? {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
            let duration = try? await AVURLAsset(url: url).load(.duration), duration.isNumeric
        else { return nil }
        return duration
    }
}
