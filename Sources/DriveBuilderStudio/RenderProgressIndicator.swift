import DriveBuilder
import SwiftUI

/// The render in flight's progress: the only view that reads
/// `StudioModel.renderProgress`, so its many updates redraw just this,
/// not the rows and sections around it.
struct RenderProgressIndicator: View {
    enum Style {
        /// A small ring, as in the journeys list's status icons.
        case ring
        /// A small ring and the percentage.
        case ringWithPercentage
        /// A full-width bar and the percentage, or what's being prepared.
        case bar
    }

    @Environment(StudioModel.self) private var model
    let style: Style

    var body: some View {
        switch (model.renderProgress, style) {
        case (.preparing, .bar):
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("Preparing \(model.activeRender?.componentName ?? "render")\u{2026}")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        case (.preparing, _):
            ProgressView()
                .controlSize(.small)
        case (.fraction(let fraction), .ring):
            ProgressView(value: fraction)
                .progressViewStyle(.circular)
                .controlSize(.small)
        case (.fraction(let fraction), .ringWithPercentage):
            HStack(spacing: 6) {
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                percentage(fraction)
                    .font(.appCaption.monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
            }
        case (.fraction(let fraction), .bar):
            HStack(spacing: 12) {
                ProgressView(value: fraction)
                percentage(fraction)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }

    private func percentage(_ fraction: Double) -> some View {
        Text(fraction.formatted(.percent.precision(.fractionLength(0))))
            .foregroundStyle(.secondary)
    }
}
