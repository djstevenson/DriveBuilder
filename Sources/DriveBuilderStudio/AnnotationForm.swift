import DriveBuilder
import SwiftUI

/// The sheet for authoring an annotation banner: the output movie's name,
/// the text that scrolls across it, and the location the journey should
/// reach as the banner finishes. Creates a new annotation,
/// or edits `annotation` when one is passed.
struct AnnotationForm: View {
    @Environment(\.dismiss) private var dismiss

    let journey: JourneySummary
    let databasePath: String
    /// The annotation being edited; nil means the form creates a new one.
    let annotation: Annotation?
    /// Runs after a successful save, so the annotations list re-reads the
    /// database.
    let onSave: () -> Void

    @State private var video: String
    @State private var text: String
    @State private var locationText: String
    @State private var isSaving = false
    @State private var saveError: String?

    init(
        journey: JourneySummary, databasePath: String, annotation: Annotation? = nil,
        onSave: @escaping () -> Void
    ) {
        self.journey = journey
        self.databasePath = databasePath
        self.annotation = annotation
        self.onSave = onSave
        _video = State(initialValue: annotation?.video ?? "")
        _text = State(initialValue: annotation?.text ?? "")
        _locationText = State(initialValue: annotation?.endLocation.text ?? "")
    }

    /// The end location, pasted ("51.0712, -1.7983") or as displayed.
    private var endLocation: TrackLocation? {
        TrackLocation(parsing: locationText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(annotation == nil ? "New Annotation" : "Edit Annotation")
                .font(.appHeadline)
            Form {
                TextField("Video name", text: $video, prompt: Text("e.g. A27 On"))
                    .help("Names the output movie: output/<name>.mov")
                TextField("Text", text: $text, axis: .vertical)
                    .lineLimit(3...6)
                    .help("What scrolls across the banner; line breaks become spaces")
                TextField(
                    "End location", text: $locationText, prompt: Text("e.g. 51.0712, -1.7983"))
                    .help(
                        "Where the journey should be as the banner finishes: latitude, "
                            + "longitude, as copied from a map")
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
                Button(annotation == nil ? "Add" : "Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isSaving)
            }
        }
        .padding()
        .frame(width: 440)
    }

    /// The video name becomes a file name, so it can't be empty or contain
    /// a path separator; the text must have something to scroll; the end
    /// location must parse.
    private var isValid: Bool {
        let name = video.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/") else { return false }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return endLocation != nil
    }

    private func save() {
        guard let endLocation else { return }
        isSaving = true
        saveError = nil
        let name = video.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                let library = JourneyLibrary(databasePath: databasePath)
                if let annotation {
                    try await library.updateAnnotation(
                        id: annotation.id, video: name, text: text, endLocation: endLocation)
                } else {
                    try await library.addAnnotation(
                        journeyID: journey.id, video: name, text: text, endLocation: endLocation)
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
