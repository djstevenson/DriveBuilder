import DriveBuilder
import SwiftUI

/// The journey window's Clips section: the standard clips and final
/// videos, each with Render, Play, and Reveal.
struct ClipsSection: View {
    let journey: JourneySummary

    var body: some View {
        SectionPage(title: "Clips") {
            EmptyView()
        } content: {
            List(RenderComponent.standardComponents) { component in
                ComponentRow(component: component, journey: journey)
            }
        }
    }
}

/// The frame every journey window section shares: a bar with the
/// section's title and its actions, over its list.
struct SectionPage<Actions: View, Content: View>: View {
    let title: String
    @ViewBuilder let actions: Actions
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.appHeadline)
                Spacer()
                actions
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            Divider()
            content
        }
    }
}
