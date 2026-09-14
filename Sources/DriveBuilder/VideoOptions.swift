import ArgumentParser
import Foundation

/// The bare `--frame-limit` option, for subcommands (intro, outro,
/// annotations) whose fixed size and frame rate leave nothing else of
/// `VideoOptions` applicable.
struct FrameLimitOptions: ParsableArguments {
    @Option(
        name: .customLong("frame-limit"),
        help: "Render only the first N frames, for a quick check.")
    var frameLimit: Int?

    func validate() throws {
        if let frameLimit, frameLimit < 1 {
            throw ValidationError("--frame-limit must be at least 1.")
        }
    }
}

/// Options shared by every subcommand that renders a dial to a movie.
struct VideoOptions: ParsableArguments {
    @Option(
        name: .customLong("size"),
        help: "Edge length of the square frame, in pixels. Defaults to 345 for the telemetry dials and 708 for the progress maps.")
    var pixelSize: Int?

    /// Frame size for the telemetry dials (speedo, compass, altitude, g-force).
    var dialPixelSize: Int { pixelSize ?? JourneyRenderer.defaultDialPixelSize }

    /// Frame size for the progress maps: the footprint of a 2x2 dial grid,
    /// two 345px dials plus a 18px gap.
    var mapPixelSize: Int { pixelSize ?? JourneyRenderer.defaultMapPixelSize }

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
        try JourneyRenderer.telemetryOutputURL(named: name, journeyDirectory: journeyDirectory)
    }
}
