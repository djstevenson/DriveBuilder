import Foundation

/// One telemetry sample extracted from dashcam footage, not yet stored in
/// the database (so no row id or journey id — compare `TelemetryRecord`).
///
/// Time is kept as a tick: deciseconds since the Unix epoch, UTC. The GPS
/// stream is sampled at 10 Hz, so every sample sits on the tick grid and
/// integer ticks avoid floating-point drift when interpolating.
struct TelemetrySample: Sendable {
    var tick: Int64
    var latitude: Double
    var longitude: Double
    /// Metres above sea level.
    var altitude: Double
    var speed: Double
    /// [0..360) degrees, 0 = North.
    var heading: Double
    /// g. Positive = accelerating, negative = braking.
    var accelForward: Double?
    /// g. Positive = turning/pulling right, negative = left.
    var accelLateral: Double?
    var speedLimit: Int?
    var file: String?
    var source: String
}

extension TelemetrySample {
    /// Formats a tick without a zone designator, e.g. "2026-07-26T14:37:55.100",
    /// matching the timestamps `TelemetryStore` reads back.
    private static let secondsFormat = Date.ISO8601FormatStyle(timeZone: .gmt)
        .year().month().day()
        .dateTimeSeparator(.standard)
        .time(includingFractionalSeconds: false)

    var timestamp: String {
        let seconds = Date(timeIntervalSince1970: TimeInterval(tick / 10))
        return "\(seconds.formatted(Self.secondsFormat)).\(tick % 10)00"
    }
}

/// Decodes exiftool's "Accelerometer Data" tag from NextBase dashcams.
///
/// It's not pure accelerometer — it's a 6-axis IMU stream (3-axis gyro +
/// 3-axis accelerometer), sampled far faster than GPS (~400 Hz vs GPS's
/// 10 Hz) and packed as repeating groups of 6 raw integers:
///
///   [gyro_x, gyro_y, gyro_z_yaw, accel_z_vertical, accel_y_lateral, accel_x_longitudinal]
///
/// Axis assignment and the scale/bias constants below were derived
/// empirically from real footage (calibrated against known braking,
/// accelerating, and cornering events, then cross-checked against a
/// stationary baseline and a whole-drive regression). Vertical accel and
/// roll/pitch gyro aren't decoded here — not needed yet.
enum Accelerometer {
    private static let longitudinalAxis = 5
    private static let longitudinalScale = 215.0  // counts per m/s²
    private static let longitudinalBias = -143.5

    private static let lateralAxis = 4
    private static let lateralScale = 1660.0  // counts per g (approximate — see calibration notes)
    private static let lateralBias = 90.0

    private static let g = 9.81

    /// Takes the raw tag value (a string of whitespace-separated integers)
    /// and returns forward acceleration/braking and left/right cornering,
    /// both in g, or nil if the string doesn't contain at least one full
    /// group of 6 numbers.
    static func decode(_ raw: String) -> (forward: Double, lateral: Double)? {
        let numbers = raw.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }

        var sumLateral = 0.0
        var sumLongitudinal = 0.0
        var count = 0

        var index = 0
        while index + 5 < numbers.count {
            sumLateral += numbers[index + lateralAxis]
            sumLongitudinal += numbers[index + longitudinalAxis]
            count += 1
            index += 6
        }

        guard count > 0 else { return nil }
        return (
            forward: ((sumLongitudinal / Double(count)) - longitudinalBias) / longitudinalScale / g,
            lateral: ((sumLateral / Double(count)) - lateralBias) / lateralScale)
    }
}

enum NextBaseExtractorError: Error, CustomStringConvertible {
    case missingFrontDirectory(String)
    case noVideoFiles(String)
    case exiftoolFailed(file: String, status: Int32)
    case trackWithoutDateTime(file: String)

    var description: String {
        switch self {
        case .missingFrontDirectory(let path):
            "No NextBase/front directory at \(path)"
        case .noVideoFiles(let path):
            "No NextBase video files (??????_??????_???_FH.MP4) in \(path)"
        case .exiftoolFailed(let file, let status):
            "exiftool exited with status \(status) for \(file)"
        case .trackWithoutDateTime(let file):
            "GPS Track without preceding GPS Date/Time in \(file)"
        }
    }
}

/// Extracts telemetry from a journey's NextBase dashcam footage by running
/// exiftool over each front-camera clip and parsing the embedded GPS and
/// IMU streams; a port of the Perl project's DriveBuilder::NextBaseData.
struct NextBaseExtractor {
    /// The journey directory; clips live in `NextBase/front` beneath it.
    let videoPath: String

    /// Looks up the speed limit at each coordinate, in the same order;
    /// injectable so tests don't need the PostGIS database.
    var speedLimits: ([(latitude: Double, longitude: Double)]) throws -> [Int?]

    func samples() throws -> [TelemetrySample] {
        let frontDirectory = videoPath + "/NextBase/front"
        var isDirectory = ObjCBool(false)
        guard
            FileManager.default.fileExists(atPath: frontDirectory, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw NextBaseExtractorError.missingFrontDirectory(videoPath)
        }

        let filenames = try FileManager.default.contentsOfDirectory(atPath: frontDirectory)
            .filter { $0.wholeMatch(of: /\d{6}_\d{6}_\d{3}_FH\.MP4/) != nil }
            .sorted()
        guard !filenames.isEmpty else {
            throw NextBaseExtractorError.noVideoFiles(frontDirectory)
        }

        var raw: [TelemetrySample] = []
        for filename in filenames {
            raw += try Self.parseClip(named: filename, in: frontDirectory)
        }

        // Look up a speed limit per raw GPS sample, carrying the last known
        // limit over samples where the lookup finds no road.
        let lookups = try speedLimits(raw.map { ($0.latitude, $0.longitude) })
        var lastLimit: Int?
        for index in raw.indices {
            let limit = lookups[index] ?? lastLimit
            raw[index].speedLimit = limit
            lastLimit = limit
        }

        return Self.smooth(Self.interpolate(Self.dedupe(raw)))
    }

    // MARK: - exiftool parsing

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    private static func parseClip(named filename: String, in directory: String) throws
        -> [TelemetrySample]
    {
        let output = try runExiftool(on: directory + "/" + filename, file: filename)

        var samples: [TelemetrySample] = []
        var tick: Int64?
        var latitude: Double?
        var longitude: Double?
        var altitude: Double?
        var speed: Double?
        var accelForward: Double?
        var accelLateral: Double?

        for line in output.split(separator: "\n") {
            // exiftool lines are "Tag Name             : value"; the value
            // can contain ':' (dates do) but never ' : '.
            guard let separator = line.range(of: " : ") else { continue }
            let tag = line[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
            let value = String(line[separator.upperBound...])

            switch tag {
            case "GPS Date/Time":
                tick = Self.tick(fromGPSDateTime: value)
            case "Accelerometer Data":
                (accelForward, accelLateral) = Accelerometer.decode(value) ?? (nil, nil)
            case "GPS Latitude":
                latitude = Double(value)
            case "GPS Longitude":
                longitude = Double(value)
            case "GPS Altitude":
                altitude = Double(value)
            case "GPS Speed":
                speed = Double(value)
            case "GPS Track":
                // End of a GPS sample: commit the last values we saw. Skip
                // incomplete samples (at the start of a recording, some
                // fields may not have appeared yet).
                guard let heading = Double(value) else { continue }
                guard let tick else {
                    throw NextBaseExtractorError.trackWithoutDateTime(file: filename)
                }
                guard let latitude, let longitude, let altitude, let speed else { continue }
                samples.append(
                    TelemetrySample(
                        tick: tick,
                        latitude: latitude,
                        longitude: longitude,
                        altitude: altitude,
                        speed: speed,
                        heading: heading,
                        accelForward: accelForward,
                        accelLateral: accelLateral,
                        speedLimit: nil,
                        file: filename,
                        source: "GPS"))
            default:
                break
            }
        }

        return samples
    }

    /// The GPS data is sampled at 10 Hz, so round to the nearest 0.1 s: the
    /// odd off-grid timestamp (e.g. 14:44:31.109Z) is close enough, and
    /// snapping it to the grid means less interpolation later.
    static func tick(fromGPSDateTime value: String) -> Int64? {
        // exiftool's "GPS Date/Time" value, e.g. "2026:07:26 14:37:55.134Z".
        let gpsDateTime = /(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})(\.\d+)?Z/
        guard let match = value.wholeMatch(of: gpsDateTime) else { return nil }

        let components = DateComponents(
            year: Int(match.1), month: Int(match.2), day: Int(match.3),
            hour: Int(match.4), minute: Int(match.5), second: Int(match.6))
        guard let date = utcCalendar.date(from: components) else { return nil }

        let fraction = match.7.flatMap { Double($0) } ?? 0
        let tenths = Int64((fraction * 10).rounded())
        return Int64(date.timeIntervalSince1970) * 10 + tenths
    }

    private static func runExiftool(on path: String, file: String) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["exiftool", "-ee", "-n", path]

        // Xcode's environment has a minimal PATH; make sure homebrew's
        // exiftool can be found.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:\(environment["PATH"] ?? "/usr/bin:/bin")"
        process.environment = environment

        let stdout = Pipe()
        process.standardOutput = stdout

        try process.run()
        // Drain stdout before waiting, or output bigger than the pipe
        // buffer deadlocks the child.
        let data = try stdout.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NextBaseExtractorError.exiftoolFailed(
                file: file, status: process.terminationStatus)
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Post-processing

    /// Drops all but the first sample seen for each tick.
    static func dedupe(_ samples: [TelemetrySample]) -> [TelemetrySample] {
        var seen = Set<Int64>()
        return samples.filter { seen.insert($0.tick).inserted }
    }

    /// Fills gaps in the tick grid with linearly interpolated samples, so
    /// downstream renderers see one sample per 0.1 s.
    static func interpolate(_ samples: [TelemetrySample]) -> [TelemetrySample] {
        guard !samples.isEmpty else { return [] }

        let sorted = samples.sorted { $0.tick < $1.tick }
        var interpolated = [sorted[0]]

        for current in sorted.dropFirst() {
            let previous = interpolated[interpolated.count - 1]
            let gap = current.tick - previous.tick
            for step in 1..<max(gap, 1) {
                interpolated.append(
                    Self.interpolated(
                        previous, current,
                        tick: previous.tick + step,
                        fraction: Double(step) / Double(gap)))
            }
            interpolated.append(current)
        }

        return interpolated
    }

    private static func interpolated(
        _ previous: TelemetrySample, _ current: TelemetrySample, tick: Int64, fraction: Double
    ) -> TelemetrySample {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * fraction }
        func mixOptional(_ a: Double?, _ b: Double?) -> Double? {
            guard let a, let b else { return nil }
            return mix(a, b)
        }

        // Headings wrap at 360°: interpolate along the shorter way round.
        var headingDelta = current.heading - previous.heading
        while headingDelta > 180 { headingDelta -= 360 }
        while headingDelta < -180 { headingDelta += 360 }

        return TelemetrySample(
            tick: tick,
            latitude: mix(previous.latitude, current.latitude),
            longitude: mix(previous.longitude, current.longitude),
            altitude: mix(previous.altitude, current.altitude),
            speed: mix(previous.speed, current.speed),
            heading: previous.heading + headingDelta * fraction,
            accelForward: mixOptional(previous.accelForward, current.accelForward),
            accelLateral: mixOptional(previous.accelLateral, current.accelLateral),
            speedLimit: previous.speedLimit,  // speed limit doesn't change between samples
            file: previous.file ?? current.file,
            source: "Interpolated")
    }

    // GPS speed limit lookups occasionally glitch onto the wrong road for a
    // sample or two. Group samples into runs of matching speedLimit, and
    // where a run is brief (<= smoothThresholdSeconds) and flanked by two
    // runs that agree with each other, treat it as a blip and correct its
    // speedLimit to match its neighbours rather than showing a momentary
    // flicker on screen.
    private static let smoothThresholdSeconds = 0.25
    private static let tickSeconds = 0.1  // samples are one GPS sample apart, post-interpolation

    static func smooth(_ samples: [TelemetrySample]) -> [TelemetrySample] {
        guard !samples.isEmpty else { return [] }

        var runs: [(speedLimit: Int?, samples: [TelemetrySample])] = []
        for sample in samples {
            if !runs.isEmpty, runs[runs.count - 1].speedLimit == sample.speedLimit {
                runs[runs.count - 1].samples.append(sample)
            } else {
                runs.append((speedLimit: sample.speedLimit, samples: [sample]))
            }
        }

        var changed = true
        while changed {
            changed = false
            guard runs.count >= 3 else { break }
            for index in 1..<(runs.count - 1) {
                let previous = runs[index - 1]
                let middle = runs[index]
                let next = runs[index + 1]

                guard previous.speedLimit == next.speedLimit else { continue }
                guard Double(middle.samples.count) * tickSeconds <= smoothThresholdSeconds
                else { continue }

                runs.replaceSubrange(
                    (index - 1)...(index + 1),
                    with: [
                        (
                            speedLimit: previous.speedLimit,
                            samples: previous.samples + middle.samples + next.samples
                        )
                    ])
                changed = true
                break
            }
        }

        return runs.flatMap { run in
            run.samples.map { sample in
                var sample = sample
                sample.speedLimit = run.speedLimit
                return sample
            }
        }
    }
}
