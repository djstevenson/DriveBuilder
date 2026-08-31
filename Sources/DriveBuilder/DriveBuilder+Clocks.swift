import ArgumentParser
import Foundation

extension DriveBuilder {
    struct WallClock: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "wall-clock",
            abstract: "Build the wall clock (UTC time of day) for a journey.")

        @OptionGroup var telemetry: TelemetryOptions

        @OptionGroup var video: VideoOptions

        mutating func run() async throws {
            let renderer = WallClockRenderer(
                records: try telemetry.load(), pixelSize: video.pixelSize)
            try await renderer.writeMovie(
                to: video.outputURL(
                    named: "wall", journeyDirectory: try telemetry.journeyDirectory()),
                framesPerSecond: video.framesPerSecond,
                frameLimit: video.frameLimit)
        }
    }

    struct RelativeClock: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "relative-clock",
            abstract: "Build the relative clock (time since the start) for a journey.")

        @OptionGroup var telemetry: TelemetryOptions

        @OptionGroup var video: VideoOptions

        mutating func run() async throws {
            let renderer = RelativeClockRenderer(
                records: try telemetry.load(), pixelSize: video.pixelSize)
            try await renderer.writeMovie(
                to: video.outputURL(
                    named: "relative", journeyDirectory: try telemetry.journeyDirectory()),
                framesPerSecond: video.framesPerSecond,
                frameLimit: video.frameLimit)
        }
    }
}
