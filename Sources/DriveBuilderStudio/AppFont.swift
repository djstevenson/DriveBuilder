import SwiftUI

/// The Studio's text sizes: the standard macOS text styles scaled up by
/// about 25% for readability. Dynamic Type has no effect on macOS, so the
/// scaling is done here instead — `appBody` is installed as the default
/// font at the app root, and the other styles replace their system
/// counterparts (title2 17, headline 13, callout 12, caption 10) at the
/// call sites that need a non-default size.
extension Font {
    static let appTitle2 = Font.system(size: 21)
    static let appHeadline = Font.system(size: 16, weight: .semibold)
    static let appBody = Font.system(size: 16)
    static let appCallout = Font.system(size: 15)
    static let appCaption = Font.system(size: 12.5)
}
