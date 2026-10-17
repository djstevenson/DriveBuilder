import AppKit

extension NSFont {
    /// Helvetica, used for all rendered text. Replaced the locally
    /// installed "Transport" road-sign recreation, whose Medium face had
    /// empty glyphs for symbols such as ° (so "17°C" rendered as "17C").
    /// Falls back to the system face if it isn't available, rather than
    /// failing the render.
    static func helvetica(size: CGFloat) -> NSFont {
        NSFont(name: "Helvetica", size: size) ?? NSFont.systemFont(ofSize: size)
    }

    /// Helvetica Bold: the signs, labels, and dial text, closest in weight
    /// to the Transport Medium they used before.
    static func helveticaBold(size: CGFloat) -> NSFont {
        NSFont(name: "Helvetica-Bold", size: size) ?? NSFont.boldSystemFont(ofSize: size)
    }
}
