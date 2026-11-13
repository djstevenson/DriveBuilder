import DriveBuilder
import SwiftUI

/// The sheet for authoring a chapter marker: its title, and the location
/// the drive reaches as the chapter starts. Creates a new chapter, or edits
/// `chapter` when one is passed. Like `AnnotationForm`, but a chapter is a
/// single line in a player's menu, so the title is a plain text field.
struct ChapterForm: View {
    @Environment(\.dismiss) private var dismiss

    let journey: JourneySummary
    let databasePath: String
    /// The chapter being edited; nil means the form creates a new one.
    let chapter: Chapter?
    /// The journey's track, to show when the chapter starts; nil while
    /// loading.
    let placement: JourneyPlacement?
    /// Runs after a successful save, so the chapters list re-reads the
    /// database.
    let onSave: () -> Void

    @State private var title: String
    @State private var locationText: String
    @State private var isSaving = false
    @State private var saveError: String?

    init(
        journey: JourneySummary, databasePath: String, chapter: Chapter? = nil,
        placement: JourneyPlacement?, onSave: @escaping () -> Void
    ) {
        self.journey = journey
        self.databasePath = databasePath
        self.chapter = chapter
        self.placement = placement
        self.onSave = onSave
        _title = State(initialValue: chapter?.title ?? "")
        _locationText = State(initialValue: chapter?.location.text ?? "")
    }

    /// Where the chapter starts, pasted ("51.0712, -1.7983") or as
    /// displayed.
    private var location: TrackLocation? {
        TrackLocation(parsing: locationText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(chapter == nil ? "New Chapter" : "Edit Chapter")
                .font(.appHeadline)
            Form {
                TextField("Title", text: $title, prompt: Text("e.g. Salisbury ring road"))
                    .help("What the player's chapter menu shows")
                    .accessibilityIdentifier("chapter-title")
                LocationField(
                    title: "Location", text: $locationText,
                    help: "Where the drive is as the chapter starts: latitude, longitude, as "
                        + "copied from a map",
                    placement: placement, identifier: "chapter")
            }
            if let saveError {
                Text(saveError)
                    .font(.appCallout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                Button(chapter == nil ? "Add" : "Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isSaving)
            }
        }
        .padding()
        .frame(width: 520)
    }

    /// The title is what the menu shows, so it can't be empty; the track
    /// must pass the location exactly once.
    private var isValid: Bool {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return isPlaceable(locationText, on: placement)
    }

    private func save() {
        guard let location else { return }
        isSaving = true
        saveError = nil
        let title = title.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                let library = JourneyLibrary(databasePath: databasePath)
                if let chapter {
                    try await library.updateChapter(id: chapter.id, title: title, location: location)
                } else {
                    try await library.addChapter(
                        journeyID: journey.id, title: title, location: location)
                }
                onSave()
                dismiss()
            } catch {
                saveError = String(describing: error)
                isSaving = false
            }
        }
    }
}
