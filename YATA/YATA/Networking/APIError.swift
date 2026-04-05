import Foundation

enum APIError: Error, LocalizedError {
    case unauthorized
    case notFound
    case conflict(serverVersion: Data)
    case validationError(message: String)
    case serverError(message: String)
    case networkError(underlying: Error)
    case decodingError(underlying: Error)
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Authentication required. Please re-enter your credentials."
        case .notFound:
            "The requested resource was not found."
        case .conflict:
            "The item was modified on the server. Please refresh and try again."
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
