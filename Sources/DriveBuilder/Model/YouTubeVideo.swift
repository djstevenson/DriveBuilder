import Foundation

/// One of a journey's two uploadable videos as known to YouTube, stored in
/// the `youtube_videos` table: a draft of its title, description, and
/// visibility before it's uploaded, then YouTube's id for it plus a cache
/// of what YouTube holds. YouTube itself is the source of truth; the row
/// is only written once YouTube has accepted a change.
///
/// A re-rendered movie can't replace the file YouTube has, so uploading it
/// again gives the row a new `videoID` and the old video is left for
/// YouTube Studio to delete.
package struct YouTubeVideo: Identifiable, Sendable, Equatable {
    /// Which of the journey's final videos. The raw value is the `variant`
    /// column's text and the output movie's base name.
    package enum Variant: String, Sendable, CaseIterable, Identifiable {
        case final
        case fastFinal = "final_fast"

        package var id: Self { self }

        /// The movie's file name under the journey's `output` directory.
        package var fileName: String { "\(rawValue).mov" }

        package var displayName: String {
            switch self {
            case .final: "Final video"
            case .fastFinal: "Fast final video"
            }
        }
    }

    /// YouTube's `status.privacyStatus` values.
    package enum Privacy: String, Sendable, CaseIterable, Identifiable {
        case `private`
        case unlisted
        case `public`

        package var id: Self { self }

        package var displayName: String {
            switch self {
            case .private: "Private"
            case .unlisted: "Unlisted"
            case .public: "Public"
            }
        }
    }

    package let id: Int64
    package let journeyID: Int64
    package let variant: Variant
    /// YouTube's id for the video; nil while the row is only a draft.
    package let videoID: String?
    package let title: String
    package let description: String
    package let privacy: Privacy
    /// When the upload that produced `videoID` completed.
    package let uploadedAt: Date?
    /// The modification date of the movie file that was uploaded, so a
    /// newer render can be flagged as not yet on YouTube.
    package let uploadedFileModified: Date?
    /// A resumable upload session in progress, to continue after a quit or
    /// dropped connection; nil when no upload is part-way through.
    package let uploadSessionURI: String?
    /// When the cached metadata was last confirmed against YouTube.
    package let syncedAt: Date?

    package init(
        id: Int64, journeyID: Int64, variant: Variant, videoID: String?, title: String,
        description: String, privacy: Privacy, uploadedAt: Date?, uploadedFileModified: Date?,
        uploadSessionURI: String?, syncedAt: Date?
    ) {
        self.id = id
        self.journeyID = journeyID
        self.variant = variant
        self.videoID = videoID
        self.title = title
        self.description = description
        self.privacy = privacy
        self.uploadedAt = uploadedAt
        self.uploadedFileModified = uploadedFileModified
        self.uploadSessionURI = uploadSessionURI
        self.syncedAt = syncedAt
    }

    package var isUploaded: Bool { videoID != nil }

    /// The video's shareable link, once uploaded.
    package var watchURL: URL? {
        videoID.flatMap { URL(string: "https://youtu.be/\($0)") }
    }
}

/// One of the channel's playlists, cached in the `youtube_playlists` table
/// from YouTube's list so the upload form can offer them offline.
package struct YouTubePlaylist: Identifiable, Sendable, Equatable {
    /// YouTube's playlist id.
    package let id: String
    package let title: String

    package init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// A video's membership of one playlist, in the `youtube_playlist_items`
/// table. YouTube identifies the membership itself (not just the pair), and
/// removing it needs that id.
package struct YouTubePlaylistItem: Identifiable, Sendable, Equatable {
    /// YouTube's playlistItem id.
    package let id: String
    /// The `youtube_videos` row, not YouTube's video id.
    package let videoRowID: Int64
    package let playlistID: String

    package init(id: String, videoRowID: Int64, playlistID: String) {
        self.id = id
        self.videoRowID = videoRowID
        self.playlistID = playlistID
    }
}
