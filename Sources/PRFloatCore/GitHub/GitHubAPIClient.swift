import Foundation

public enum GitHubAPIError: LocalizedError, Equatable {
    case unauthorized
    case rateLimited(resetAt: Date?)
    case offline
    case timedOut
    case http(status: Int, message: String)
    case decoding(String)
    case graphQL(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Session expired. Sign in to GitHub again."
        case .rateLimited(let resetAt):
            guard let resetAt else { return "GitHub rate limit reached." }
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return "GitHub rate limit reached — retrying at \(formatter.string(from: resetAt))."
        case .offline:
            return "No internet connection."
        case .timedOut:
            return "GitHub timed out."
        case .http(let status, let message):
            return message.isEmpty ? "GitHub returned HTTP \(status)." : message
        case .decoding(let detail):
            return "Could not read GitHub's response: \(detail)"
        case .graphQL(let message):
            return message
        }
    }

    /// Whether retrying the same request could plausibly succeed.
    public var isTransient: Bool {
        switch self {
        case .offline, .timedOut, .rateLimited:
            return true
        case .http(let status, _):
            return status >= 500
        case .unauthorized, .decoding, .graphQL:
            return false
        }
    }
}

/// Exponential backoff with full jitter, capped. Pure so the schedule is testable.
public enum Backoff {
    public static func delay(
        attempt: Int,
        base: TimeInterval = 2,
        cap: TimeInterval = 900,
        jitter: Double = 1.0
    ) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        let exponential = base * pow(2, Double(attempt - 1))
        let bounded = min(exponential, cap)
        return bounded * jitter
    }
}

/// Authenticated GitHub API access: GraphQL for PRs, REST for the account.
public struct GitHubAPIClient: Sendable {
    private let http: HTTPClient
    private let token: String
    private let graphQLURL: URL
    private let restBaseURL: URL

    public init(
        http: HTTPClient,
        token: String,
        graphQLURL: URL = URL(string: "https://api.github.com/graphql")!,
        restBaseURL: URL = URL(string: "https://api.github.com")!
    ) {
        self.http = http
        self.token = token
        self.graphQLURL = graphQLURL
        self.restBaseURL = restBaseURL
    }

    public func account() async throws -> GitHubAccount {
        var request = URLRequest(url: restBaseURL.appendingPathComponent("user"))
        request.httpMethod = "GET"
        applyHeaders(to: &request)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let response = try await send(request)
        do {
            return try JSONDecoder().decode(GitHubAccount.self, from: response.body)
        } catch {
            throw GitHubAPIError.decoding(error.localizedDescription)
        }
    }

    public func graphQL<T: Decodable>(
        query: String,
        variables: [String: String] = [:],
        as type: T.Type
    ) async throws -> T {
        var request = URLRequest(url: graphQLURL)
        request.httpMethod = "POST"
        applyHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = ["query": query, "variables": variables]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let response = try await send(request)

        let envelope: GraphQLEnvelope<T>
        do {
            envelope = try JSONDecoder().decode(GraphQLEnvelope<T>.self, from: response.body)
        } catch {
            throw GitHubAPIError.decoding(error.localizedDescription)
        }

        if let message = envelope.errors?.first?.message {
            throw GitHubAPIError.graphQL(message)
        }
        guard let data = envelope.data else {
            throw GitHubAPIError.decoding("GraphQL response contained no data")
        }
        return data
    }

    // MARK: - Transport

    private func applyHeaders(to request: inout URLRequest) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("PRFloat", forHTTPHeaderField: "User-Agent")
    }

    private func send(_ request: URLRequest) async throws -> HTTPResponse {
        let response: HTTPResponse
        do {
            response = try await http.send(request)
        } catch let error as HTTPClientError {
            switch error {
            case .offline: throw GitHubAPIError.offline
            case .timedOut: throw GitHubAPIError.timedOut
            case .transport(let detail): throw GitHubAPIError.http(status: 0, message: detail)
            }
        }
        try Self.validate(response)
        return response
    }

    /// Maps GitHub's status codes onto states the UI can explain.
    static func validate(_ response: HTTPResponse) throws {
        switch response.status {
        case 200...299:
            return
        case 401:
            throw GitHubAPIError.unauthorized
        case 403, 429:
            // GitHub signals rate limiting with a zero remaining count, and 403 is also
            // used for ordinary permission errors — distinguish on the header.
            if response.header("x-ratelimit-remaining") == "0" || response.status == 429 {
                throw GitHubAPIError.rateLimited(resetAt: resetDate(from: response))
            }
            throw GitHubAPIError.http(status: response.status, message: message(from: response))
        default:
            throw GitHubAPIError.http(status: response.status, message: message(from: response))
        }
    }

    static func resetDate(from response: HTTPResponse) -> Date? {
        if let retryAfter = response.header("retry-after"), let seconds = TimeInterval(retryAfter) {
            return Date().addingTimeInterval(seconds)
        }
        guard let reset = response.header("x-ratelimit-reset"), let epoch = TimeInterval(reset) else {
            return nil
        }
        return Date(timeIntervalSince1970: epoch)
    }

    static func message(from response: HTTPResponse) -> String {
        guard
            let object = try? JSONSerialization.jsonObject(with: response.body),
            let dict = object as? [String: Any],
            let message = dict["message"] as? String
        else {
            return ""
        }
        return message
    }
}

// MARK: - GraphQL envelope

struct GraphQLEnvelope<T: Decodable>: Decodable {
    let data: T?
    let errors: [GraphQLErrorEntry]?
}

struct GraphQLErrorEntry: Decodable {
    let message: String
}
