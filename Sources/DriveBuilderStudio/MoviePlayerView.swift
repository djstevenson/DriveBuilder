import AVKit
import SwiftUI

/// In-app preview of a rendered clip. Alpha-channel components (dials,
/// annotations) composite over the player's black backing here, like they
/// would in QuickTime Player.
struct MoviePlayerView: View {
    let url: URL
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            VideoPlayer(player: player)
                .frame(minWidth: 960, minHeight: 540)
        }
        .onAppear {
            let player = AVPlayer(url: url)
            self.player = player
            player.play()
        }
        .onDisappear {
            player?.pause()
        }
    }
}
