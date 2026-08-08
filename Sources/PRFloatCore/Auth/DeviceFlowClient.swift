import Foundation

/// The device-code grant GitHub hands back at the start of the flow.
public struct DeviceCodeGrant: Equatable, Sendable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURI: URL
    public let expiresIn: Int
    /// Minimum seconds between polls, per GitHub.
    public let interval: Int

    public init(deviceCode: String, userCode: String, verificationURI: URL, expiresIn: Int, interval: Int) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.expiresIn = expiresIn
        self.interval = interval
    }
}

public enum DeviceFlowError: LocalizedError, Equatable {
    case missingClientID
    case expiredCode
    case accessDenied
    case unexpected(String)

    public var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "No GitHub OAuth client ID configured"
        case .expiredCode:
            return "The sign-in code expired. Try again."
        case .accessDenied:
            return "Sign-in was cancelled on GitHub."
        case .unexpected(let detail):
            return detail
        }
    }
}

/// One poll of the token endpoint.
public enum DeviceFlowPollResult: Equatable, Sendable {
    /// The user has not finished authorising yet — keep polling.
    case pending
    /// GitHub asked us to back off; the associated value is the new minimum interval.
    case slowDown(interval: Int)
    case token(String)
}

/// Implements GitHub's OAuth device flow (RFC 8628).
///
/// The client ID is not a secret — device flow has no client secret — so it ships in the
/// bundle. The OAuth App must have "Enable Device Flow" checked.
public struct DeviceFlowClient: Sendable {
    public static let defaultScopes = ["repo", "read:org"]

    private let clientID: String
    private let http: HTTPClient
    private let codeURL: URL
    private let tokenURL: URL

    public init(
        clientID: String,
        http: HTTPClient,
        codeURL: URL = URL(string: "https://github.com/login/device/code")!,
        tokenURL: URL = URL(string: "https://github.com/login/oauth/access_token")!
    ) {
        self.clientID = clientID
        self.http = http
        self.codeURL = codeURL
        self.tokenURL = tokenURL
    }

    public func requestDeviceCode(scopes: [String] = defaultScopes) async throws -> DeviceCodeGrant {
        guard !clientID.isEmpty else { throw DeviceFlowError.missingClientID }

        let response = try await http.send(
            Self.form(url: codeURL, fields: [
                "client_id": clientID,
                "scope": scopes.joined(separator: " ")
            ])
        )
        let json = try Self.json(response)

        if let error = json["error"] as? String {
            throw Self.mapError(error, description: json["error_description"] as? String)
        }
        guard
            let deviceCode = json["device_code"] as? String,
            let userCode = json["user_code"] as? String,
            let uriString = json["verification_uri"] as? String,
            let uri = URL(string: uriString)
        else {
            throw DeviceFlowError.unexpected("GitHub returned an unrecognised device code response")
        }

        return DeviceCodeGrant(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURI: uri,
            expiresIn: json["expires_in"] as? Int ?? 900,
            interval: json["interval"] as? Int ?? 5
        )
    }

    public func poll(deviceCode: String) async throws -> DeviceFlowPollResult {
        let response = try await http.send(
            Self.form(url: tokenURL, fields: [
                "client_id": clientID,
                "device_code": deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
            ])
        )
        let json = try Self.json(response)

        if let token = json["access_token"] as? String {
            return .token(token)
        }
        guard let error = json["error"] as? String else {
            throw DeviceFlowError.unexpected("GitHub returned no token and no error")
        }
        switch error {
        case "authorization_pending":
            return .pending
        case "slow_down":
            return .slowDown(interval: json["interval"] as? Int ?? 10)
        default:
            throw Self.mapError(error, description: json["error_description"] as? String)
        }
    }

    // MARK: - Helpers

    private static func mapError(_ error: String, description: String?) -> DeviceFlowError {
        switch error {
        case "expired_token":
            return .expiredCode
        case "access_denied":
            return .accessDenied
        default:
            return .unexpected(description ?? "GitHub rejected the sign-in: \(error)")
        }
    }

    private static func form(url: URL, fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formEncoded(fields).utf8)
        return request
    }

    /// Strict `application/x-www-form-urlencoded`: everything outside RFC 3986's unreserved
    /// set is escaped. `URLComponents` leaves reserved characters such as `:` intact, which
    /// would send the grant type as a literal `urn:ietf:...`.
    static func formEncoded(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")

        return fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
    }

    private static func json(_ response: HTTPResponse) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: response.body),
              let dict = object as? [String: Any]
        else {
            throw DeviceFlowError.unexpected("Could not read GitHub's response (HTTP \(response.status))")
        }
        return dict
    }
}
