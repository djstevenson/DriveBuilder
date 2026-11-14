import DriveBuilder
import SwiftUI

/// What the YouTube form is for: one of a journey's final videos, to
/// upload (afresh or as a new video) or to edit the details of.
struct YouTubeVideoEdit: Identifiable {
    let journey: JourneySummary
    let variant: YouTubeVideo.Variant
    /// The existing record, if any.
    let video: YouTubeVideo?
    let isUpload: Bool

    var id: String { "youtube-\(journey.id)-\(variant.rawValue)-\(isUpload ? "upload" : "edit")" }
}

/// The sheet for a video's YouTube details: title, description,
/// visibility, and playlists. Uploads the movie with them, or saves
/// changes to an uploaded video (or a draft).
struct YouTubeVideoForm: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(YouTubeModel.self) private var youtube
    let edit: YouTubeVideoEdit
    /// Runs after a successful save or an upload's start.
    let onSave: () -> Void

    @State private var title: String
    @State private var description: String
    @State private var privacy: YouTubeVideo.Privacy
    @State private var playlistIDs: Set<String> = []
    @State private var newPlaylistTitle = ""
    @State private var isBusy = false
    @State private var error: String?
    /// The rendered movie's chapters, for the description; nil until read,
    /// or if the movie can't be.
    @State private var chapters: YouTubeChapterList?

    private static let titleLimit = 100
    private static let descriptionLimit = 5000

    init(edit: YouTubeVideoEdit, onSave: @escaping () -> Void) {
        self.edit = edit
        self.onSave = onSave
        let fallbackTitle =
            edit.variant == .final ? edit.journey.title : "\(edit.journey.title) (sped up)"
        _title = State(initialValue: edit.video?.title ?? fallbackTitle)
        _description = State(initialValue: edit.video?.description ?? "")
        _privacy = State(initialValue: edit.video?.privacy ?? .private)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(heading)
                .font(.appHeadline)
            Form {
                TextField("Title", text: $title)
                    .accessibilityIdentifier("youtube-title")
                counter(title.count, limit: Self.titleLimit)
                LabeledContent("Description") {
                    TextEditor(text: $description)
                        .font(.appBody)
                        .frame(minHeight: 120)
                        .accessibilityIdentifier("youtube-description")
                }
                HStack(alignment: .firstTextBaseline) {
                    Button("Insert Chapters", systemImage: "bookmark") {
                        if let chapters {
                            description = YouTubeChapterList.inserting(chapters.text, into: description)
                        }
                    }
                    .disabled(chapters?.entries.isEmpty ?? true)
                    .help(
                        "Add the movie's chapter list to the description, where YouTube reads "
                            + "its chapters from (it ignores the chapter track in the file).")
                    Spacer()
                    counter(description.count, limit: Self.descriptionLimit)
                }
                chapterNotes
                Picker("Visibility", selection: $privacy) {
                    ForEach(YouTubeVideo.Privacy.allCases) { privacy in
                        Text(privacy.displayName).tag(privacy)
                    }
                }
                .pickerStyle(.segmented)
                playlistsField
            }
            if let error {
                Text(error)
                    .font(.appCallout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                Button(edit.isUpload ? "Upload" : "Save") {
                    Task { await submit() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isBusy)
            }
        }
        .padding()
        .frame(width: 560)
        .task {
            if let video = edit.video {
                let items =
                    (try? await JourneyLibrary(databasePath: youtube.databasePath)
                        .youtubePlaylistItems(videoRowID: video.id)) ?? []
                playlistIDs = Set(items.map(\.playlistID))
            }
            let movieURL = YouTubeModel.movieURL(journey: edit.journey, variant: edit.variant)
            chapters = try? await YouTubeChapterList.read(movieURL: movieURL)
            // A fresh description starts as the chapter list, so YouTube
            // gets chapters without a second thought.
            if let chapters, !chapters.entries.isEmpty,
                description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                description = chapters.text
            }
        }
    }

    /// Why YouTube would ignore the chapter list, or that the movie has
    /// none to offer.
    @ViewBuilder
    private var chapterNotes: some View {
        if let chapters {
            if chapters.entries.isEmpty {
                Text("The movie has no chapter track.")
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
            } else if !chapters.problems.isEmpty {
                Text("YouTube would show no chapters: " + chapters.problems.joined(separator: " "))
                    .font(.appCaption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var heading: String {
        if edit.isUpload {
            return edit.video?.isUploaded == true
                ? "Upload \(edit.variant.displayName) as a New Video"
                : "Upload \(edit.variant.displayName)"
        }
        return "Edit \(edit.variant.displayName) on YouTube"
    }

    private func counter(_ count: Int, limit: Int) -> some View {
        Text("\(count) / \(limit)")
            .font(.appCaption)
            .foregroundStyle(count > limit ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var playlistsField: some View {
        LabeledContent("Playlists") {
            VStack(alignment: .leading, spacing: 6) {
                if youtube.playlists.isEmpty {
                    Text("No playlists yet")
                        .foregroundStyle(.secondary)
                }
                ForEach(youtube.playlists) { playlist in
                    Toggle(
                        playlist.title,
                        isOn: Binding(
                            get: { playlistIDs.contains(playlist.id) },
                            set: { on in
                                if on { playlistIDs.insert(playlist.id) } else { playlistIDs.remove(playlist.id) }
                            }))
                }
                HStack {
                    TextField("New playlist", text: $newPlaylistTitle, prompt: Text("New playlist title"))
                    Button("Create") {
                        Task { await createPlaylist() }
                    }
                    .disabled(newPlaylistTitle.trimmingCharacters(in: .whitespaces).isEmpty || isBusy)
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await refreshPlaylists() }
                    }
                    .labelStyle(.iconOnly)
                    .disabled(isBusy)
                    .help("Fetch the channel's playlists again.")
                }
            }
        }
    }

    /// YouTube wants a non-empty title within its limits and no angle
    /// brackets in it.
    private var isValid: Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.titleLimit else { return false }
        guard !trimmed.contains("<"), !trimmed.contains(">") else { return false }
        return description.count <= Self.descriptionLimit
    }

    private var details: YouTubeVideoDetails {
        YouTubeVideoDetails(
            metadata: .init(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                description: description, privacy: privacy),
            playlistIDs: playlistIDs)
    }

    private func submit() async {
        isBusy = true
        error = nil
        defer { isBusy = false }
        if edit.isUpload {
            await youtube.uploadButtonTapped(journey: edit.journey, variant: edit.variant, details: details)
            if let failure = youtube.uploadError, failure.journeyID == edit.journey.id {
                error = failure.message
                return
            }
        } else {
            do {
                try await youtube.saveButtonTapped(
                    journey: edit.journey, variant: edit.variant, row: edit.video, details: details)
            } catch {
                self.error = String(describing: error)
                return
            }
        }
        onSave()
        dismiss()
    }

    private func createPlaylist() async {
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            let playlist = try await youtube.createPlaylist(
                title: newPlaylistTitle.trimmingCharacters(in: .whitespaces))
            playlistIDs.insert(playlist.id)
            newPlaylistTitle = ""
        } catch {
            self.error = String(describing: error)
        }
    }

    private func refreshPlaylists() async {
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            try await youtube.refreshPlaylistsButtonTapped()
        } catch {
            self.error = String(describing: error)
        }
    }
}
