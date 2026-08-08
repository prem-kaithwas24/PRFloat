import Foundation

/// The single GraphQL request that replaces v1's per-repo `gh` invocations.
public enum PullRequestQuery {
    public static let searchQuery = "is:pr is:open author:@me archived:false"

    public static let document = """
    query($q: String!, $first: Int!) {
      search(query: $q, type: ISSUE, first: $first) {
        nodes {
          ... on PullRequest {
            number
            title
            url
            body
            headRefName
            isDraft
            repository { nameWithOwner }
            commits(last: 1) {
              nodes {
                commit {
                  statusCheckRollup {
                    contexts(first: 100) {
                      nodes {
                        ... on CheckRun { name status conclusion }
                        ... on StatusContext { context state }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    """

    /// Fetches every open PR authored by the signed-in user, across all visible repos.
    public static func fetch(using client: GitHubAPIClient, limit: Int = 50) async throws -> [PRSummary] {
        let payload = try await client.graphQL(
            query: document,
            variables: ["q": searchQuery, "first": String(limit)],
            as: SearchPayload.self
        )
        return payload.search.nodes.compactMap { $0.value?.toSummary() }
    }

    /// Decodes a recorded GraphQL payload. Shared by `fetch` and the fixture tests.
    public static func decode(_ data: Data) throws -> [PRSummary] {
        do {
            let envelope = try JSONDecoder().decode(GraphQLEnvelope<SearchPayload>.self, from: data)
            if let message = envelope.errors?.first?.message {
                throw GitHubAPIError.graphQL(message)
            }
            guard let payload = envelope.data else {
                throw GitHubAPIError.decoding("GraphQL response contained no data")
            }
            return payload.search.nodes.compactMap { $0.value?.toSummary() }
        } catch let error as GitHubAPIError {
            throw error
        } catch {
            throw GitHubAPIError.decoding(error.localizedDescription)
        }
    }
}

// MARK: - Wire types

/// GraphQL emits `{}` for search results that do not match the inline fragment. Decoding
/// those as `PullRequestNode` fails, so each element is decoded leniently and dropped.
struct Lenient<Wrapped: Decodable>: Decodable {
    let value: Wrapped?

    init(from decoder: Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}

struct SearchPayload: Decodable {
    let search: SearchConnection

    struct SearchConnection: Decodable {
        let nodes: [Lenient<PullRequestNode>]
    }
}

struct PullRequestNode: Decodable {
    let number: Int
    let title: String
    let url: URL
    let body: String?
    let headRefName: String
    let isDraft: Bool
    let repository: Repository
    let commits: CommitConnection?

    struct Repository: Decodable {
        let nameWithOwner: String
    }

    struct CommitConnection: Decodable {
        let nodes: [CommitNode]

        struct CommitNode: Decodable {
            let commit: Commit

            struct Commit: Decodable {
                let statusCheckRollup: Rollup?
            }
        }
    }

    struct Rollup: Decodable {
        let contexts: Contexts?

        struct Contexts: Decodable {
            let nodes: [GHCheck]
        }
    }

    func toSummary() -> PRSummary {
        let checklist = ChecklistParser.parse(body)
        let contexts = commits?.nodes.first?.commit.statusCheckRollup?.contexts?.nodes ?? []
        return PRSummary(
            repository: repository.nameWithOwner,
            number: number,
            title: title,
            headRefName: headRefName,
            url: url,
            isDraft: isDraft,
            checklistDone: checklist.done,
            checklistTotal: checklist.total,
            checks: CheckSummary.from(rollup: contexts)
        )
    }
}
