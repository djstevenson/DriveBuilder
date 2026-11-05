import DriveBuilder
import SwiftUI

/// The journey window's Route Map Labels section: the signs the route map
/// reveals, in track order, with add, edit, and delete.
struct RouteMapLabelsSection: View {
    @Environment(\.journeyPresenter) private var presenter
    let labels: [RouteMapLabel]
    /// The journey's track, for when each sign appears; nil while loading.
    let placement: JourneyPlacement?

    var body: some View {
        SectionPage(title: "Route Map Labels") {
            Button("Add Label", systemImage: "plus") {
                presenter.showSheet(.addRouteMapLabel)
            }
        } content: {
            List(sortedLabels) { label in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label.title)
                        Text(detail(label))
                            .font(.appCaption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit", systemImage: "pencil") {
                        presenter.showSheet(.editRouteMapLabel(label))
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        presenter.confirmDeletion(.routeMapLabel(label))
                    }
                }
                .padding(.vertical, 4)
            }
            .overlay {
                if labels.isEmpty {
                    ContentUnavailableView(
                        "No route map labels yet", systemImage: "tag",
                        description: Text("Signs the route map shows as the drive reaches them."))
                }
            }
        }
    }

    /// The labels in the order the track reveals them, once it's loaded.
    private var sortedLabels: [RouteMapLabel] {
        placement?.sorted(labels, by: \.revealLocation) ?? labels
    }

    /// The row's caption: when the sign appears (or where, until the track
    /// loads), which side it sits on, its gap from the track point when
    /// overridden, and the subtitle.
    private func detail(_ label: RouteMapLabel) -> String {
        var parts = [
            placement?.caption(for: label.revealLocation) ?? label.revealLocation.text,
            label.location.rawValue,
        ]
        if let distance = label.distance {
            parts.append(
                "gap \(distance.formatted(.number.precision(.fractionLength(0...1))))")
        }
        if !label.subtitle.isEmpty {
            parts.append(label.subtitle)
        }
        return parts.joined(separator: " \u{00B7} ")
    }
}
