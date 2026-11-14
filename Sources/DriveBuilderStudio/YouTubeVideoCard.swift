import AppKit
import DriveBuilder
import SwiftUI

/// One final video's row in the YouTube section: the movie on disk, what
/// YouTube has, and the buttons to upload, edit, refresh, and share it.
struct YouTubeVideoCard: View {
    @Environment(StudioModel.self) private var model
    @Environment(YouTubeModel.self) private var youtube
    @Environment(\.journeyPresenter) private var presenter
    let journey: JourneySummary
    let variant: YouTubeVideo.Variant
    let video: YouTubeVideo?

    @State private var isRefreshing = false
    /// What the last refresh learnt: YouTube's processing state, or that
    /// the video is gone.
    @State private var refreshNote: String?
    @State private var isGone = false

    var body: some View {
        let _ = model.outputsVersion
        let fileURL = YouTubeModel.movieURL(journey: journey, variant: variant)
        let file = FileStatus(url: fileURL)

        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(variant.displayName)
                    .font(.appHeadline)
                Text("Movie: \(file.summary)")
                    .font(.appCaption)
                    .foregroundStyle(file.exists ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                details(fileURL: fileURL)
            }
            Spacer()
            buttons(fileExists: file.exists)
        }
        .padding(.vertical, 6)
    }

    private var isUploadingThis: Bool {
        youtube.activeUpload?.journeyID == journey.id && youtube.activeUpload?.variant == variant
    }

    /// The movie was rendered again after the upload, so YouTube has an
    /// older cut.
    private func renderedSinceUpload(_ fileURL: URL) -> Bool {
        guard let video, video.isUploaded, let uploaded = video.uploadedFileModified,
            let modified = YouTubeModel.modificationDate(of: fileURL)
        else { return false }
        return modified.timeIntervalSince(uploaded) > 1
    }

    @ViewBuilder
    private func details(fileURL: URL) -> some View {
        if isUploadingThis {
            HStack(spacing: 8) {
                ProgressView(value: youtube.uploadFraction)
                    .frame(maxWidth: 240)
                Text(youtube.uploadFraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.appCaption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } else if let video, video.isUploaded, let url = video.watchURL {
            Text(video.title)
                .font(.appCallout)
            HStack(spacing: 6) {
                Text(video.privacy.displayName)
                if let uploadedAt = video.uploadedAt {
                    Text("\u{00B7} uploaded \(uploadedAt.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            .font(.appCaption)
            .foregroundStyle(.secondary)
            Link(url.absoluteString, destination: url)
                .font(.appCaption)
            if isGone {
                Text("No longer on YouTube")
                    .font(.appCaption)
                    .foregroundStyle(.red)
            } else if let refreshNote {
                Text(refreshNote)
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
            }
            if renderedSinceUpload(fileURL) {
                Text("Rendered since upload: YouTube has the older movie")
                    .font(.appCaption)
                    .foregroundStyle(.orange)
            }
        } else if let video {
            Text("Draft: \u{201C}\(video.title)\u{201D}, not uploaded")
                .font(.appCaption)
                .foregroundStyle(.secondary)
            if video.uploadSessionURI != nil {
                Text("An upload was interrupted; Upload continues it")
                    .font(.appCaption)
                    .foregroundStyle(.orange)
            }
        } else {
            Text("Not uploaded")
                .font(.appCaption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func buttons(fileExists: Bool) -> some View {
        if isUploadingThis {
            Button("Cancel") {
                youtube.cancelUploadButtonTapped()
            }
        } else {
            if let video, video.isUploaded, !isGone {
                Button("Edit Details\u{2026}", systemImage: "pencil") {
                    presenter.showSheet(.youtubeVideo(edit(video, upload: false)))
                }
                Button("Copy Link", systemImage: "link") {
                    if let url = video.watchURL {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                }
                Button("Open", systemImage: "arrow.up.right.square") {
                    if let url = video.watchURL {
                        NSWorkspace.shared.open(url)
                    }
                }
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await refresh(video) }
                    }
                    .help("Re-read the title, description, visibility, and playlists from YouTube.")
                }
            }
            if let video, isGone {
                Button("Forget", systemImage: "trash") {
                    Task { await forget(video) }
                }
                .help("Drop the record of this video; YouTube no longer has it.")
            }
            Button(video?.isUploaded == true ? "Upload as New\u{2026}" : "Upload\u{2026}", systemImage: "arrow.up.circle") {
                presenter.showSheet(.youtubeVideo(edit(video, upload: true)))
            }
            .disabled(!fileExists || youtube.isUploading)
            .help(
                fileExists
                    ? "Upload the movie to YouTube with a title, description, visibility, and playlists."
                    : "Render the movie first.")
        }
    }

    private func edit(_ video: YouTubeVideo?, upload: Bool) -> YouTubeVideoEdit {
        YouTubeVideoEdit(journey: journey, variant: variant, video: video, isUpload: upload)
    }

    private func refresh(_ video: YouTubeVideo) async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            if let remote = try await youtube.refreshButtonTapped(row: video) {
                isGone = false
                refreshNote = remote.uploadStatus.map { status in
                    status == "processed" ? "Processed on YouTube" : "YouTube status: \(status)"
                }
            } else {
                isGone = true
            }
        } catch {
            presenter.showFailure(
                JourneyFailure(title: "Could not refresh from YouTube", message: String(describing: error)))
        }
    }

    private func forget(_ video: YouTubeVideo) async {
        do {
            try await youtube.forgetButtonTapped(row: video)
            isGone = false
        } catch {
            presenter.showFailure(JourneyFailure(title: "Could not forget", message: String(describing: error)))
        }
    }
}
