import XCTest
@testable import YATA

// MARK: - URLProtocol Stub

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responseHandler: ((URLRequest) -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.responseHandler else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let (data, response) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Tests

final class APIClientTests: XCTestCase {

    private var client: APIClient!
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: config)
        client = APIClient(
            serverURL: URL(string: "https://api.example.com")!,
            token: "test-token",
            session: session
        )
    }

    override func tearDown() {
        StubURLProtocol.responseHandler = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func stubResponse(statusCode: Int, json: String = "{}") {
        StubURLProtocol.responseHandler = { request in
            let url = request.url ?? URL(string: "https://api.example.com")!
            let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            return (json.data(using: .utf8)!, response)
        }
    }

    // MARK: - Success

    func testSuccessfulRequest() async throws {
        let json = """
        { "status": "ok", "version": "1.0.0" }
        """
        stubResponse(statusCode: 200, json: json)

        let response: HealthResponse = try await client.request(.health)
        XCTAssertEqual(response.status, "ok")
        XCTAssertEqual(response.version, "1.0.0")
    }

    func testAuthorizationHeaderIncluded() async throws {
        StubURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let url = request.url!
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return ("{\"status\":\"ok\",\"version\":\"1.0.0\"}".data(using: .utf8)!, response)
        }

        let _: HealthResponse = try await client.request(.health)
    }

    // MARK: - Error Mapping

    func testUnauthorized() async {
        stubResponse(statusCode: 401)
        do {
            let _: HealthResponse = try await client.request(.health)
            XCTFail("Expected unauthorized error")
        } catch let error as APIError {
            guard case .unauthorized = error else {
                XCTFail("Expected .unauthorized, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testNotFound() async {
        stubResponse(statusCode: 404)
        do {
            let _: HealthResponse = try await client.request(.health)
            XCTFail("Expected notFound error")
        } catch let error as APIError {
            guard case .notFound = error else {
                XCTFail("Expected .notFound, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testConflict() async {
        let serverVersionJSON = """
        {"error":{"code":"conflict","message":"Version mismatch"}}
        """
        stubResponse(statusCode: 409, json: serverVersionJSON)
        do {
            let _: HealthResponse = try await client.request(.health)
            XCTFail("Expected conflict error")
        } catch let error as APIError {
            guard case .conflict(let data) = error else {
                XCTFail("Expected .conflict, got \(error)")
                return
            }
            XCTAssertFalse(data.isEmpty)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testValidationError() async {
        let json = """
        {"error":{"code":"validation_error","message":"Title cannot be empty"}}
        """
        stubResponse(statusCode: 422, json: json)
        do {
            let _: HealthResponse = try await client.request(.health)
            XCTFail("Expected validation error")
        } catch let error as APIError {
            guard case .validationError(let message) = error else {
                XCTFail("Expected .validationError, got \(error)")
                return
            }
            XCTAssertEqual(message, "Title cannot be empty")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testServerError() async {
        let json = """
        {"error":{"code":"server_error","message":"Internal failure"}}
        """
        stubResponse(statusCode: 500, json: json)
        do {
            let _: HealthResponse = try await client.request(.health)
            XCTFail("Expected server error")
        } catch let error as APIError {
            guard case .serverError(let message) = error else {
                XCTFail("Expected .serverError, got \(error)")
                return
            }
            XCTAssertEqual(message, "Internal failure")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testUnknownStatusCode() async {
        stubResponse(statusCode: 503)
        do {
            let _: HealthResponse = try await client.request(.health)
            XCTFail("Expected server error for unknown status")
        } catch let error as APIError {
            guard case .serverError(let message) = error else {
                XCTFail("Expected .serverError, got \(error)")
                return
            }
            XCTAssertEqual(message, "HTTP 503")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testDecodingError() async {
        stubResponse(statusCode: 200, json: "not valid json for HealthResponse")
        do {
            let _: HealthResponse = try await client.request(.health)
            XCTFail("Expected decoding error")
        } catch let error as APIError {
            guard case .decodingError = error else {
                XCTFail("Expected .decodingError, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testRequestNoContent() async throws {
        stubResponse(statusCode: 204)
        try await client.requestNoContent(.deleteItem(id: UUID()))
    }

    // MARK: - URL Construction

    func testEndpointURLConstruction() async throws {
        StubURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.url?.path, "/items")
            XCTAssertTrue(request.url?.query?.contains("date=2026-04-05") ?? false)
            let url = request.url!
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return ("{\"items\":[]}".data(using: .utf8)!, response)
        }

        let _: ItemsResponse = try await client.request(.getItems(date: "2026-04-05", priority: nil))
    }
}
