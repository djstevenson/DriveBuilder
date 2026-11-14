import Foundation

/// One chapter marker in the final videos, stored in the `chapters` table:
/// `title` is what a player's chapter list shows, and `location` is where
/// the drive is as the chapter starts, for `final` to place it by when the
/// track passes there. The intro gets its own marker automatically (see
/// `FinalVideoComposer`); the outro doesn't, being too short a chapter for
/// YouTube.
package struct Chapter: Identifiable, Sendable, Equatable {
    package let id: Int64
    package let journeyID: Int64
    package let title: String
    package let location: TrackLocation
}
