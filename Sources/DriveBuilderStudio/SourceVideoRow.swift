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

/// One of the journey's source-footage files, found by convention beneath
/// the journey directory (video/front.mov, video/rear.mov) rather than in
/// the database. Shows the video's duration, resolution, frame rate, and
/// size, or notes that the file is missing.
struct SourceVideoRow: View {
    @Environment(StudioModel.self) private var model
    let name: String
    let url: URL

    @State private var details: String?

    var body: some View {
        let status = FileStatus(url: url)

        VStack(alignment: .leading, spacing: 2) {
            Text(name)
            Text(status.exists ? (details ?? "Loading\u{2026}") : "Missing")
                .font(.appCaption)
                .foregroundStyle(
                    status.exists ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
        }
        .padding(.vertical, 4)
        .task(id: SourceVideoLoadKey(url: url, outputsVersion: model.outputsVersion)) {
            details = status.exists ? await loadDetails(status: status) : nil
        }
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
