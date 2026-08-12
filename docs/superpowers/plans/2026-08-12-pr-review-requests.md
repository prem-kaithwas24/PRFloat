# PRs to Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "PRs to Review" section to PR Float showing open PRs where the signed-in user is requested as a reviewer, alongside the existing "your open PRs" list.

**Architecture:** Reuse `PullRequestQuery`'s existing GraphQL document (its search string is already a `$q` variable, not hardcoded) by adding a second search-string constant and an optional `query` override on `fetch`. `PRStatusStore` fetches both lists concurrently per refresh cycle and exposes a second grouped list. `ContentView` renders a second section, gated by a new `AppSettings` toggle, reusing the existing `PRRowView`.

**Tech Stack:** Swift 5.9+, SwiftUI, `Observation` (`@Observable`), Swift Testing (`import Testing`), no third-party dependencies.

## Global Constraints

- macOS 14+, Swift 5.9+ — do not use APIs newer than that.
- No new dependencies.
- Follow existing naming: settings keys are `show<Thing>Section` in `UserDefaults`, properties are `show<Thing>`.
- All new public API on `PullRequestQuery.fetch` must be additive (default parameter) — do not break the existing call site in `PRStatusStore` or the four existing tests in `PullRequestQueryTests.swift`.
- Section header title text: exactly `"PRs to Review"`.
- Empty-state title text: exactly `"Nothing waiting on your review"`.
- Settings toggle label text: exactly `"PRs to review"`.
- New `UserDefaults` key: `showReviewRequestsSection`; new property: `showReviewRequests`, default `true`.

---

### Task 1: `PullRequestQuery` — parameterize the search string on `fetch`

**Files:**
- Modify: `Sources/PRFloatCore/GitHub/PullRequestQuery.swift:5` (add constant), `:40-47` (change `fetch` signature)
- Test: `Tests/PRFloatTests/PullRequestQueryTests.swift`

**Interfaces:**
- Consumes: nothing new (uses existing `GitHubAPIClient.graphQL`, `GraphQLEnvelope`, `SearchPayload`, `document`).
- Produces:
  - `public static let reviewRequestedSearchQuery: String` — value `"is:pr is:open review-requested:@me archived:false"`.
  - `public static func fetch(using client: GitHubAPIClient, limit: Int = 50, query: String = searchQuery) async throws -> [PRSummary]` — new `query` parameter, defaulting to the existing `searchQuery` so `PullRequestQuery.fetch(using: client)` still compiles unchanged.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/PRFloatTests/PullRequestQueryTests.swift`, after the existing `searchTerms` test:

```swift
    @Test("A second search targets PRs where the user is requested as a reviewer")
    func reviewRequestedSearchTerms() {
        #expect(PullRequestQuery.reviewRequestedSearchQuery.contains("is:pr"))
        #expect(PullRequestQuery.reviewRequestedSearchQuery.contains("is:open"))
        #expect(PullRequestQuery.reviewRequestedSearchQuery.contains("review-requested:@me"))
    }

    @Test("fetch sends the overridden query string as the GraphQL q variable")
    func fetchUsesOverriddenQuery() async throws {
        let http = StubHTTPClient(json: #"{"data":{"search":{"nodes":[]}}}"#)
        let client = GitHubAPIClient(http: http, token: "t")

        let prs = try await PullRequestQuery.fetch(
            using: client,
            query: PullRequestQuery.reviewRequestedSearchQuery
        )

        #expect(prs.isEmpty)
        #expect(http.bodyString(at: 0).contains("review-requested:@me"))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PullRequestQueryTests`
Expected: FAIL — `reviewRequestedSearchQuery` and the `query:` parameter don't exist yet (compile error).

- [ ] **Step 3: Implement the change**

In `Sources/PRFloatCore/GitHub/PullRequestQuery.swift`, change:

```swift
public enum PullRequestQuery {
    public static let searchQuery = "is:pr is:open author:@me archived:false"
```

to:

```swift
public enum PullRequestQuery {
    public static let searchQuery = "is:pr is:open author:@me archived:false"

    /// Open PRs where the signed-in user is currently requested as a reviewer.
    /// GitHub drops a PR from this search once the user submits a review, so the
    /// list naturally reflects "still waiting on you."
    public static let reviewRequestedSearchQuery = "is:pr is:open review-requested:@me archived:false"
```

Then change the `fetch` function:

```swift
    /// Fetches every open PR authored by the signed-in user, across all visible repos.
    public static func fetch(using client: GitHubAPIClient, limit: Int = 50) async throws -> [PRSummary] {
        let payload = try await client.graphQL(
            query: document,
            variables: ["q": searchQuery, "first": String(limit)],
            as: SearchPayload.self
        )
        return payload.search.nodes.compactMap { $0.value?.toSummary() }
    }
```

to:

```swift
    /// Fetches PRs matching `query` (defaulting to PRs authored by the signed-in user),
    /// across all visible repos.
    public static func fetch(
        using client: GitHubAPIClient,
        limit: Int = 50,
        query: String = searchQuery
    ) async throws -> [PRSummary] {
        let payload = try await client.graphQL(
            query: document,
            variables: ["q": query, "first": String(limit)],
            as: SearchPayload.self
        )
        return payload.search.nodes.compactMap { $0.value?.toSummary() }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PullRequestQueryTests`
Expected: PASS, all tests including the two new ones and the four pre-existing ones.

- [ ] **Step 5: Commit**

```bash
git add Sources/PRFloatCore/GitHub/PullRequestQuery.swift Tests/PRFloatTests/PullRequestQueryTests.swift
git commit -m "Parameterize PullRequestQuery's search string

Lets fetch() target review-requested PRs, not just authored ones,
without a second GraphQL document."
```

---

### Task 2: `PRStatusStore` — fetch and expose the review-requested list

**Files:**
- Modify: `Sources/PRFloat/Store/PRStatusStore.swift:17-21` (state), `:37-41` (add `reviewGroups`), `:84-119` (`refresh()`)

**Interfaces:**
- Consumes: `PullRequestQuery.fetch(using:limit:query:)` and `PullRequestQuery.reviewRequestedSearchQuery` from Task 1.
- Produces:
  - `PRStatusStore.reviewRequestedPRs: [PRSummary]` (read-only outside the store)
  - `PRStatusStore.reviewGroups: [PRStatusStore.Group]`

No dedicated unit tests exist for `PRStatusStore` today (it depends on `GitHubSession`/`AppSettings`, which aren't stubbed in the test target) — this task is verified by the full suite still passing and by manual verification in Task 5's final step.

- [ ] **Step 1: Add the new state and computed property**

In `Sources/PRFloat/Store/PRStatusStore.swift`, change:

```swift
    private(set) var prs: [PRSummary] = []
    private(set) var isLoading = false
```

to:

```swift
    private(set) var prs: [PRSummary] = []
    private(set) var reviewRequestedPRs: [PRSummary] = []
    private(set) var isLoading = false
```

Then, right after the existing `groups` computed property, add:

```swift
    var reviewGroups: [Group] {
        Dictionary(grouping: reviewRequestedPRs, by: \.repository)
            .map { Group(repository: $0.key, prs: $0.value.sorted { $0.number > $1.number }) }
            .sorted { $0.repository.localizedCaseInsensitiveCompare($1.repository) == .orderedAscending }
    }
```

- [ ] **Step 2: Fetch both lists concurrently in `refresh()`**

Change:

```swift
        do {
            let list = try await PullRequestQuery.fetch(using: client)
            prs = list
            errorMessage = nil
            isOffline = false
            consecutiveFailures = 0
            lastRefresh = Date()
        } catch GitHubAPIError.unauthorized {
```

to:

```swift
        do {
            async let authored = PullRequestQuery.fetch(using: client)
            async let reviewRequested = PullRequestQuery.fetch(
                using: client,
                query: PullRequestQuery.reviewRequestedSearchQuery
            )
            let (list, reviewList) = try await (authored, reviewRequested)
            prs = list
            reviewRequestedPRs = reviewList
            errorMessage = nil
            isOffline = false
            consecutiveFailures = 0
            lastRefresh = Date()
        } catch GitHubAPIError.unauthorized {
```

Leave the `catch` blocks below unchanged — on any failure, both `prs` and `reviewRequestedPRs` keep their last-good values (neither is reset), matching the existing "a failed poll must not blank the panel" behavior. Also leave this unchanged:

```swift
        guard let client = session.apiClient else {
            prs = []
            errorMessage = nil
            return
        }
```

Change it to also clear the new list when signed out:

```swift
        guard let client = session.apiClient else {
            prs = []
            reviewRequestedPRs = []
            errorMessage = nil
            return
        }
```

- [ ] **Step 3: Build and run the full test suite**

Run: `swift build && swift test`
Expected: builds cleanly, all existing tests still PASS (this task adds no new tests, since `PRStatusStore` has no test harness today).

- [ ] **Step 4: Commit**

```bash
git add Sources/PRFloat/Store/PRStatusStore.swift
git commit -m "Fetch review-requested PRs alongside authored PRs

Both searches run concurrently per refresh cycle and share the same
error/loading state, so a failed poll doesn't blank either list."
```

---

### Task 3: `AppSettings` — add the `showReviewRequests` toggle

**Files:**
- Modify: `Sources/PRFloat/Store/AppSettings.swift:26-32` (Key enum), `:44-46` (property), `:56-70` (`init`)

**Interfaces:**
- Consumes: nothing new.
- Produces: `AppSettings.showReviewRequests: Bool`, default `true`, persisted under `UserDefaults` key `"showReviewRequestsSection"`.

- [ ] **Step 1: Add the key**

Change:

```swift
    private enum Key {
        static let pollInterval = "pollIntervalSeconds"
        static let showAgents = "showAgentsSection"
        static let showPRs = "showPullRequestsSection"
        static let launchAtLogin = "launchAtLogin"
        static let alwaysOnTop = "alwaysOnTop"
    }
```

to:

```swift
    private enum Key {
        static let pollInterval = "pollIntervalSeconds"
        static let showAgents = "showAgentsSection"
        static let showPRs = "showPullRequestsSection"
        static let showReviewRequests = "showReviewRequestsSection"
        static let launchAtLogin = "launchAtLogin"
        static let alwaysOnTop = "alwaysOnTop"
    }
```

- [ ] **Step 2: Add the property**

Change:

```swift
    var showPullRequests: Bool {
        didSet { defaults.set(showPullRequests, forKey: Key.showPRs) }
    }
```

to:

```swift
    var showPullRequests: Bool {
        didSet { defaults.set(showPullRequests, forKey: Key.showPRs) }
    }

    var showReviewRequests: Bool {
        didSet { defaults.set(showReviewRequests, forKey: Key.showReviewRequests) }
    }
```

- [ ] **Step 3: Register the default and read it in `init`**

Change:

```swift
        defaults.register(defaults: [
            Key.pollInterval: PollInterval.oneMinute.rawValue,
            Key.showAgents: true,
            Key.showPRs: true,
            Key.alwaysOnTop: true,
            Key.launchAtLogin: false
        ])
        self.pollInterval = PollInterval(rawValue: defaults.integer(forKey: Key.pollInterval)) ?? .oneMinute
        self.showAgents = defaults.bool(forKey: Key.showAgents)
        self.showPullRequests = defaults.bool(forKey: Key.showPRs)
        self.alwaysOnTop = defaults.bool(forKey: Key.alwaysOnTop)
        self.launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
```

to:

```swift
        defaults.register(defaults: [
            Key.pollInterval: PollInterval.oneMinute.rawValue,
            Key.showAgents: true,
            Key.showPRs: true,
            Key.showReviewRequests: true,
            Key.alwaysOnTop: true,
            Key.launchAtLogin: false
        ])
        self.pollInterval = PollInterval(rawValue: defaults.integer(forKey: Key.pollInterval)) ?? .oneMinute
        self.showAgents = defaults.bool(forKey: Key.showAgents)
        self.showPullRequests = defaults.bool(forKey: Key.showPRs)
        self.showReviewRequests = defaults.bool(forKey: Key.showReviewRequests)
        self.alwaysOnTop = defaults.bool(forKey: Key.alwaysOnTop)
        self.launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
```

- [ ] **Step 4: Build to verify it compiles**

Run: `swift build`
Expected: succeeds with no errors or warnings about unused/uninitialized properties.

- [ ] **Step 5: Commit**

```bash
git add Sources/PRFloat/Store/AppSettings.swift
git commit -m "Add showReviewRequests setting, default on"
```

---

### Task 4: `SettingsView` — expose the toggle

**Files:**
- Modify: `Sources/PRFloat/UI/SettingsView.swift:102-105`

**Interfaces:**
- Consumes: `AppSettings.showReviewRequests` from Task 3.
- Produces: nothing consumed by later tasks (UI leaf).

- [ ] **Step 1: Add the toggle**

Change:

```swift
            Section("Show") {
                Toggle("Agents", isOn: $settings.showAgents)
                Toggle("Pull requests", isOn: $settings.showPullRequests)
            }
```

to:

```swift
            Section("Show") {
                Toggle("Agents", isOn: $settings.showAgents)
                Toggle("Pull requests", isOn: $settings.showPullRequests)
                Toggle("PRs to review", isOn: $settings.showReviewRequests)
            }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/PRFloat/UI/SettingsView.swift
git commit -m "Add PRs-to-review toggle to Settings > General"
```

---

### Task 5: `ContentView` — render the "PRs to Review" section

**Files:**
- Modify: `Sources/PRFloat/UI/ContentView.swift:124-137` (`collapsedLabel`), `:209-230` (`overviewBody`), add a new `reviewRequestsSection` view near `pullRequestsSection` (`:261-305`)
- Modify: `README.md:129-134` (remove the "Not included" line)

**Interfaces:**
- Consumes: `store.reviewRequestedPRs`, `store.reviewGroups` (Task 2), `settings.showReviewRequests` (Task 3), existing `PRRowView`, `SectionHeader`, `EmptyStateView`, `SkeletonRow`, `Theme.Space`.
- Produces: nothing consumed by later tasks (this is the last task).

- [ ] **Step 1: Update `collapsedLabel` to include a review count**

Change:

```swift
    private var collapsedLabel: String {
        guard store.session.isSignedIn else { return "Sign in to GitHub" }

        var parts: [String] = []
        let count = store.prs.count
        if settings.showPullRequests {
            parts.append(count == 0 ? "No PRs" : "\(count) PR\(count == 1 ? "" : "s")")
        }
        if settings.showAgents, let agentSummary = agentStore.summaryLine {
            parts.append(agentSummary)
        }
        if parts.isEmpty { return "PR Float" }
        return parts.joined(separator: " · ")
    }
```

to:

```swift
    private var collapsedLabel: String {
        guard store.session.isSignedIn else { return "Sign in to GitHub" }

        var parts: [String] = []
        let count = store.prs.count
        if settings.showPullRequests {
            parts.append(count == 0 ? "No PRs" : "\(count) PR\(count == 1 ? "" : "s")")
        }
        if settings.showReviewRequests {
            let reviewCount = store.reviewRequestedPRs.count
            if reviewCount > 0 {
                parts.append("\(reviewCount) to review")
            }
        }
        if settings.showAgents, let agentSummary = agentStore.summaryLine {
            parts.append(agentSummary)
        }
        if parts.isEmpty { return "PR Float" }
        return parts.joined(separator: " · ")
    }
```

(The review count is omitted from the collapsed strip entirely when zero, since "0 to review" is noise the other two parts don't have — they always show a count, including zero, but review-requests is additive context, not the panel's primary purpose.)

- [ ] **Step 2: Add `reviewRequestsSection` and wire it into `overviewBody`**

Change:

```swift
    private var overviewBody: some View {
        VStack(spacing: 0) {
            if let error = store.errorMessage {
                banner(error, offline: store.isOffline)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if settings.showAgents {
                        agentsSection
                    }
                    if settings.showPullRequests {
                        pullRequestsSection
                    }
                }
                .padding(.bottom, Theme.Space.sm)
            }

            Divider()
            footer
        }
    }
```

to:

```swift
    private var overviewBody: some View {
        VStack(spacing: 0) {
            if let error = store.errorMessage {
                banner(error, offline: store.isOffline)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if settings.showAgents {
                        agentsSection
                    }
                    if settings.showPullRequests {
                        pullRequestsSection
                    }
                    if settings.showReviewRequests {
                        reviewRequestsSection
                    }
                }
                .padding(.bottom, Theme.Space.sm)
            }

            Divider()
            footer
        }
    }
```

Then, immediately after the existing `pullRequestsSection` (which ends right before the `// MARK: - Chrome` comment), add:

```swift
    // MARK: - Reviews

    @ViewBuilder
    private var reviewRequestsSection: some View {
        Section {
            if store.isLoading && !store.hasData {
                VStack(spacing: Theme.Space.sm) {
                    SkeletonRow()
                    SkeletonRow()
                }
                .padding(.horizontal, Theme.Space.md)
            } else if store.reviewRequestedPRs.isEmpty {
                EmptyStateView(
                    title: "Nothing waiting on your review",
                    systemImage: "checkmark.circle",
                    message: nil
                )
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    ForEach(store.reviewGroups) { group in
                        VStack(alignment: .leading, spacing: Theme.Space.sm) {
                            if store.reviewGroups.count > 1 {
                                Text(group.repository)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            ForEach(group.prs) { pr in
                                PRRowView(pr: pr, agents: []) {
                                    store.openPR(pr)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.md)
            }
        } header: {
            SectionHeader(
                title: "PRs to Review",
                count: store.reviewRequestedPRs.isEmpty ? nil : store.reviewRequestedPRs.count
            )
            .background(.regularMaterial)
        }
    }
```

This mirrors `pullRequestsSection` but always passes `agents: []` to `PRRowView` (agent correlation only makes sense for branches the user is running agents on, not other people's branches), and has no "no open PRs" error-dependent copy since a review list being empty isn't itself an error state.

- [ ] **Step 3: Update the README**

In `README.md`, remove the review-requested line from "Not included":

```markdown
## Not included

- Cloud agents (Claude on the web, Copilot agent) — local sessions only
- Controlling agents from the panel; it is a read-only view
- Review-requested PRs (authored only)
- Multiple GitHub accounts, GitHub Enterprise Server
```

becomes:

```markdown
## Not included

- Cloud agents (Claude on the web, Copilot agent) — local sessions only
- Controlling agents from the panel; it is a read-only view
- Multiple GitHub accounts, GitHub Enterprise Server
```

Also update the "Settings" section list of what General controls — change:

```markdown
- **General** — poll interval (30s / 1m / 5m / manual), which sections show, launch at login
```

This line is already generic ("which sections show") and needs no edit.

And update the "Usage" section's panel description to mention the new section. Change:

```markdown
**Pull Requests** — your open PRs, grouped by repository, with checklist progress from the
PR body (`- [ ]` / `- [x]`), a CI summary, a Draft pill, and an agent badge where one is
working on that branch. Double-click a row, or use the arrow button, to open it on GitHub.
```

to:

```markdown
**Pull Requests** — your open PRs, grouped by repository, with checklist progress from the
PR body (`- [ ]` / `- [x]`), a CI summary, a Draft pill, and an agent badge where one is
working on that branch. Double-click a row, or use the arrow button, to open it on GitHub.

**PRs to Review** — open PRs where you're requested as a reviewer, in the same grouped
layout. A PR drops off this list once you submit a review (unless re-requested).
```

- [ ] **Step 4: Build and run the full test suite**

Run: `swift build && swift test`
Expected: builds cleanly, all tests PASS (13 tests from `PullRequestQueryTests` including Task 1's additions, plus every other existing suite).

- [ ] **Step 5: Manually verify in the running app**

Run: `swift run PRFloat`

- Sign in with GitHub if not already.
- Confirm a new "PRs to Review" section appears below "Pull Requests" (or the empty state "Nothing waiting on your review" if you have none pending).
- Open Settings (⌘,) → General, confirm the "PRs to review" toggle is present and checked; toggle it off and confirm the section disappears from the panel; toggle it back on.
- Collapse the panel (chevron in the header) and confirm the collapsed strip shows a "N to review" segment only when the count is nonzero.

- [ ] **Step 6: Commit**

```bash
git add Sources/PRFloat/UI/ContentView.swift README.md
git commit -m "Add PRs to Review section to the panel

Closes the review-requested gap noted in the README's Not included
list. Reuses PRRowView; agent badges are skipped since agent
correlation only applies to branches you're running agents on."
```

---

## Self-Review Notes

- **Spec coverage:** every section of the design doc (`docs/2026-08-12-pr-review-requests-design.md`) maps to a task — data layer → Task 1, store → Task 2, settings → Tasks 3–4, UI + docs → Task 5. Testing scope matches the design's "no new fixture, no new SwiftUI tests" call.
- **Type consistency:** `reviewRequestedPRs: [PRSummary]`, `reviewGroups: [Group]`, `PullRequestQuery.reviewRequestedSearchQuery: String`, and the `fetch(using:limit:query:)` signature are used identically across Tasks 1, 2, and 5.
- **No placeholders:** every step has literal code to write, not a description of what to write.
