import SwiftUI

enum HapticEvent {
    case dragStart
    case drop
    case markDone
    case delete
}

/// Maps haptic events to SwiftUI sensory feedback values.
/// Use with `.sensoryFeedback()` modifier on views.
extension HapticEvent {
    var feedback: SensoryFeedback {
        switch self {
        case .dragStart: .impact(weight: .medium)
        case .drop: .impact(weight: .light)
        case .markDone: .success
        case .delete: .warning
        }
    }
}
