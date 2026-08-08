import Foundation

/// Org-scoped contribution stats plus merged-PR flow data, in one GraphQL request.
///
/// `contributionsCollection` is deliberately fetched *unscoped* and filtered client-side by
/// repository owner: scoping it server-side needs the organization's node ID, which would
/// cost an extra round trip. The per-repository breakdowns carry `nameWithOwner`, so the
/// filter is exact either way.
public enum ContributionQuery {
    public static let document = """
    query($from: DateTime!, $to: DateTime!, $mergedQuery: String!) {
      viewer {
        login
        organizations(first: 50) {
          nodes { login name }
        }
        contributionsCollection(from: $from, to: $to) {
          commitContributionsByRepository(maxRepositories: 100) {
            repository { nameWithOwner }
            contributions { totalCount }
          }
          pullRequestContributionsByRepository(maxRepositories: 100) {
            repository { nameWithOwner }
            contributions { totalCount }
          }
          pullRequestReviewContributionsByRepository(maxRepositories: 100) {
            repository { nameWithOwner }
            contributions { totalCount }
          }
        }
      }
      merged: search(query: $mergedQuery, type: ISSUE, first: 100) {
        nodes {
          ... on PullRequest {
            number
            title
            url
            headRefName
            createdAt
            mergedAt
            additions
            deletions
            changedFiles
            repository { nameWithOwner }
          }
        }
      }
    }
    """

    public struct Result: Sendable, Equatable {
        public let login: String
        public let organizations: [GitHubOrganization]
        public let report: ContributionReport
    }

    /// Fetches contributions for `organization` over `period`.
    /// Pass an empty organization to include every repo the user contributed to.
    public static func fetch(
        using client: GitHubAPIClient,
        organization: String,
        period: MetricsPeriod,
        now: Date = Date()
    ) async throws -> Result {
        let start = period.start(from: now)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let scope = organization.isEmpty ? "" : " org:\(organization)"
        let mergedQuery = "is:pr is:merged author:@me\(scope) merged:>=\(Self.dayString(start))"

        let payload = try await client.graphQL(
            query: document,
            variables: [
                "from": formatter.string(from: start),
                "to": formatter.string(from: now),
                "mergedQuery": mergedQuery
            ],
            as: ContributionPayload.self
        )
        return decode(payload, organization: organization, since: start)
    }

    /// Decodes a recorded payload. Shared by `fetch` and the fixture tests.
    public static func decode(
        _ data: Data,
        organization: String,
        since: Date
    ) throws -> Result {
        do {
            let envelope = try GitHubAPIClient.decoder
                .decode(GraphQLEnvelope<ContributionPayload>.self, from: data)
            if let message = envelope.errors?.first?.message {
                throw GitHubAPIError.graphQL(message)
            }
            guard let payload = envelope.data else {
                throw GitHubAPIError.decoding("GraphQL response contained no data")
            }
            return decode(payload, organization: organization, since: since)
        } catch let error as GitHubAPIError {
            throw error
        } catch {
            throw GitHubAPIError.decoding(error.localizedDescription)
        }
    }

    static func decode(
        _ payload: ContributionPayload,
        organization: String,
        since: Date
    ) -> Result {
        let collection = payload.viewer.contributionsCollection
        var repos: [String: RepoContribution] = [:]

        func belongs(_ nameWithOwner: String) -> Bool {
            guard !organization.isEmpty else { return true }
            let owner = nameWithOwner.split(separator: "/").first.map(String.init) ?? ""
            return owner.caseInsensitiveCompare(organization) == .orderedSame
        }

        for entry in collection.commitContributionsByRepository where belongs(entry.repository.nameWithOwner) {
            repos[entry.repository.nameWithOwner, default: RepoContribution(repository: entry.repository.nameWithOwner)]
                .commits += entry.contributions.totalCount
        }
        for entry in collection.pullRequestContributionsByRepository where belongs(entry.repository.nameWithOwner) {
            repos[entry.repository.nameWithOwner, default: RepoContribution(repository: entry.repository.nameWithOwner)]
                .pullRequests += entry.contributions.totalCount
        }
        for entry in collection.pullRequestReviewContributionsByRepository where belongs(entry.repository.nameWithOwner) {
            repos[entry.repository.nameWithOwner, default: RepoContribution(repository: entry.repository.nameWithOwner)]
                .reviews += entry.contributions.totalCount
        }

        let merged = (payload.merged?.nodes ?? [])
            .compactMap { $0.value?.toMergedPullRequest() }
            .filter { belongs($0.repository) && $0.mergedAt >= since }

        let byRepository = repos.values.sorted { $0.total > $1.total }
        var report = ContributionReport(
            commits: byRepository.reduce(0) { $0 + $1.commits },
            pullRequestsOpened: byRepository.reduce(0) { $0 + $1.pullRequests },
            reviews: byRepository.reduce(0) { $0 + $1.reviews },
            byRepository: byRepository,
            mergedPullRequests: merged.sorted { $0.mergedAt > $1.mergedAt }
        )
        // Repos with merges but no counted contribution still belong in the breakdown.
        for pr in report.mergedPullRequests where !repos.keys.contains(pr.repository) {
            report.byRepository.append(RepoContribution(repository: pr.repository))
        }

        let organizations = (payload.viewer.organizations?.nodes ?? [])
            .map { GitHubOrganization(login: $0.login, name: $0.name) }
            .sorted { $0.login.localizedCaseInsensitiveCompare($1.login) == .orderedAscending }

        return Result(login: payload.viewer.login, organizations: organizations, report: report)
    }

    static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}

// MARK: - Wire types

struct ContributionPayload: Decodable {
    let viewer: Viewer
    let merged: MergedConnection?

    struct Viewer: Decodable {
        let login: String
        let organizations: OrganizationConnection?
        let contributionsCollection: Collection
    }

    struct OrganizationConnection: Decodable {
        let nodes: [Organization]

        struct Organization: Decodable {
            let login: String
            let name: String?
        }
    }

    struct Collection: Decodable {
        let commitContributionsByRepository: [RepositoryEntry]
        let pullRequestContributionsByRepository: [RepositoryEntry]
        let pullRequestReviewContributionsByRepository: [RepositoryEntry]
    }

    struct RepositoryEntry: Decodable {
        let repository: Repository
        let contributions: Count

        struct Repository: Decodable { let nameWithOwner: String }
        struct Count: Decodable { let totalCount: Int }
    }

    struct MergedConnection: Decodable {
        let nodes: [Lenient<MergedNode>]
    }

    struct MergedNode: Decodable {
        let number: Int
        let title: String
        let url: URL
        let headRefName: String
        let createdAt: Date
        let mergedAt: Date
        let additions: Int
        let deletions: Int
        let changedFiles: Int
        let repository: Repository

        struct Repository: Decodable { let nameWithOwner: String }

        func toMergedPullRequest() -> MergedPullRequest {
            MergedPullRequest(
                repository: repository.nameWithOwner,
                number: number,
                title: title,
                url: url,
                headRefName: headRefName,
                createdAt: createdAt,
                mergedAt: mergedAt,
                additions: additions,
                deletions: deletions,
                changedFiles: changedFiles
            )
        }
    }
}
