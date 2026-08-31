import ArgumentParser
import Foundation

extension DriveBuilder {
    struct Annotations: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "annotations",
            abstract: "Build the scrolling annotation banners for a journey.")

        @OptionGroup var telemetry: TelemetryOptions

        @Option(
            name: .customLong("frame-limit"),
            help: "Render only the first N frames of each banner, for a quick check.")
        var frameLimit: Int?

        /// Every annotation source in `directory`'s `annotations` directory,
        /// sorted by name. The directory must exist and contain at least one
        /// `.txt` file; each becomes one movie named after the file.
        static func annotationFiles(in directory: String) throws -> [URL] {
            let annotationsDirectory = URL(filePath: directory).appending(path: "annotations")
            let path = annotationsDirectory.path(percentEncoded: false)

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                throw ValidationError("No annotations directory at \(path).")
            }

            let files = try FileManager.default
                .contentsOfDirectory(at: annotationsDirectory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "txt" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard !files.isEmpty else {
                throw ValidationError("No .txt annotation files in \(path).")
            }
            return files
        }

        /// The annotation's text: the file's lines joined with single spaces,
        /// since the scroll is one long line. Blank lines and leading or
        /// trailing whitespace on each line are dropped.
        static func annotationText(from file: URL) throws -> String {
            try String(contentsOf: file, encoding: .utf8)
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        mutating func run() async throws {
            let directory = try telemetry.journeyDirectory()
            let files = try Self.annotationFiles(in: directory)

            let outputRoot = URL(filePath: directory).appending(path: "output")
            let outputDirectory = outputRoot.appending(path: "annotations")
            try FileManager.default.createDirectory(
                at: outputDirectory, withIntermediateDirectories: true)
            try FileManager.default.excludeFromBackup(outputRoot)

            for file in files {
                let name = file.deletingPathExtension().lastPathComponent
                let text = try Self.annotationText(from: file)
                guard !text.isEmpty else {
                    throw ValidationError(
                        "Annotation file \(file.path(percentEncoded: false)) is empty.")
                }

                let renderer = AnnotationRenderer(text: text)
                try await renderer.writeMovie(
                    to: outputDirectory.appending(path: "\(name).mov"),
                    frameLimit: frameLimit)
            }
        }
    }
}
