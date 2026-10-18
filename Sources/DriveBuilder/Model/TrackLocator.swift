import Foundation

/// Where a journey's recorded track passes a `TrackLocation`.
package struct TrackFix: Sendable, Equatable {
    /// Seconds since the journey's first telemetry sample (before the
    /// telemetry offset is applied), interpolated between samples.
    package let telemetrySeconds: Double
    /// The sample at the start of the track segment the fix lies on, and
    /// how far along that segment (0...1) towards the next sample.
    package let sampleIndex: Int
    package let fraction: Double
    /// How far the location is from the track, in metres.
    package let distanceMetres: Double
    /// The journey's odometer at the fix, in metres.
    package let odometerMetres: Double
}

/// Why a location couldn't be pinned to a single moment of the journey.
package enum TrackLocatorError: Error, Equatable, CustomStringConvertible {
    /// The journey has no telemetry.
    case emptyTrack
    /// The track never comes within `thresholdMetres`: usually a typo or a
    /// pin on the wrong road.
    case tooFar(nearestMetres: Double, thresholdMetres: Double)
    /// The track passes within the threshold more than once (a roundabout,
    /// a bridge over the route, an out-and-back drive), at these telemetry
    /// seconds.
    case ambiguous(telemetrySeconds: [Double])

    package var description: String {
        switch self {
        case .emptyTrack:
            "The journey has no telemetry to find the location on."
        case .tooFar(let nearest, let threshold):
            String(
                format: "The track never comes within %.0f m of the location (nearest %.0f m).",
                threshold, nearest)
        case .ambiguous(let seconds):
            "The track passes the location more than once, at telemetry "
                + seconds.map { ClockTime.text(for: $0) }.joined(separator: ", ")
                + "; move it to a point passed only once."
        }
    }
}

/// Finds when a journey passed a location: the closest approach of its
/// recorded track, treated as straight lines between consecutive samples so
/// a pin between two 10 Hz fixes still gets a sub-sample time.
struct TrackLocator {
    /// How close the track must come for a location to count as on it:
    /// generous enough for GPS error and for a pin dropped on the road's
    /// centreline rather than the lane driven.
    static let defaultThresholdMetres = 30.0
    /// Two stretches of track within the threshold this far apart (by
    /// odometer) are separate passes rather than GPS jitter about one.
    static let distinctPassMetres = 200.0
    /// While the car sits near a location (queuing, say), the fix walks
    /// back from the closest approach over segments shorter than
    /// `stationaryStepMetres` (under about 4 mph at 10 Hz) that stay within
    /// `arrivalToleranceMetres` of it, so it marks arriving rather than
    /// wherever the GPS jitter happened to dip. A moving pass is untouched.
    static let arrivalToleranceMetres = 1.0
    static let stationaryStepMetres = 0.2

    let records: [TelemetryRecord]
    var thresholdMetres = defaultThresholdMetres

    func locate(_ location: TrackLocation) throws(TrackLocatorError) -> TrackFix {
        guard !records.isEmpty else { throw .emptyTrack }
        let plane = LocalPlane(origin: location)

        // Each segment's closest point to the location; a lone sample is a
        // segment of zero length.
        let fixes = (0..<max(records.count - 1, 1)).map { fix(onSegment: $0, plane: plane) }

        // Runs of consecutive segments within the threshold, each reduced to
        // its arrival point; runs close together by odometer are one pass
        // that GPS jitter split, so keep the nearer.
        var passes: [TrackFix] = []
        var start = 0
        while start < fixes.count {
            guard fixes[start].distanceMetres <= thresholdMetres else {
                start += 1
                continue
            }
            var end = start
            while end + 1 < fixes.count, fixes[end + 1].distanceMetres <= thresholdMetres {
                end += 1
            }
            var arrivalIndex = (start...end).min {
                fixes[$0].distanceMetres < fixes[$1].distanceMetres
            } ?? start
            let nearest = fixes[arrivalIndex].distanceMetres
            while arrivalIndex > start,
                isStationary(segment: arrivalIndex - 1),
                fixes[arrivalIndex - 1].distanceMetres <= nearest + Self.arrivalToleranceMetres
            {
                arrivalIndex -= 1
            }
            let arrival = fixes[arrivalIndex]
            if let last = passes.last,
                arrival.odometerMetres - last.odometerMetres < Self.distinctPassMetres
            {
                if arrival.distanceMetres < last.distanceMetres { passes[passes.count - 1] = arrival }
            } else {
                passes.append(arrival)
            }
            start = end + 1
        }

        switch passes.count {
        case 0:
            throw .tooFar(
                nearestMetres: fixes.map(\.distanceMetres).min() ?? .infinity,
                thresholdMetres: thresholdMetres)
        case 1:
            return passes[0]
        default:
            throw .ambiguous(telemetrySeconds: passes.map(\.telemetrySeconds))
        }
    }

    /// Whether the car barely moved between sample `index` and the next.
    private func isStationary(segment index: Int) -> Bool {
        guard index + 1 < records.count else { return true }
        return records[index + 1].odometer - records[index].odometer < Self.stationaryStepMetres
    }

    /// The point on the segment from sample `index` to the next that's
    /// closest to `plane`'s origin, with its time and odometer interpolated.
    private func fix(onSegment index: Int, plane: LocalPlane) -> TrackFix {
        let a = records[index]
        let b = records[min(index + 1, records.count - 1)]
        let p = plane.point(latitude: a.latitude, longitude: a.longitude)
        let q = plane.point(latitude: b.latitude, longitude: b.longitude)
        let (dx, dy) = (q.x - p.x, q.y - p.y)
        let lengthSquared = dx * dx + dy * dy
        let fraction =
            lengthSquared > 0 ? min(max(-(p.x * dx + p.y * dy) / lengthSquared, 0), 1) : 0
        let (x, y) = (p.x + fraction * dx, p.y + fraction * dy)

        func lerp(_ u: Double, _ v: Double) -> Double { u + (v - u) * fraction }
        let first = records[0].timestamp
        return TrackFix(
            telemetrySeconds: lerp(
                a.timestamp.timeIntervalSince(first), b.timestamp.timeIntervalSince(first)),
            sampleIndex: index, fraction: fraction,
            distanceMetres: (x * x + y * y).squareRoot(),
            odometerMetres: lerp(a.odometer, b.odometer))
    }
}

/// Flat-earth metres east (x) and north (y) of an origin: accurate to well
/// under a centimetre over the few hundred metres that decide a fix, and
/// plenty to tell a far location from a near one.
private struct LocalPlane {
    let origin: TrackLocation
    let metresPerDegree = 6_371_000.0 * .pi / 180
    let metresPerLongitudeDegree: Double

    init(origin: TrackLocation) {
        self.origin = origin
        metresPerLongitudeDegree = metresPerDegree * cos(origin.latitude * .pi / 180)
    }

    func point(latitude: Double, longitude: Double) -> (x: Double, y: Double) {
        (
            (longitude - origin.longitude) * metresPerLongitudeDegree,
            (latitude - origin.latitude) * metresPerDegree
        )
    }
}
