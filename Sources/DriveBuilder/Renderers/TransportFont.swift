import AppKit

extension NSFont {
    /// "Transport", the typeface used on real UK road signs - installed
    /// locally as a public-domain recreation (family "Transport", weight
    /// Medium). Falls back to the system bold face if it isn't installed,
    /// rather than failing the render.
    static func transport(size: CGFloat) -> NSFont {
        NSFont(name: "Transport", size: size) ?? NSFont.boldSystemFont(ofSize: size)
    }
}
