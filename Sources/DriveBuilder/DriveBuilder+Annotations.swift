import ArgumentParser
import Foundation

extension DriveBuilder {
    struct Annotations: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "annotations",
            abstract: "Build the scrolling annotation banners for a journey.",
            discussion: "Reads the \"annotations\" section of the journey's main.json: each "
                + "entry's \"video\" names the output (output/<video>.mov) and \"text\" is "
                + "what scrolls across the banner.")

        @OptionGroup var telemetry: TelemetryOptions

        @OptionGroup var video: FrameLimitOptions

        /// The journey's annotations, from `main.json`. The file and its
        /// `annotations` section must exist and list at least one entry.
        static func annotations(in journeyDirectory: String) throws -> [MainConfig.Annotation] {
            let annotations = try MainConfig.load(journeyDirectory: journeyDirectory).annotations
            guard !annotations.isEmpty else {
                throw ValidationError(
                    "No \"annotations\" entries in \(journeyDirectory)/main.json.")
            }
            return annotations
        }

        /// The annotation's text: lines joined with single spaces, since the
        /// scroll is one long line. Blank lines and leading or trailing
        /// whitespace on each line are dropped.
        static func normalizedText(_ text: String) -> String {
            text
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        mutating func run() async throws {
            let directory = try telemetry.journeyDirectory()
            let annotations = try Self.annotations(in: directory)

            let outputDirectory = URL(filePath: directory).appending(path: "output")
            try FileManager.default.createDirectory(
                at: outputDirectory, withIntermediateDirectories: true)
            try FileManager.default.excludeFromBackup(outputDirectory)

            for annotation in annotations {
                let text = Self.normalizedText(annotation.text)
                guard !text.isEmpty else {
                    throw ValidationError(
                        "Annotation \"\(annotation.video)\" in main.json has no text.")
                }

                let renderer = AnnotationRenderer(text: text)
                try await renderer.writeMovie(
                    to: outputDirectory.appending(path: "\(annotation.video).mov"),
                    frameLimit: video.frameLimit)
            }
        }
    }
}
