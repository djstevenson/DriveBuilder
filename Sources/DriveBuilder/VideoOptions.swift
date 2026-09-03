import ArgumentParser
import Foundation

/// Options shared by every subcommand that renders a dial to a movie.
struct VideoOptions: ParsableArguments {
    @Option(
        name: .customLong("size"),
        help: "Edge length of the square frame, in pixels. Defaults to 280 for the telemetry dials and 420 for the progress maps.")
    var pixelSize: Int?

    /// Frame size for the telemetry dials (speedo, compass, altitude, g-force).
    var dialPixelSize: Int { pixelSize ?? 280 }

    /// Frame size for the progress maps.
    var mapPixelSize: Int { pixelSize ?? 420 }

    @Option(name: .customLong("fps"), help: "Frame rate. Telemetry is sampled at 10 Hz.")
    var framesPerSecond: Int32 = 10

    @Option(
        name: .customLong("frame-limit"),
        help: "Render only the first N frames, for a quick check.")
    var frameLimit: Int?

    func validate() throws {
        if let pixelSize, pixelSize < 1 {
            throw ValidationError("--size must be a positive number of pixels.")
        }
        guard framesPerSecond > 0 else {
            throw ValidationError("--fps must be positive.")
        }
        if let frameLimit, frameLimit < 1 {
            throw ValidationError("--frame-limit must be at least 1.")
        }
    }

    /// Destination for a named dial's movie, under the journey's
    /// `output/telemetry` directory. Creates that directory if it doesn't
    /// exist yet, and removes any existing movie of the same name so the
    /// render always starts from a clean slate.
    func outputURL(named name: String, journeyDirectory: String) throws -> URL {
        let outputDirectory = URL(filePath: journeyDirectory).appending(path: "output")
        let directory = outputDirectory.appending(path: "telemetry")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.excludeFromBackup(outputDirectory)

        let url = directory.appending(path: "\(name).mov")
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: url)
        }
        return url
    }
}
