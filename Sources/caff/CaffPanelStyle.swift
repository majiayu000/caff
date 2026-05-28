import AppKit

enum CaffPanelStyle {
    static let background = panelColor(0xf4f4f7)
    static let card = NSColor.white
    static let cardSubtle = panelColor(0xfafafa)
    static let sunken = panelColor(0xf0f0f3)
    static let line = panelColor(0x000000, alpha: 0.08)
    static let lineStrong = panelColor(0x000000, alpha: 0.12)
    static let ink = panelColor(0x000000, alpha: 0.92)
    static let inkSecondary = panelColor(0x000000, alpha: 0.64)
    static let inkTertiary = panelColor(0x000000, alpha: 0.45)
    static let accent = panelColor(0x5e5ce6)
    static let accentSoft = panelColor(0x5e5ce6, alpha: 0.12)
    static let coffee = panelColor(0xff8a3d)
    static let coffeeDeep = panelColor(0xff6b2c)
    static let heroTint = panelColor(0xfff5ec)
    static let heroBorder = panelColor(0xffd0a8)
    static let good = panelColor(0x2bb673)
    static let goodSoft = panelColor(0x2bb673, alpha: 0.12)
    static let bad = panelColor(0xe23b3b)
    static let badSoft = panelColor(0xe23b3b, alpha: 0.10)

    static func panelColor(_ hex: Int, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha
        )
    }

    static func applyCard(_ view: NSView, radius: CGFloat = 14, borderColor: NSColor = line) {
        view.wantsLayer = true
        view.layer?.cornerRadius = radius
        view.layer?.backgroundColor = card.cgColor
        view.layer?.borderWidth = 1
        view.layer?.borderColor = borderColor.cgColor
    }

    static func configureTitle(_ label: NSTextField, size: CGFloat = 13) {
        label.font = .systemFont(ofSize: size, weight: .semibold)
        label.textColor = ink
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
    }

    static func configureBody(_ label: NSTextField, size: CGFloat = 11) {
        label.font = .systemFont(ofSize: size)
        label.textColor = inkTertiary
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
    }

    static func styleRoundedButton(_ button: NSButton, tint: NSColor? = nil) {
        button.bezelStyle = .rounded
        button.controlSize = .small
        if let tint {
            button.bezelColor = tint
        }
    }
}
