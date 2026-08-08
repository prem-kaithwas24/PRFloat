# PR Float v2 — Design Spec

**Date:** 2026-08-08
**Status:** Approved for implementation planning
**Supersedes:** parts of `2026-08-06-pr-float-design.md` (data layer, UI shell)
**Platform:** macOS 14+ (SwiftUI + AppKit)

## 1. Problem

v1 shipped a floating panel that reads PRs through the `gh` CLI for one user-selected
folder. Three gaps make it feel like a prototype:

1. **Auth is invisible and fragile.** The app silently assumes `gh` is installed and
   authenticated. When it is not, the user gets an error string instead of a way in.
2. **Scope is one folder.** Watching a repo means picking a filesystem path, and only
   one at a time — even though the user's PRs span many repos.
3. **No agent visibility.** Multiple Claude Code sessions run concurrently on this Mac.
   Nothing shows which are working, which are finished, and which are blocked waiting.

## 2. Goals

- **Sign in to GitHub inside the app** via OAuth device flow; no `gh` dependency.
- **Show every open PR authored by the signed-in user**, across all accessible repos.
- **Show every live Claude Code session** with in-progress / finished / blocked status,
  what it is working on, and which PR it maps to.
- **Look and behave like a shipped product**: considered visuals, a Settings window,
  resilient error handling, and an installable bundle.

## 3. Non-goals

- Review-requested or assigned PRs (authored only, as in v1).
- Multi-account GitHub support (one signed-in account).
- GitHub Enterprise Server hosts.
- Cloud/remote agents (Claude on the web, Copilot agent) — local sessions only.
- Controlling agents from the panel (read-only view; no send/stop/reply).
- Editing checklist items from the app.
- Windows / Linux.

## 4. Phasing

Each phase is independently shippable and leaves the app in a working state.

| Phase | Delivers | Done when |
|-------|----------|-----------|
| **1** | Native auth + GitHub API; `GitHubCLIService` deleted | User signs in, sees all their open PRs, no `gh` installed |
| **2** | Agents section + PR correlation | Live sessions listed with status and task; badges appear on matching PR rows |
| **3** | Professional shell: visual redesign, Settings, robustness, packaging | Settings window works, offline/expiry states are graceful, `.app` installs |

## 5. Architecture

```
┌──────────────────────────────────────────────────────────┐
│ PRFloat (app target — AppKit + SwiftUI)                  │
│   AppDelegate · FloatingPanelController · StatusItem     │
│   ContentView · AgentSectionView · PRSectionView         │
│   SettingsWindow · SignInView                            │
│                        │                                 │
│            ┌───────────┴────────────┐                    │
│            ▼                        ▼                    │
│   ┌─────────────────┐      ┌──────────────────┐          │
│   │ PRStatusStore   │      │ AgentStore       │          │
│   │ @Observable     │      │ @Observable      │          │
│   └────────┬────────┘      └────────┬─────────┘          │
└────────────┼────────────────────────┼────────────────────┘
             ▼                        ▼
┌──────────────────────────────────────────────────────────┐
│ PRFloatCore (no AppKit — fully testable)                 │
│                                                          │
│  Auth/     DeviceFlowClient · TokenStore · GitHubSession │
│  GitHub/   GitHubAPIClient · PullRequestQuery            │
│  Agents/   SessionRegistry · TranscriptReader ·          │
│            RepoResolver · AgentCorrelator                │
│  Models/   PRSummary · CheckSummary · AgentSession       │
│            AgentStatus · GitHubAccount                   │
│  Net/      HTTPClient (protocol) · URLSessionHTTPClient  │
└──────────────────────────────────────────────────────────┘
```

### Module responsibilities

| Type | Responsibility | Depends on |
|------|----------------|------------|
| `DeviceFlowClient` | Requests a device code, polls for the access token, classifies GitHub's flow errors. | `HTTPClient` protocol |
| `TokenStore` | Protocol for read/write/delete of the token. `KeychainTokenStore` is the real impl; tests use an in-memory fake. | Security.framework |
| `GitHubSession` | Owns signed-in state: token + `GitHubAccount`. Publishes `.signedOut / .signingIn(code) / .signedIn(account) / .expired`. | `TokenStore`, `GitHubAPIClient` |
| `GitHubAPIClient` | One `URLSession` wrapper: bearer auth, GraphQL POST, rate-limit and retry policy, typed errors. | `HTTPClient` protocol |
| `PullRequestQuery` | The GraphQL document plus decoding into `[PRSummary]`. Pure given a payload. | Models |
| `SessionRegistry` | Reads `~/.claude/sessions/*.json`, prunes dead PIDs, returns `[AgentSession]`. | FileManager, `kill(2)` |
| `TranscriptReader` | Extracts the most recent real user prompt from a session transcript by reverse-chunked read. Caches on `(mtime, size)`. | FileManager |
| `RepoResolver` | Maps a working directory to `owner/repo` + current branch by reading `.git/config` and `.git/HEAD`. | FileManager |
| `AgentCorrelator` | Pure function: `([AgentSession], [PRSummary]) -> [PRNumber: [AgentSession]]`. | Models |
| `PRStatusStore` | Poll timer, in-flight coalescing, last-good-data retention, error surface. | Core |
| `AgentStore` | FSEvents watch + safety poll, status-transition tracking for "just finished". | Core |

`GitHubCLIService` is **deleted** in Phase 1. Keeping both a CLI and an API path would
double the error surface for no benefit once a native token exists.

## 6. Authentication

### Flow

1. **Request a code.** `POST https://github.com/login/device/code`
   with `client_id` and `scope=repo read:org`, `Accept: application/json`.
   Response: `device_code`, `user_code`, `verification_uri`, `expires_in`, `interval`.
2. **Present it.** The panel shows the `user_code` in a large monospaced field with a
   **Copy & Open GitHub** button that copies the code and opens `verification_uri`.
   A countdown reflects `expires_in`.
3. **Poll for the token.** `POST https://github.com/login/oauth/access_token`
   with `client_id`, `device_code`, and
   `grant_type=urn:ietf:params:oauth:grant-type:device_code`, every `interval` seconds.

   | Response `error` | Handling |
   |------------------|----------|
   | `authorization_pending` | Keep polling — this is the normal case |
   | `slow_down` | Increase interval by the returned `interval`, keep polling |
   | `expired_token` | Stop; show "Code expired" with a Try Again button |
   | `access_denied` | Stop; return to signed-out state |
   | `incorrect_device_code` | Stop; treat as an internal error |

4. **Persist.** Store the access token in the Keychain: `kSecClassGenericPassword`,
   service `com.prfloat.github`, account = the GitHub login, accessibility
   `kSecAttrAccessibleAfterFirstUnlock` (the app may refresh before the user unlocks).
5. **Identify.** `GET https://api.github.com/user` → login, name, avatar URL. The avatar
   is fetched once and cached on disk in Application Support.

### Client ID

Device flow requires an OAuth App registered on GitHub with **Enable Device Flow**
checked. The client ID is not a secret and ships in the bundle, read in this order:

1. `PRFloatGitHubClientID` from `Info.plist` (build-time default)
2. A user-supplied override in Settings → Account, stored in `UserDefaults`

If neither is present the sign-in view explains what to register and links to
`https://github.com/settings/developers`. **This is an external setup step the user must
perform once.**

### Sign out

Deletes the Keychain item, clears cached PRs and the avatar, returns to `.signedOut`.
Agent tracking is unaffected — it needs no GitHub credentials.

## 7. Fetching pull requests

A single GraphQL request replaces v1's per-repo CLI invocations:

```graphql
query($q: String!) {
  search(query: $q, type: ISSUE, first: 50) {
    nodes {
      ... on PullRequest {
        number title url body headRefName isDraft updatedAt
        repository { nameWithOwner }
        reviewDecision
        commits(last: 1) {
          nodes { commit { statusCheckRollup {
            state
            contexts(first: 100) { nodes {
              ... on CheckRun    { name status conclusion }
              ... on StatusContext { context state }
            }}
          }}}
        }
      }
    }
  }
}
```

with `q = "is:pr is:open author:@me archived:false"`.

- **Checks.** `contexts` mixes `CheckRun` (`status` + `conclusion`) and `StatusContext`
  (`state`). The existing `CheckSummary.from(rollup:)` already normalises both; its
  redundant duplicate branch is cleaned up as part of this work.
- **Checklist.** Unchanged — `ChecklistParser` over the PR `body`.
- **Grouping.** Rows group under `repository.nameWithOwner` headers, sorted by repo name
  then PR number descending. Single-repo results skip the header.
- **Rate limit.** GraphQL allows 5000 points/hour; one poll per 60s costs ~60/hour.

## 8. Agent tracking

### Source of truth

`~/.claude/sessions/<pid>.json`, one small file per session. Observed shape:

```json
{"pid":28408,"sessionId":"ca610c24-…","cwd":"/Users/josh/non-moxi/PRFloat",
 "startedAt":1786155797785,"version":"2.1.224","kind":"interactive",
 "entrypoint":"cli","tmux":"hq-boot:@109.%109","name":"prfloat-6a",
 "status":"busy","statusUpdatedAt":1786157154547,"waitingFor":"dialog open"}
```

All fields beyond `pid`, `cwd`, and `status` are decoded optionally — the format belongs
to another application and may change. An unparseable file is skipped, not fatal.

### Watching

A `DispatchSource` file-system watch on the sessions **directory** gives near-instant
reaction to status changes, backed by a 5-second poll in case an event is missed. Reading
all files is cheap (a handful of sub-1KB files).

### Liveness

`kill(pid, 0)`: success or `EPERM` means the process is alive; `ESRCH` means it is gone
and the entry is pruned from the list. This guards against stale files left by crashes.

### Status mapping

| Registry `status` | Panel state | Treatment |
|-------------------|-------------|-----------|
| `busy` | **Working** | Blue dot with a slow pulse; elapsed time since `statusUpdatedAt` |
| `idle` | **Done** | Green dot; "finished 4m ago" |
| `waiting` | **Needs you** | Amber dot; shows `waitingFor` verbatim (e.g. "dialog open") |
| anything else | **Unknown** | Grey dot; raw value shown |

`AgentStore` remembers the previous status of each PID across polls. A `busy → idle`
transition within the last **5 minutes** is flagged `justFinished`, which gets a stronger
visual treatment — that transition is the moment the user actually cares about. The flag
decays on its own; it is derived state, never persisted.

### Task text

`TranscriptReader` finds the most recent genuine user prompt in that session's transcript.

**Locating the transcript.** Transcripts live at `~/.claude/projects/<slug>/<sessionId>.jsonl`,
where `<slug>` is a mangled form of `cwd` — observed to replace `/` and `.` with `-`, but
the full escaping rule is another application's private detail and is not safe to
reimplement. Instead the reader **globs `~/.claude/projects/*/<sessionId>.jsonl`**: the
session ID is unique, so the match is exact, and it costs one shallow directory listing
(~21 entries on this machine). Directory names are cached and rescanned only on a miss.

**A fixed byte-tail does not work.** Measured against real transcripts, the last user
message sat 100–180 lines from the end, buried under tool results — a 200KB tail found
nothing. The reader therefore:

1. Reads the last 256KB, scans backwards line by line for the first record with
   `type == "user"`, `isSidechain != true`, `isMeta != true`, and text content that is
   not a `<…>` wrapper block (system reminders, command wrappers) or a tool result.
2. If none is found, doubles the window and retries, capped at 4MB.
3. Returns `nil` past the cap — the row shows the session name alone.

Results cache on `(path, mtime, size)`, so a poll where nothing changed does no I/O.
Text is truncated to one line for display, with the full text in the tooltip.

### Correlation with PRs

`RepoResolver` maps a session's `cwd` to a repository:

1. Walk up from `cwd` to find `.git` (handles subdirectory sessions and worktree files).
2. Parse `.git/config` for `[remote "origin"] url`, normalising both SSH
   (`git@github.com:owner/repo.git`) and HTTPS forms to `owner/repo`.
3. Read `.git/HEAD` for `ref: refs/heads/<branch>`; detached HEAD yields no branch.

`AgentCorrelator` then matches on `(nameWithOwner, headRefName)`. Matching agents render
as a badge on that PR row; every session still appears in the Agents section regardless of
whether it matched. Resolution results cache per directory, invalidated on `.git/HEAD`
mtime change.

## 9. User interface

### Panel

- Default **360×480**, resizable, min 320×280. Always-on-top, position persisted.
- `.regularMaterial` background; full light/dark support using semantic colors only.
- Layout: header → Agents section → Pull Requests section → footer.
- 4pt spacing grid. Type scale limited to `headline` / `subheadline` / `caption` /
  `caption2`; no ad-hoc font sizes.
- Section headers are sticky, uppercase `caption2`, secondary, with a count.

### Header

Avatar (circular, 20pt) · account login · spacer · refresh · collapse. Signed out, the
header shows the app name and a **Sign in** button instead.

### Agent row

```
● prfloat-6a                              Working · 2m
  PRFloat · main
  "make it professional, git login and fetch PRs"
```

Status dot, session name, status label with elapsed time, then `repo · branch` (falling
back to the folder name when the directory is not a repo), then the one-line task text.
Rows are ordered: **Needs you** → **Working** → **Just finished** → **Done**, each group
by most recent `statusUpdatedAt`.

### PR row

Retains v1's content — health dot, `#number`, title, checklist progress, checks summary,
head branch — refined to the new type and spacing scale, plus:

- Repo name in the group header rather than per row.
- A **Draft** pill when `isDraft`.
- An agent badge (`◍ prfloat-6a`) when a session matches, tinted by that agent's status.

### Collapsed strip

`3 PRs · 2 agents working`, or `2 agents need you` when anything is blocked, since that
outranks everything else. Signed out: `Sign in to GitHub`.

### States

| Condition | Treatment |
|-----------|-----------|
| Signed out | Sign-in view with a single primary button |
| Signing in | Large `user_code`, Copy & Open GitHub, countdown, Cancel |
| Token expired | "Session expired" banner + Sign in again; PR list dims but is retained |
| Loading, no data | Skeleton rows, not a spinner |
| Loading, has data | Existing rows stay; refresh control animates |
| No PRs | "No open PRs by you" |
| No agents | "No Claude Code sessions running" |
| Offline / refresh failed | Footer reads "Offline · last updated 14:22"; data retained |
| Rate limited | "GitHub rate limit — retrying at 14:45" |

### Settings window (⌘,)

| Tab | Contents |
|-----|----------|
| **Account** | Avatar, login, Sign Out; OAuth client ID override field |
| **General** | Poll interval (30s/60s/5m/manual), launch at login, show/hide each section |
| **Panel** | Always-on-top toggle, show on all Spaces, reset position |

## 10. Robustness

- **A failed refresh never clears good data.** `PRStatusStore` writes `prs` only on
  success; failures set a banner and leave the list intact.
- **401** → `GitHubSession` moves to `.expired`, distinct from `.signedOut`, so the UI can
  say why rather than showing an empty list.
- **403 / rate limit** → honour `x-ratelimit-reset`, exponential backoff with jitter,
  capped at 15 minutes; the next attempt time is shown.
- **Offline** → `NSURLErrorNotConnectedToInternet` and friends map to an offline state
  rather than a generic error; polling continues quietly.
- **Timeouts** → 30s request timeout, single retry for idempotent GETs.
- **Agent list degradation** → a malformed or unreadable session file is skipped
  individually; the rest of the list renders.
- **Missing `~/.claude/sessions`** → the Agents section shows its empty state, no error.
- **No token in Keychain but signed-in flag set** → treated as signed out.

## 11. Packaging

- App icon (`.icns`, full size set) and an About panel with version and build.
- `Info.plist`: `LSUIElement`, `CFBundleShortVersionString`, `CFBundleVersion`,
  `NSHumanReadableCopyright`.
- Launch at login via `SMAppService.mainApp` (macOS 13+), surfaced in Settings.
- `scripts/package-app.sh` extended: build, assemble bundle, **ad-hoc sign**.
- `scripts/notarize.sh` added, driving `codesign --options runtime` +
  `xcrun notarytool submit` + `stapler`, reading `DEVELOPER_ID` from the environment.

> **Constraint:** this Mac reports `0 valid identities found` for code signing. The app
> ships ad-hoc signed; the notarize script is wired and documented but cannot run until a
> Developer ID exists. The README documents the Gatekeeper first-run step
> (`xattr -d com.apple.quarantine`) for ad-hoc builds.

## 12. Testing

| Layer | Coverage |
|-------|----------|
| `DeviceFlowClient` | Stubbed `URLProtocol`: happy path, `authorization_pending` then success, `slow_down` interval increase, `expired_token`, `access_denied`, malformed JSON |
| `TokenStore` | In-memory fake exercises the protocol contract; one integration test against the real Keychain, round-tripping and deleting |
| `GitHubSession` | State transitions: signed out → signing in → signed in → expired → signed out |
| `GitHubAPIClient` | 401 / 403+reset / 5xx / offline mapping; backoff schedule is a pure function under test |
| `PullRequestQuery` | Recorded GraphQL fixtures → `[PRSummary]`: mixed `CheckRun`/`StatusContext`, no checks, empty body, draft, multi-repo |
| `SessionRegistry` | Temp-dir fixtures: valid set, malformed file among valid ones, dead PID pruned, missing directory |
| `TranscriptReader` | Locates a transcript by session ID across several project dirs; missing transcript; prompt 200 lines deep (the measured real case), no user message at all, corrupt lines, sidechain/meta skipped, cap exceeded, cache hit does no re-read |
| `RepoResolver` | SSH and HTTPS remotes, nested subdirectory, detached HEAD, no remote, not a repo |
| `AgentCorrelator` | Match, no match, two agents on one PR, same branch across different repos |
| `AgentStore` | `busy → idle` sets `justFinished`; flag decays after 5 minutes; ordering rules |
| `ChecklistParser`, `CheckSummary` | Existing v1 tests retained |
| Manual | Real sign-in; expired token; airplane mode; several concurrent sessions; agent badge appearing on a real PR |

Tests continue to use swift-testing so `swift test` runs without Xcode.app.

## 13. Success criteria

1. A user with no `gh` installed signs in from the panel and sees their PRs.
2. Open PRs across every accessible repo appear, grouped by repo, with accurate checklist
   and check counts.
3. Every live Claude Code session is listed; starting one makes it appear, and its status
   tracks working / finished / blocked without a manual refresh.
4. A session that finishes is visibly distinguishable from one that has been idle a while.
5. An agent working on a branch with an open PR is badged on that PR's row.
6. Killing a session removes it from the list within 5 seconds.
7. Pulling the network shows an offline state and retains the last data.
8. Signing out clears credentials; relaunching returns to the sign-in view.
9. Settings changes take effect without relaunch.
10. `swift test` passes without Xcode.app.

## 14. Open items

| Item | Owner | Blocking |
|------|-------|----------|
| Register a GitHub OAuth App with device flow enabled; supply the client ID | User | Phase 1 sign-in works only with a client ID |
| Apple Developer ID for signing and notarization | User | Phase 3 notarization only; ad-hoc builds work |

## 15. Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Auth mechanism | OAuth device flow, Keychain storage | No `gh` dependency; works for any user; no secret to ship |
| Keep `gh` as fallback | No — delete it | Two data paths double the error surface for no gain |
| PR scope | All open PRs authored by me, all repos | The token already knows who the user is; folder picking becomes pointless |
| Agent source | `~/.claude/sessions/*.json` | Purpose-built registry with the exact status field needed; no log scraping |
| Agent kinds | Local sessions only | Matches the stated need; cloud agents deferred |
| Session scope | All live sessions on the machine | User wants to see every running agent, not just PR-related ones |
| "Finished" definition | `idle`, with a 5-minute `justFinished` highlight | The registry has no terminal state; idle *is* "handed back to you" |
| Task text | Last user prompt, reverse-chunked read, cached | Makes "whose task" literal at negligible I/O cost |
| Exited sessions | Pruned, not retained | User chose live-only; retention can come later if missed completions hurt |
