import Foundation
@testable import PRFloatCore

/// Scripted transport for tests: hands back queued responses in order and records requests.
final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    enum Step {
        case respond(HTTPResponse)
        case fail(HTTPClientError)
    }

    private let lock = NSLock()
    private var steps: [Step]
    private(set) var requests: [URLRequest] = []

    init(_ steps: [Step]) {
        self.steps = steps
    }

    convenience init(json: String, status: Int = 200, headers: [String: String] = [:]) {
        self.init([.respond(HTTPResponse(status: status, headers: headers, body: Data(json.utf8)))])
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requests.count
    }

    func bodyString(at index: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        guard index < requests.count, let body = requests[index].httpBody else { return "" }
        return String(decoding: body, as: UTF8.self)
    }

    /// Synchronous so the lock is never held across a suspension point.
    private func nextStep(recording request: URLRequest) -> Step? {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        return steps.isEmpty ? nil : steps.removeFirst()
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        guard let step = nextStep(recording: request) else {
            throw HTTPClientError.transport("StubHTTPClient ran out of scripted responses")
        }

        switch step {
        case .respond(let response): return response
        case .fail(let error): throw error
        }
    }
}

extension HTTPResponse {
    static func json(_ string: String, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers, body: Data(string.utf8))
    }
}
