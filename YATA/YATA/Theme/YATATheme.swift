import SwiftUI

enum YATATheme {

    static func backgroundColor(for priority: Priority) -> Color {
        switch priority {
        case .high: Color("YATARed")
        case .medium: Color("YATAYellow")
        case .low: Color("YATAGreen")
        }
    }

    static let pillFont: Font = .body.weight(.medium)
    static let titleFont: Font = .largeTitle.bold()
    static let captionFont: Font = .caption

    static let pillHeight: Double = 40
    static let pillPadding: Double = 8
    static let pillSpacing: Double = 4
    static let containerCornerRadius: Double = 16
    static let containerPadding: Double = 10
}
