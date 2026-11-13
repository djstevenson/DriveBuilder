import DriveBuilder
import SwiftUI

/// The journey window's Chapters section: the journey's own chapter
/// markers in the final videos, in track order, with add, edit, and
/// delete. The intro and outro markers are added at render time, so they
/// aren't listed here.
struct ChaptersSection: View {
    @Environment(\.journeyPresenter) private var presenter
    let chapters: [Chapter]
    /// The journey's track, for when each chapter starts; nil while
    /// loading.
    let placement: JourneyPlacement?

    var body: some View {
        SectionPage(title: "Chapters") {
            Button("Add Chapter", systemImage: "plus") {
                presenter.showSheet(.addChapter)
            }
        } content: {
            List(sortedChapters) { chapter in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chapter.title)
                        Text(detail(chapter))
                            .font(.appCaption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit", systemImage: "pencil") {
                        presenter.showSheet(.editChapter(chapter))
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        presenter.confirmDeletion(.chapter(chapter))
                    }
                }
                .padding(.vertical, 4)
            }
            .overlay {
                if chapters.isEmpty {
                    ContentUnavailableView(
                        "No chapters yet", systemImage: "bookmark",
                        description: Text(
                            "Markers in the final videos' chapter menus, between the automatic "
                                + "\u{201C}Intro + Route Map\u{201D} and \u{201C}Outro\u{201D} "
                                + "chapters."))
                }
            }
        }
    }

    /// The chapters in the order the drive reaches them, once the track's
    /// loaded.
    private var sortedChapters: [Chapter] {
        placement?.sorted(chapters, by: \.location) ?? chapters
    }

    /// The row's caption: when the chapter starts (or where, until the
    /// track loads), or why it can't be placed.
    private func detail(_ chapter: Chapter) -> String {
        guard let placement else { return "Starts at \(chapter.location.text)" }
        switch placement.place(chapter.location) {
        case .success(let placed): return "Starts at \(placement.timeText(placed))"
        case .failure(let error): return "Not placeable: \(error)"
        }
    }
}
