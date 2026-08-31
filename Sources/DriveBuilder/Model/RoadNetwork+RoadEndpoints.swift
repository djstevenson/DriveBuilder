struct RoadEndpoints {
    let first: RoadEndpoint
    let second: RoadEndpoint
}

extension RoadNetwork {
    func endpoints(for roadNumber: String) throws -> RoadEndpoints {
        let candidates = try candidateEndpoints(for: roadNumber)

        guard !candidates.isEmpty else {
            throw Error.roadNotFound(roadNumber)
        }
        guard candidates.count >= 2 else {
            throw Error.insufficientEndpoints(roadNumber: roadNumber, count: candidates.count)
        }

        var bestPair: RoadEndpoints?
        var bestDistanceSquared = -Double.infinity

        for i in 0..<(candidates.count - 1) {
            for j in (i + 1)..<candidates.count {
                let a = candidates[i]
                let b = candidates[j]

                let dx = a.location.easting - b.location.easting
                let dy = a.location.northing - b.location.northing

                let distanceSquared = dx * dx + dy * dy

                if distanceSquared > bestDistanceSquared {
                    bestDistanceSquared = distanceSquared
                    bestPair = RoadEndpoints(
                        first: a,
                        second: b
                    )
                }
            }
        }

        return bestPair!
    }
}
