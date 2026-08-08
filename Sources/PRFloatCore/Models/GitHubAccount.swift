import Foundation

public struct GitHubAccount: Equatable, Sendable, Codable {
    public let login: String
    public let name: String?
    public let avatarURL: URL?

    public init(login: String, name: String? = nil, avatarURL: URL? = nil) {
        self.login = login
        self.name = name
        self.avatarURL = avatarURL
    }

    /// What the header shows: real name when GitHub has one, otherwise the handle.
    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return login
    }

    private enum CodingKeys: String, CodingKey {
        case login
        case name
        case avatarURL = "avatar_url"
    }
}
