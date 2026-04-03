import SwiftUI
import UIKit

enum YATATheme {

    static func backgroundColor(for priority: Priority) -> Color {
        switch priority {
        case .high: Color(.yataRed)
        case .medium: Color(.yataYellow)
        case .low: Color(.yataGreen)
        }
    }

    static let doneBackgroundColor = Color(.yataDone)
    static let repeatingBackgroundColor = Color(.yataDone)

    static let pillFont: Font = .body.weight(.medium)
    static let titleFont: Font = .system(.title2, weight: .bold)
    static let captionFont: Font = .caption

    static let pillHeight: Double = 40
    static let pillPadding: Double = 8
    static let pillSpacing: Double = 4
    static let containerCornerRadius: Double = 16
    static let containerPadding: Double = 10

    static let containerShadowColor = Color.black.opacity(0.08)
    static let containerShadowRadius: Double = 6
    static let containerShadowY: Double = 4
}

// MARK: - Cached grain texture

/// Renders a noise texture once per (size, colorScheme) and caches the UIImage.
/// Avoids the previous Canvas approach that re-generated thousands of random dots every frame.
private enum GrainCache {
    private static var cached: (size: CGSize, dark: Bool, image: UIImage)?

    static func texture(size: CGSize, dark: Bool) -> UIImage {
        if let c = cached, c.size == size, c.dark == dark {
            return c.image
        }
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            let gc = ctx.cgContext
            let color: UIColor = dark ? .white : .black
            let dotCount = Int(size.width * size.height * 0.012)
            for _ in 0..<dotCount {
                let x = CGFloat.random(in: 0..<size.width)
                let y = CGFloat.random(in: 0..<size.height)
                let opacity = CGFloat.random(in: 0...0.12)
                let dotSize = CGFloat.random(in: 0.5...1.5)
                gc.setFillColor(color.withAlphaComponent(opacity).cgColor)
                gc.fillEllipse(in: CGRect(x: x, y: y, width: dotSize, height: dotSize))
            }
        }
        cached = (size, dark, image)
        return image
    }
}

struct GrainOverlay: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            Image(uiImage: GrainCache.texture(size: geo.size, dark: colorScheme == .dark))
                .resizable()
        }
        .allowsHitTesting(false)
        .opacity(0.03)
    }
}

// MARK: - Container style

struct ContainerStyle: ViewModifier {
    let backgroundColor: Color
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: YATATheme.containerCornerRadius)
                        .fill(backgroundColor)

                    if colorScheme == .dark {
                        RoundedRectangle(cornerRadius: YATATheme.containerCornerRadius)
                            .fill(
                                RadialGradient(
                                    colors: [Color.white.opacity(0.02), .clear],
                                    center: .top,
                                    startRadius: 0,
                                    endRadius: 200
                                )
                            )
                    }

                    GrainOverlay()
                        .clipShape(RoundedRectangle(cornerRadius: YATATheme.containerCornerRadius))
                }
            }
            .shadow(
                color: YATATheme.containerShadowColor,
                radius: YATATheme.containerShadowRadius,
                y: YATATheme.containerShadowY
            )
            .shadow(
                color: colorScheme == .dark ? backgroundColor.opacity(0.35) : .clear,
                radius: colorScheme == .dark ? 12 : 0
            )
    }
}

extension View {
    func containerStyle(color: Color) -> some View {
        modifier(ContainerStyle(backgroundColor: color))
    }
}
