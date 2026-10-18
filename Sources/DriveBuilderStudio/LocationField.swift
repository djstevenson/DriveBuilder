import DriveBuilder
import SwiftUI

extension JourneyPlacement {
    /// The clock captions read times off: final.mov's when it's known,
    /// else the front footage's.
    var captionClock: Clock { clocks.contains(.final) ? .final : .front }

    /// "23:41 in final.mov": when `placement` happens, on `captionClock`.
    func timeText(_ placement: Placement) -> String {
        let clock = captionClock
        return seconds(placement, on: clock).map {
            "\(ClockTime.text(for: $0)) in \(clock.movieName)"
        } ?? ""
    }

    /// A list row's caption for an item at `location`: when it happens, or
    /// why it can't be placed.
    func caption(for location: TrackLocation) -> String {
        switch place(location) {
        case .success(let placement): timeText(placement)
        case .failure(let error): "Not placeable: \(error)"
        }
    }
}

/// A form row for one of an item's locations: a latitude, longitude field
/// (pasted from a map, or as Studio displays it), a line saying when the
/// track passes it - or why it can't be placed - and a "From time…"
/// popover that fills it in from a time read off one of the journey's
/// players.
struct LocationField: View {
    let title: String
    @Binding var text: String
    let help: String
    /// Nil while loading, or if the journey has no telemetry; the field
    /// then only checks the text parses.
    let placement: JourneyPlacement?
    /// Distinguishes this field's accessibility identifiers.
    let identifier: String

    @State private var showingFromTime = false
    @State private var timeText = ""
    @State private var clock: JourneyPlacement.Clock = .final

    var body: some View {
        TextField(title, text: $text, prompt: Text("e.g. 51.0712, -1.7983"))
            .help(help)
            .accessibilityIdentifier("\(identifier)-location")
        LabeledContent {
            HStack(alignment: .firstTextBaseline) {
                status
                    .font(.appCaption)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("\(identifier)-status")
                Spacer()
                Button("From time\u{2026}") {
                    if let placement, !placement.clocks.contains(clock) {
                        clock = placement.captionClock
                    }
                    showingFromTime = true
                }
                .disabled(placement == nil)
                .help("Fill this in from a time read off one of the journey's movies")
                .accessibilityIdentifier("\(identifier)-from-time")
                .popover(isPresented: $showingFromTime, arrowEdge: .bottom) {
                    fromTime
                }
            }
        } label: {
            Text(verbatim: "")
        }
    }

    /// When the track passes the location, or what's wrong with it.
    @ViewBuilder private var status: some View {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Text("Paste a latitude, longitude, or use a time")
                .foregroundStyle(.tertiary)
        } else if let location = TrackLocation(parsing: trimmed) {
            if let placement {
                switch placement.place(location) {
                case .success(let placed):
                    Text(
                        "Reached at \(placement.timeText(placed)), "
                            + "\(Int(placed.distanceMetres.rounded())) m from the track")
                        .foregroundStyle(.secondary)
                case .failure(let error):
                    Text(error.description)
                        .foregroundStyle(.red)
                }
            }
        } else {
            Text("Not a latitude, longitude")
                .foregroundStyle(.red)
        }
    }

    /// The popover: a time on a chosen movie's clock, turned into where
    /// the track was then.
    private var fromTime: some View {
        let seconds = ClockTime.seconds(from: timeText)
        let location = seconds.flatMap { placement?.location(atSeconds: $0, on: clock) }
        return VStack(alignment: .leading, spacing: 10) {
            Form {
                Picker("Movie", selection: $clock) {
                    ForEach(placement?.clocks ?? []) { clock in
                        Text(clock.movieName).tag(clock)
                    }
                }
                .accessibilityIdentifier("\(identifier)-from-time-movie")
                TextField("Time", text: $timeText, prompt: Text("e.g. 25:03.5"))
                    .help("As the movie's player shows it: m:ss, h:mm:ss, or seconds")
                    .accessibilityIdentifier("\(identifier)-from-time-time")
            }
            if seconds != nil, location == nil {
                Text("That time isn't on the recorded track.")
                    .font(.appCaption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Use") {
                    if let location {
                        text = location.text
                    }
                    showingFromTime = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(location == nil)
                .accessibilityIdentifier("\(identifier)-from-time-use")
            }
        }
        .padding()
        .frame(width: 300)
    }
}

/// Whether `text` is a location the form can save: it must parse, and
/// once the track is loaded, the track must pass it exactly once.
func isPlaceable(_ text: String, on placement: JourneyPlacement?) -> Bool {
    guard let location = TrackLocation(parsing: text) else { return false }
    guard let placement else { return true }
    return (try? placement.place(location).get()) != nil
}
