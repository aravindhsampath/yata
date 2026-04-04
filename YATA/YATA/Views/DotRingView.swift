import SwiftUI

/// A ring of evenly-spaced dots that encircles a date in the week strip.
/// Dots are colored by priority (red/yellow/green) with remaining dots in grey.
struct DotRingView: View {
    let highCount: Int
    let mediumCount: Int
    let lowCount: Int
    let diameter: CGFloat
    let totalDots: Int

    init(
        highCount: Int = 0,
        mediumCount: Int = 0,
        lowCount: Int = 0,
        diameter: CGFloat = 32,
        totalDots: Int = 12
    ) {
        let clamped = min(highCount + mediumCount + lowCount, totalDots)
        let h = min(highCount, clamped)
        let m = min(mediumCount, clamped - h)
        let l = min(lowCount, clamped - h - m)
        self.highCount = h
        self.mediumCount = m
        self.lowCount = l
        self.diameter = diameter
        self.totalDots = totalDots
    }

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = diameter / 2
            let dotSize: CGFloat = 3.5
            let angleStep = (2 * .pi) / Double(totalDots)
            // Start from top (-π/2)
            let startAngle = -Double.pi / 2

            var filledSoFar = 0

            for i in 0..<totalDots {
                let angle = startAngle + angleStep * Double(i)
                let x = center.x + radius * cos(angle)
                let y = center.y + radius * sin(angle)
                let rect = CGRect(
                    x: x - dotSize / 2,
                    y: y - dotSize / 2,
                    width: dotSize,
                    height: dotSize
                )

                let color: Color
                if filledSoFar < highCount {
                    color = Color(.yataRed)
                } else if filledSoFar < highCount + mediumCount {
                    color = Color(.yataYellow)
                } else if filledSoFar < highCount + mediumCount + lowCount {
                    color = Color(.yataGreen)
                } else {
                    color = Color.gray.opacity(0.3)
                }
                filledSoFar += 1

                context.fill(
                    Path(ellipseIn: rect),
                    with: .color(color)
                )
            }
        }
        .frame(width: diameter + 6, height: diameter + 6)
        .accessibilityElement()
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        let total = highCount + mediumCount + lowCount
        if total == 0 { return "No tasks" }
        var parts: [String] = []
        if highCount > 0 { parts.append("\(highCount) now") }
        if mediumCount > 0 { parts.append("\(mediumCount) soon") }
        if lowCount > 0 { parts.append("\(lowCount) later") }
        return parts.joined(separator: ", ")
    }
}
