import SwiftUI

// MARK: - YATA typography
//
// Three families, registered as bundled variable TTFs (see Info.plist
// `UIAppFonts` and `Resources/Fonts/`):
//
//   Inter Tight  — display: page headers, today date, sheet titles.
//   Inter Variable — body: row titles, settings rows, button labels.
//   JetBrains Mono — mono: small uppercase labels (section headers, day
//                    letters), counts, settings values, "JOT", "ESC".
//
// All three are *variable* TTFs (single file per family, weight is an axis).
// SwiftUI's `Font.custom(_:size:).weight(_)` maps the wght axis at render
// time on iOS 16+, so we don't need separate font files per weight.

enum YATAFont {

    // MARK: Family names (PostScript-resolvable family names from the TTFs)

    fileprivate static let display = "Inter Tight"
    fileprivate static let text    = "Inter Variable"
    fileprivate static let mono    = "JetBrains Mono"

    // MARK: Builders

    /// Display type — Inter Tight. Default 600 / SemiBold per the design's
    /// `28/600 -0.025em` baseline. Caller picks size + weight.
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .custom(display, size: size).weight(weight)
    }

    /// Body type — Inter Variable. Default `.regular` to match the design's
    /// 16/450 row title (450 ≈ regular on the wght axis).
    static func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(text, size: size).weight(weight)
    }

    /// Mono type — JetBrains Mono. Default `.medium` because every mono use
    /// in the design is a small uppercase label (10–12pt, weight 500).
    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .custom(mono, size: size).weight(weight)
    }
}
