# PRs to Review — design

Closes the gap noted in the README's "Not included" list: PR Float currently shows only
PRs you authored. This adds a second section for PRs where you're requested as a
reviewer.

## Data layer (`PRFloatCore`)

`PullRequestQuery`'s GraphQL document already parameterizes the search string as a `$q`
variable — it isn't hardcoded to `author:@me`. So no new query type or document is
needed, just a second search string and an override parameter:

```swift
public static let searchQuery = "is:pr is:open author:@me archived:false"
public static let reviewRequestedSearchQuery = "is:pr is:open review-requested:@me archived:false"

public static func fetch(
    using client: GitHubAPIClient,
    limit: Int = 50,
    query: String = searchQuery
) async throws -> [PRSummary]
```

Decoding, wire types (`SearchPayload`, `PullRequestNode`, `Lenient`), and
`PullRequestQuery.decode(_:)` are untouched — both searches return the same PR shape, so
the existing decode path is reused as-is. This is a purely additive change to the public
API (`fetch`'s new parameter has a default, so existing call sites don't change).

`review-requested:@me` matches GitHub's own semantics: a PR drops out of this search once
you submit a review (unless re-requested), so the list naturally reflects "still waiting
on you" rather than "ever asked."

## Store (`PRStatusStore`)

- New published state: `reviewRequestedPRs: [PRSummary] = []`.
- New computed property `reviewGroups: [Group]`, grouped/sorted identically to the
  existing `groups`, sourced from `reviewRequestedPRs`.
- `refresh()` fetches both lists concurrently against the same `GitHubAPIClient`:

  ```swift
  async let authored = PullRequestQuery.fetch(using: client)
  async let reviewRequested = PullRequestQuery.fetch(using: client, query: PullRequestQuery.reviewRequestedSearchQuery)
  let (prList, reviewList) = try await (authored, reviewRequested)
  ```

- Failure handling is shared, matching today's single-list behavior: if either call
  throws, the whole refresh fails and both `prs` and `reviewRequestedPRs` keep their
  last-good values (no partial blanking). This keeps the store's error/offline/loading
  state as a single flag instead of doubling it per-section.
- The footer's `attentionCount` stays scoped to `prs` (your own PRs) only. Review-requested
  PRs don't feed into "N need attention" for v1 — that's a distinct kind of urgency
  (blocking someone else) that can be revisited later if wanted.

## Settings (`AppSettings`, `SettingsView`)

- New persisted toggle `showReviewRequests: Bool`, default `true`, backed by
  `UserDefaults` key `showReviewRequestsSection`, following the exact pattern of
  `showAgents`/`showPullRequests`.
- `SettingsView`'s "Show" section gets a third toggle: `Toggle("PRs to review", isOn: $settings.showReviewRequests)`.

## UI (`ContentView`)

- New `reviewRequestsSection` computed view, structurally identical to
  `pullRequestsSection`: grouped-by-repo headers, skeleton rows while loading with no
  data yet, empty state, `SectionHeader` with a count badge. Empty-state copy: "Nothing
  waiting on your review."
- Section order in `overviewBody`: **Agents → Pull Requests (yours) → PRs to Review**,
  each gated on its own `settings.show*` flag.
- `PRRowView` is reused unchanged. Agent badges are omitted for this section — agent
  correlation (`AgentCorrelator`) matches by branch on repos *you're* running agents on,
  which doesn't apply to someone else's PR — so review rows always pass `agents: []`.
- `collapsedLabel` gains a third part (e.g. `"2 to review"`) when
  `settings.showReviewRequests` is on, following the existing `showAgents`/
  `showPullRequests` part-building pattern.

## Out of scope for this change

- Reviewer status (approved / changes requested / commented) isn't surfaced — the section
  is just "still pending your review," matching the search semantics above.
- No change to `attentionCount`/footer urgency math.
- No separate poll interval or independent loading state for the review list.

## Testing

- `PullRequestQueryTests`: add a `searchTerms`-style test asserting
  `reviewRequestedSearchQuery` contains `is:pr`, `is:open`, `review-requested:@me`.
- Add a `fetch` test using the existing `StubHTTPClient` to confirm passing a custom
  `query` actually sends that string as the GraphQL `q` variable (currently untested
  since `fetch` always used the hardcoded constant).
- No new fixture file — decoding is unchanged and already covered by
  `pr-search-sample.json`.
- No new SwiftUI view tests (none exist for `ContentView` today; consistent with current
  coverage).

## Docs

- Remove "Review-requested PRs (authored only)" from the README's "Not included" list.
