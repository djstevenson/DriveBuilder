import Foundation

/// The journey's hand-authored `main.json`, kept in the root of the journey's
/// data directory. Only the parts the final assembly needs are decoded;
/// other sections (e.g. "annotations") are ignored until they're needed.
struct MainConfig {
    /// Seconds to skip at the start of each separately recorded component so
    /// they play in sync: the cameras and the telemetry logger don't all
    /// start recording at the same moment.
    struct StartOffsets {
        var front = 0.0
        var rear = 0.0
        var telemetry = 0.0
    }

    var startOffsets = StartOffsets()

    private struct File: Decodable {
        struct Component: Decodable {
            var offset: Double?
        }
        var components: [String: Component]?
    }

    /// Loads `main.json` from the journey directory. A missing file just
    /// means no offsets; a malformed one is an error.
    static func load(journeyDirectory: String) throws -> MainConfig {
        var config = MainConfig()
        let url = URL(filePath: journeyDirectory).appending(path: "main.json")
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return config
        }
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        let file = try decoder.decode(File.self, from: Data(contentsOf: url))
        config.startOffsets.front = file.components?["front"]?.offset ?? 0
        config.startOffsets.rear = file.components?["rear"]?.offset ?? 0
        config.startOffsets.telemetry = file.components?["telemetry"]?.offset ?? 0
        return config
    }
}
