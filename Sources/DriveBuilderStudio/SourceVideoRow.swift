import AVFoundation
import DriveBuilder
import SwiftUI

/// Keys the details reload to both the file and the toolbar's Reload
/// button, so switching journeys or reloading re-reads the video from
/// disk rather than showing stale details.
private struct SourceVideoLoadKey: Equatable {
    let url: URL
    let outputsVersion: Int
}

/// One of a segment's source-footage files, named by the segment and found
/// beneath the journey's video directory. Shows the file's name and the
/// video's duration, resolution, frame rate, and size, or notes that the
/// file is missing.
struct SourceVideoRow: View {
    @Environment(StudioModel.self) private var model
    let name: String
    /// The file's name, as the segment stores it.
    let file: String
    let url: URL
    /// The segment's synchronisation offset for this source, in seconds;
    /// nil for a side camera the segment doesn't use.
    let offset: Double?
    /// Opens the editing sheet for this source.
    let onEditOffset: () -> Void

    @State private var details: String?

    var body: some View {
        let status = FileStatus(url: url)
        let fileDetails =
            "\(file) \u{00B7} " + (status.exists ? (details ?? "Loading\u{2026}") : "Missing")
        // An unused side camera: its file (if any) is ignored by the render.
        let caption =
            if let offset {
                "\(fileDetails) \u{00B7} \(Self.offsetText(offset))"
            } else {
                status.exists ? "Not used \u{00B7} \(fileDetails)" : "Not used"
            }

        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(caption)
                    .font(.appCaption)
                    .foregroundStyle(
                        status.exists && offset != nil
                            ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            }
            Spacer()
            Button("Edit", systemImage: "pencil") {
                onEditOffset()
            }
        }
        .padding(.vertical, 4)
        .task(id: SourceVideoLoadKey(url: url, outputsVersion: model.outputsVersion)) {
            details = status.exists ? await loadDetails(status: status) : nil
        }
    }

    /// The detail line's offset part, shared with the telemetry row so all
    /// three sources format their offsets identically.
    static func offsetText(_ offset: Double) -> String {
        "Offset \(offset.formatted(.number.precision(.fractionLength(0...3)))) s"
    }

    private func loadDetails(status: FileStatus) async -> String {
        var parts: [String] = []
        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration), duration.isNumeric {
            parts.append(
                Duration.seconds(duration.seconds)
                    .formatted(.time(pattern: .hourMinuteSecond)))
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            if let size = try? await track.load(.naturalSize) {
                parts.append("\(Int(size.width))\u{00D7}\(Int(size.height))")
            }
            if let fps = try? await track.load(.nominalFrameRate), fps > 0 {
                parts.append(
                    "\(fps.formatted(.number.precision(.fractionLength(0...2)))) fps")
            }
        }
        parts.append(status.sizeBytes.formatted(.byteCount(style: .file)))
        return parts.joined(separator: " \u{00B7} ")
    }
}
