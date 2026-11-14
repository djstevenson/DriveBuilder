import DriveBuilder
import SwiftUI

/// The journey window's YouTube section: the two final videos' upload
/// state, links, and actions, or a pointer to Settings when nobody's
/// signed in.
struct YouTubeSection: View {
    @Environment(YouTubeModel.self) private var youtube
    let journey: JourneySummary
    /// The journey's YouTube records; a variant without one has never been
    /// drafted or uploaded.
    let videos: [YouTubeVideo]

    var body: some View {
        SectionPage(title: "YouTube") {
            if let channel = youtube.account.channel {
                Text("Channel: \(channel.title)")
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
            }
        } content: {
            if youtube.account.isSignedIn {
                List(YouTubeVideo.Variant.allCases) { variant in
                    YouTubeVideoCard(
                        journey: journey, variant: variant,
                        video: videos.first { $0.variant == variant })
                }
            } else {
                ContentUnavailableView {
                    Label("Not signed in", systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text("Sign in to the channel the videos go to, in Settings.")
                } actions: {
                    SettingsLink {
                        Text("Open Settings\u{2026}")
                    }
                }
            }
        }
    }
}
