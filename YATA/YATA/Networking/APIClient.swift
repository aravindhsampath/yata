import Foundation

final class APIClient {
    let serverURL: URL
    let token: String
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(serverURL: URL, token: String, session: URLSession = .shared) {
        self.serverURL = serverURL
        self.token = token
        self.session = session

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    func request<T: Decodable>(_ endpoint: Endpoint) async throws -> T {
        let (data, response) = try await performRequest(endpoint)
        try mapStatusCode(response: response, data: data)

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decodingError(underlying: error)
        }
    }

    func requestNoContent(_ endpoint: Endpoint) async throws {
        let (data, response) = try await performRequest(endpoint)
        try mapStatusCode(response: response, data: data)
    }

    // MARK: - Private

    private func performRequest(_ endpoint: Endpoint) async throws(APIError) -> (Data, HTTPURLResponse) {
        let request: URLRequest
        do {
            request = try buildRequest(for: endpoint)
        } catch let error as APIError {
            throw error
        } catch {
            throw .invalidURL
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw .networkError(underlying: error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw .networkError(underlying: URLError(.badServerResponse))
        }

        return (data, httpResponse)
    }

    private func buildRequest(for endpoint: Endpoint) throws -> URLRequest {
        guard var components = URLComponents(url: serverURL.appendingPathComponent(endpoint.path), resolvingAgainstBaseURL: true) else {
            throw APIError.invalidURL
        }
        components.queryItems = endpoint.queryItems

        guard let url = components.url else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let body = try endpoint.bodyData(encoder: encoder) {
            request.httpBody = body
        }

        return request
    }

    private func mapStatusCode(response: HTTPURLResponse, data: Data) throws(APIError) {
        let statusCode = response.statusCode
        guard !(200...299).contains(statusCode) else { return }

        switch statusCode {
        case 401:
            throw .unauthorized
        case 404:
            throw .notFound
        case 409:
            throw .conflict(serverVersion: data)
        case 422:
            let message = (try? decoder.decode(ErrorResponse.self, from: data))?.error.message ?? "Validation error"
            throw .validationError(message: message)
        case 500:
            let message = (try? decoder.decode(ErrorResponse.self, from: data))?.error.message ?? "Server error"
            throw .serverError(message: message)
        default:
            throw .serverError(message: "HTTP \(statusCode)")
        }
    }
}
