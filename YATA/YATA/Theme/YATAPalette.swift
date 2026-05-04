import SwiftUI
import UIKit

// MARK: - YATA palette
//
// Warm-neutral chroma family in both modes so the terracotta accent reads
// as intentional rather than jarring. Dark mode is "warm off-black" — not
// pure black — and light mode is "warm paper" rather than system white.
// All hue references hover around 75°.
//
// The four chromatic tokens (`accent`, `done`, `danger`, `rolled`) were
// computed once from the designer's OKLCH specs to sRGB and baked in here:
//
//   dark.accent   oklch(70% 0.12 55)   → #D78951   (terracotta)
//   dark.done     oklch(70% 0.09 145)  → #7BAE7C   (muted sage)
//   dark.danger   oklch(62% 0.16 25)   → #D55753   (warm red)
//   dark.rolled   oklch(72% 0.10 70)   → #CD995C   (amber)
//   light.accent  oklch(55% 0.14 45)   → #B2511E
//   light.done    oklch(52% 0.09 145)  → #467748
//   light.danger  oklch(52% 0.18 25)   → #BA2B2E
//   light.rolled  oklch(60% 0.12 65)   → #B16F23
//
// Using `UIColor { trait in … }` so each token resolves dynamically when
// the user toggles light/dark — no asset-catalog round-trip needed and
// every token lives in one diff-able place.

extension Color {

    // MARK: Surfaces

    /// App background — warm off-black (#0E0D0B) / warm paper (#F7F3EC).
    static let yataBG = Color(uiColor: UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0x0E/255, green: 0x0D/255, blue: 0x0B/255, alpha: 1)
            : UIColor(red: 0xF7/255, green: 0xF3/255, blue: 0xEC/255, alpha: 1)
    })

    /// Section card background.
    static let yataSurface = Color(uiColor: UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0x18/255, green: 0x17/255, blue: 0x14/255, alpha: 1)
            : UIColor(red: 0xFF/255, green: 0xFD/255, blue: 0xF8/255, alpha: 1)
    })

    /// Slightly lifted surface for input fields and pressed-row state.
    static let yataSurface2 = Color(uiColor: UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0x1F/255, green: 0x1D/255, blue: 0x19/255, alpha: 1)
            : UIColor(red: 0xFF/255, green: 0xFD/255, blue: 0xF8/255, alpha: 1)
    })

    /// Highest tier — active tab background, dragging-row background.
    static let yataSurfaceHi = Color(uiColor: UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0x2A/255, green: 0x27/255, blue: 0x22/255, alpha: 1)
            : UIColor(red: 0xF0/255, green: 0xEA/255, blue: 0xDF/255, alpha: 1)
    })

    /// 1px hairline border tint. Replaces drop shadows everywhere except
    /// the floating tab/jot pills.
    static let yataHairline = Color(uiColor: UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 245/255, blue: 225/255, alpha: 0.07)
            : UIColor(red: 40/255, green: 30/255, blue: 15/255, alpha: 0.08)
    })

    // MARK: Text

    static let yataText = Color(uiColor: UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0xF2/255, green: 0xEE/255, blue: 0xE6/255, alpha: 1)
            : UIColor(red: 0x1A/255, green: 0x17/255, blue: 0x12/255, alpha: 1)
    })

    /// Body secondary, section headers' meta on hover.
    static let yataTextDim = Color(uiColor: UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 242/255, green: 238/255, blue: 230/255, alpha: 0.62)
            : UIColor(red: 26/255, green: 23/255, blue: 18/255, alpha: 0.62)
    })

    /// Lowest legibility — undone-but-not-active hints, day-letter labels.
    static let yataTextMute = Color(uiColor: UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 242/255, green: 238/255, blue: 230/255, alpha: 0.38)
            : UIColor(red: 26/255, green: 23/255, blue: 18/255, alpha: 0.40)
    })

    // MARK: Chromatic accents

    /// Terracotta — Now bucket markers, today indicator, primary actions.
    static let yataAccent = Color(uiColor: UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0xD7/255, green: 0x89/255, blue: 0x51/255, alpha: 1)
            : UIColor(red: 0xB2/255, green: 0x51/255, blue: 0x1E/255, alpha: 1)
    })

    /// Soft accent fill for chip-style buttons (empty-state CTA, etc).
    static let yataAccentSoft = Color(uiColor: UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0xD7/255, green: 0x89/255, blue: 0x51/255, alpha: 0.14)
            : UIColor(red: 0xB2/255, green: 0x51/255, blue: 0x1E/255, alpha: 0.10)
    })

    /// Muted sage — completed state, Later arc.
    static let yataDoneSage = Color(uiColor: UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0x7B/255, green: 0xAE/255, blue: 0x7C/255, alpha: 1)
            : UIColor(red: 0x46/255, green: 0x77/255, blue: 0x48/255, alpha: 1)
    })

    /// Warm red — delete swipe action, disconnect button.
    static let yataDanger = Color(uiColor: UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0xD5/255, green: 0x57/255, blue: 0x53/255, alpha: 1)
            : UIColor(red: 0xBA/255, green: 0x2B/255, blue: 0x2E/255, alpha: 1)
    })

    /// Amber — Soon arc + carry-over pill outline. Outlined only, never
    /// filled — the design treats carry-over as information, not shame.
    static let yataRolled = Color(uiColor: UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0xCD/255, green: 0x99/255, blue: 0x5C/255, alpha: 1)
            : UIColor(red: 0xB1/255, green: 0x6F/255, blue: 0x23/255, alpha: 1)
    })
}
