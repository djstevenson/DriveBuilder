import DriveBuilder
import Foundation
import SwiftUI

/// A sheet a journey window shows on a section's behalf.
///
/// Sections ask for these through `JourneyPresenter` rather than attaching
/// `.sheet` themselves: presentations declared down in a section (inside
/// the split view's detail column) were only shown long after the click,
/// or not at all, while ones on `JourneyDetailView` itself appear at once.
enum JourneySheet: Identifiable {
    case addAnnotation
    case editAnnotation(Annotation)
    case addRouteMapLabel
    case editRouteMapLabel(RouteMapLabel)
    case addCameraOverride
    case editCameraOverride(CameraOverride)
    case editSegment(SegmentEdit)
    case movie(url: URL, title: String)

    var id: String {
        switch self {
        case .addAnnotation: "add-annotation"
        case .editAnnotation(let annotation): "annotation-\(annotation.id)"
        case .addRouteMapLabel: "add-route-map-label"
        case .editRouteMapLabel(let label): "route-map-label-\(label.id)"
        case .addCameraOverride: "add-camera-override"
        case .editCameraOverride(let cameraOverride): "camera-override-\(cameraOverride.id)"
        case .editSegment(let edit): "segment-\(edit.id)"
        case .movie(let url, _): "movie-\(url.path(percentEncoded: false))"
        }
    }
}

/// Something a section wants deleted, awaiting the journey window's
/// confirmation alert (see `JourneySheet` for why the window shows it).
enum JourneyDeletion: Identifiable {
    case annotation(Annotation)
    case routeMapLabel(RouteMapLabel)
    case cameraOverride(CameraOverride)
    case segment(JourneySegment)

    var id: String {
        switch self {
        case .annotation(let annotation): "annotation-\(annotation.id)"
        case .routeMapLabel(let label): "route-map-label-\(label.id)"
        case .cameraOverride(let cameraOverride): "camera-override-\(cameraOverride.id)"
        case .segment(let segment): "segment-\(segment.id)"
        }
    }

    var title: String {
        switch self {
        case .annotation: "Delete annotation?"
        case .routeMapLabel: "Delete route map label?"
        case .cameraOverride: "Delete secondary camera selection?"
        case .segment: "Delete segment?"
        }
    }

    var message: String {
        switch self {
        case .annotation(let annotation):
            "\u{201C}\(annotation.video)\u{201D} will be removed from the database. "
                + "Its rendered movie, if any, stays on disk."
        case .routeMapLabel(let label):
            "\u{201C}\(label.title)\u{201D} will be removed from the database."
        case .cameraOverride(let cameraOverride):
            "The \(cameraOverride.camera.displayName.lowercased()) view from "
                + "\(cameraOverride.startLocation.text) will be removed; the slot "
                + "shows the rear view there instead."
        case .segment(let segment):
            "Segment \(segment.position + 1) will be removed from the journey. Its "
                + "source videos stay on disk."
        }
    }
}

/// An error a journey window reports on a section's behalf.
struct JourneyFailure: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// How a journey window's sections ask it to present something.
struct JourneyPresenter {
    var showSheet: (JourneySheet) -> Void = { _ in }
    var confirmDeletion: (JourneyDeletion) -> Void = { _ in }
    var showFailure: (JourneyFailure) -> Void = { _ in }
}

extension EnvironmentValues {
    /// The enclosing journey window's presenter; does nothing outside one.
    @Entry var journeyPresenter = JourneyPresenter()
}
