import Foundation

enum SpeedLimitLookupError: Error, CustomStringConvertible {
    case queryFailed(status: Int32)
    case unexpectedRowCount(expected: Int, got: Int)

    var description: String {
        switch self {
        case .queryFailed(let status):
            "psql exited with status \(status) looking up speed limits"
        case .unexpectedRowCount(let expected, let got):
            "Speed limit lookup returned \(got) rows for \(expected) points"
        }
    }
}

/// Looks up speed limits from the OSM roads in the local PostGIS `gb`
/// database, as the Perl project's DriveBuilder::SpeedLimit does. Rather
/// than a query per sample, every point is resolved in a single `psql`
/// run: one scalar subquery per point, so the output has exactly one line
/// per input (blank where no road matched).
struct SpeedLimitLookup {
    var databaseName = "gb"
    var host = "localhost"

    /// Roads more than this many metres away don't count.
    private static let limitDistance = 15

    /// OSM `maxspeed` tags that aren't a plain number, mapped to UK mph figures.
    private static let nslMPH: [String: Int] = [
        "gb:nsl_restricted": 30,
        "gb:nsl_single": 60,
        "gb:nsl_dual": 70,
        "none": 70,
    ]

    /// The speed limit in mph of the nearest road to each point, in the
    /// same order; nil where there's no road within range or its maxspeed
    /// tag couldn't be parsed.
    func limits(for points: [(latitude: Double, longitude: Double)]) throws -> [Int?] {
        guard !points.isEmpty else { return [] }

        var sql = ""
        for point in points {
            let position =
                "ST_Transform(ST_SetSRID(ST_MakePoint(\(point.longitude), \(point.latitude)), 4326), 27700)"
            sql += """
                SELECT (SELECT r.maxspeed FROM osm_roads r
                    WHERE ST_DWithin(r.geom_bng, \(position), \(Self.limitDistance))
                        AND r.maxspeed IS NOT NULL
                    ORDER BY r.geom_bng <-> \(position)
                    LIMIT 1);

                """
        }

        let output = try runPsql(sql)

        // -At prints one line per row; a NULL row is a blank line, so keep
        // empty subsequences and drop only the trailing newline's.
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last == "" { lines.removeLast() }
        guard lines.count == points.count else {
            throw SpeedLimitLookupError.unexpectedRowCount(
                expected: points.count, got: lines.count)
        }

        return lines.map { Self.parseMaxspeed(String($0)) }
    }

    private func runPsql(_ sql: String) throws -> String {
        let scriptURL = FileManager.default.temporaryDirectory
            .appending(path: "speed-limits-\(UUID().uuidString).sql")
        try sql.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = [
            "psql", "-At", "-q", "-v", "ON_ERROR_STOP=1",
            "-d", databaseName, "-h", host,
            "-f", scriptURL.path(percentEncoded: false),
        ]

        // Xcode's environment has a minimal PATH; make sure homebrew's
        // (unlinked, versioned) psql can be found.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] =
            "/opt/homebrew/opt/postgresql@18/bin:/opt/homebrew/bin:"
            + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment

        // stderr is left inherited so Postgres errors show through.
        let stdout = Pipe()
        process.standardOutput = stdout

        try process.run()
        // Drain stdout before waiting, or output bigger than the pipe
        // buffer deadlocks the child.
        let data = try stdout.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw SpeedLimitLookupError.queryFailed(status: process.terminationStatus)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Parses an OSM `maxspeed` tag into mph, or nil if it can't be.
    static func parseMaxspeed(_ raw: String) -> Int? {
        let text = raw.lowercased().trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        if let mph = nslMPH[text] { return mph }
        if let match = text.wholeMatch(of: /(\d+(?:\.\d+)?)(?:\s*mph)?/),
            let value = Double(match.1)
        {
            return Int(value.rounded())
        }

        return nil
    }
}
