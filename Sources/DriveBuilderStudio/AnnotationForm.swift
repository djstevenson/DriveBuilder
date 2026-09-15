import DriveBuilder
import SwiftUI

/// The sheet for authoring an annotation banner: the output movie's name,
/// the text that scrolls across it, and the offset in seconds into the raw
/// front footage where the banner should finish. Creates a new annotation,
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
    @State private var offsetText: String
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
        _offsetText = State(initialValue: annotation.map { String($0.offset) } ?? "")
    }

    /// The offset parsed as seconds; decimals are fine ("94.5").
    private var offset: Double? {
        Double(offsetText.trimmingCharacters(in: .whitespaces))
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
                TextField("Offset (seconds)", text: $offsetText, prompt: Text("e.g. 94.5"))
                    .help(
                        "Seconds from the start of the raw front footage at which "
                            + "the banner should finish")
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
    /// a path separator; the text must have something to scroll; the offset
    /// must parse as a non-negative number of seconds.
    private var isValid: Bool {
        let name = video.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/") else { return false }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let offset, offset >= 0 else { return false }
        return true
    }

    private func save() {
        guard let offset else { return }
        isSaving = true
        saveError = nil
        let name = video.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                let library = JourneyLibrary(databasePath: databasePath)
                if let annotation {
                    try await library.updateAnnotation(
                        id: annotation.id, video: name, text: text, offset: offset)
                } else {
                    try await library.addAnnotation(
                        journeyID: journey.id, video: name, text: text, offset: offset)
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
