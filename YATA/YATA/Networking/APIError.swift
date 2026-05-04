import Foundation

enum APIError: Error, LocalizedError {
    case unauthorized
    case notFound
    case validationError(message: String)
    case serverError(message: String)
    case networkError(underlying: Error)
    case decodingError(underlying: Error)
    case invalidURL

    // Note: there used to be a `.conflict(serverVersion:)` case wired to
    // HTTP 409 from the optimistic-concurrency check on `updated_at`.
    // That mechanism was removed (see
    // docs/conflict_resolution_redesign.md). The server now stamps
    // `updated_at` itself and never returns 409 for write conflicts;
    // any 409 from a stale server falls through to `.serverError` below.

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Authentication required. Please re-enter your credentials."
        case .notFound:
            "The requested resource was not found."
        case .validationError(let message):
            message
        case .serverError(let message):
            message
        case .networkError(let underlying):
            "Network error: \(underlying.localizedDescription)"
        case .decodingError(let underlying):
            "Failed to process server response: \(underlying.localizedDescription)"
        case .invalidURL:
            "Invalid server URL."
        }
    }
}
