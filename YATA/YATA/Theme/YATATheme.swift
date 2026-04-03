import SwiftUI

enum YATATheme {

    static func backgroundColor(for priority: Priority) -> Color {
        switch priority {
        case .high: Color("YATARed")
        case .medium: Color("YATAYellow")
        case .low: Color("YATAGreen")
        }
    }

    static let doneBackgroundColor = Color("YATADone")

    static let pillFont: Font = .body.weight(.medium)
    static let titleFont: Font = .system(.title2, weight: .bold)
    static let captionFont: Font = .caption

    static let pillHeight: Double = 40
    static let pillPadding: Double = 8
    static let pillSpacing: Double = 4
    static let containerCornerRadius: Double = 16
    static let containerPadding: Double = 10

    // Shadows inspired by web UI card shadow
    static let containerShadowColor = Color.black.opacity(0.08)
    static let containerShadowRadius: Double = 6
    static let containerShadowY: Double = 4
}

// Film grain overlay inspired by web UI's fractalNoise texture
struct GrainOverlay: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            // Draw noise pattern
            for _ in 0..<Int(size.width * size.height * 0.015) {
                let x = Double.random(in: 0..<size.width)
                let y = Double.random(in: 0..<size.height)
                let opacity = Double.random(in: 0...0.12)
                let dotSize = Double.random(in: 0.5...1.5)
                let color = colorScheme == .dark ? Color.white : Color.black
                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: dotSize, height: dotSize)),
                    with: .color(color.opacity(opacity))
                )
            }
        }
        .allowsHitTesting(false)
        .drawingGroup()
    }
}

// Container background modifier with grain + shadow
struct ContainerStyle: ViewModifier {
    let backgroundColor: Color
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: YATATheme.containerCornerRadius)
                        .fill(backgroundColor)

                    // Subtle radial glow in dark mode (like web UI)
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

                    // Grain texture
                    GrainOverlay()
                        .clipShape(RoundedRectangle(cornerRadius: YATATheme.containerCornerRadius))
                        .opacity(0.03)
                }
            }
            .shadow(
                color: YATATheme.containerShadowColor,
                radius: YATATheme.containerShadowRadius,
                y: YATATheme.containerShadowY
            )
    }
}

extension View {
    func containerStyle(color: Color) -> some View {
        modifier(ContainerStyle(backgroundColor: color))
    }
}
