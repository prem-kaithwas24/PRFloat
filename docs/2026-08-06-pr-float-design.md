# PR Float — Design Spec

**Date:** 2026-08-06  
**Status:** Approved for implementation planning  
**Platform:** macOS (SwiftUI + AppKit)

## 1. Problem

While coding, you need a glanceable view of whether **your open PRs** in the **current repo** are checklist-complete and CI-healthy—without switching to the browser or terminal.

## 2. Goals (v1)

- Small **floating, always-on-top** window on macOS.
- Show **open PRs authored by you** in a **user-selected repo** (current working repo).
- For each PR:
  - Number, title, head branch
  - **Markdown checklist** progress from PR body (`- [ ]` / `- [x]`, also `* [ ]` variants)
  - **CI / checks** summary (pass / fail / pending)
  - **Open in browser** action
- Data via **GitHub CLI** (`gh`) already authenticated on the Mac.
- Menu bar control: show/hide panel, quit.
- Manual refresh + periodic poll (~60s).

## 3. Non-goals (v1)

- Agent highlights (Claude, Grok, etc.) — deferred; leave a clear extension point only if trivial.
- Multi-repo aggregation.
- Review-requested / assigned PRs (authored only).
- Direct GitHub REST/GraphQL with PAT (use `gh` only).
- Windows/Linux.
- Editing checklist items from the app.
- Push notifications / system alerts (optional later).

## 4. Architecture

```
┌─────────────────────────────────────────┐
│  PR Float (SwiftUI + AppKit)            │
│  ┌─────────────┐  ┌──────────────────┐  │
│  │ Floating    │  │ Menu bar icon    │  │
│  │ Panel UI    │  │ show/hide panel  │  │
│  └──────┬──────┘  └────────┬─────────┘  │
│         │                  │            │
│         ▼                  ▼            │
│  ┌──────────────────────────────────┐   │
│  │ PRStatusStore (Observable)       │   │
│  │ - selectedRepoPath               │   │
│  │ - prs: [PRSummary]               │   │
│  │ - refresh() on timer + manual    │   │
│  └──────────────┬───────────────────┘   │
│                 ▼                       │
│  ┌──────────────────────────────────┐   │
│  │ GitHubCLIService                 │   │
│  │ Process: gh pr list / view /     │   │
│  │          checks  (cwd = repo)    │   │
│  └──────────────────────────────────┘   │
└─────────────────────────────────────────┘
```

| Component | Responsibility |
|-----------|----------------|
| **App entry** | Menu bar-only app (LSUIElement-style or accessory policy); no Dock icon required. |
| **Floating panel** | `NSPanel`: utility/HUD, floating level, can become key for scroll/clicks, draggable, remembers position. |
| **Menu bar** | `NSStatusItem`: toggle panel visibility, Refresh, Choose Repo, Quit. |
| **PRStatusStore** | Observable state: repo path, PR list, last refresh, errors, loading. Timer + manual refresh. |
| **GitHubCLIService** | Runs `gh` via `Process` with `currentDirectoryURL` = selected repo; returns typed models. |
| **ChecklistParser** | Pure functions: count completed/total from PR body markdown. |
| **Persistence** | `UserDefaults`: `repoPath`, window frame, poll interval seconds (default 60). |

### Project layout

```
PRFloat/
  PRFloat.xcodeproj             # macOS App target (required for .app + menu bar)
  PRFloat/
    App/
      PRFloatApp.swift
      AppDelegate.swift         # status item + panel lifecycle
    UI/
      FloatingPanelController.swift
      ContentView.swift
      PRRowView.swift
      EmptyStateView.swift
    Models/
      PRSummary.swift
      CheckStatus.swift
    Services/
      GitHubCLIService.swift
      ChecklistParser.swift
    Store/
      PRStatusStore.swift
    Resources/
      Assets.xcassets
      Info.plist                # LSUIElement = true (menu bar app)
  PRFloatTests/
    ChecklistParserTests.swift
    CheckSummaryTests.swift
    Fixtures/
      pr-list-sample.json
  README.md
```

**Delivery form (v1):** **Xcode macOS App** only (SwiftUI lifecycle + AppKit `NSPanel`). Not a pure SwiftPM executable—menu bar + floating panel need a proper `.app` bundle.

## 5. UI

### Window

- Default size ~**320×400**, resizable within min/max bounds (min ~280×200).
- Always on top (`floating` / `statusBar` window level).
- Compact chrome: title “PR Float”, repo short name, Refresh, collapse.
- Collapse: thin strip showing “N PRs · M need attention”; click to expand.
- Dark-mode friendly system materials (`.hudWindow` / `.popover` material if available).

### Per-PR row

- `#number` + title (one line, truncate)
- Checklist progress bar + `done/total` (hide bar if total == 0; show “No checklist”)
- Checks line: e.g. “CI passing”, “2 failing”, “3 pending” with color
- Head branch (secondary text)
- **Open ↗** opens PR `url` via `NSWorkspace`

### Empty / error states

| Condition | Message |
|-----------|---------|
| No repo selected | “Choose a git repo to watch” + button |
| Not a git repo / no remote | “Folder is not a GitHub repo `gh` can use” |
| `gh` missing | “Install GitHub CLI (`gh`) and ensure it is on PATH” |
| Not authenticated | “Run `gh auth login` in Terminal” |
| No open authored PRs | “No open PRs by you in this repo” |
| `gh` error | Show stderr snippet / exit code; keep last good data if any |

### Overall health color (per PR)

- **Green:** checklist complete (or no checklist) AND no failing checks AND no pending required checks (if pending exist, prefer yellow)
- **Yellow:** incomplete checklist OR pending checks
- **Red:** any failing check

## 6. Data flow

### Selecting repo

1. User picks folder via `NSOpenPanel` (directories only).
2. Store absolute path in `UserDefaults` + `PRStatusStore`.
3. All `gh` invocations use that path as `cwd`.

### Fetch open PRs

```bash
gh pr list --author @me --state open --limit 20 \
  --json number,title,headRefName,url,body,statusCheckRollup
```

Parse JSON into `[PRSummary]`.

### Checklist

From `body` string:

- Match lines roughly: `^\s*[-*]\s*\[([ xX])\]\s+`
- `total` = matches; `done` = those with `x`/`X`
- v1 uses simple line regex (does not skip fenced code blocks).

### Checks summary

Prefer rollup from `statusCheckRollup` on list response when present.

Fallback / detail:

```bash
gh pr checks <number> --json name,state,bucket
```

Map states into: failing count, pending count, passing count.

### Refresh policy

- On launch (if repo set)
- On manual Refresh
- On repo change
- Timer every **60 seconds** (configurable later; constant in v1)
- Coalesce: ignore overlapping refreshes (single in-flight flag)

### Open in browser

`NSWorkspace.shared.open(url)` using PR `url` from `gh`.

## 7. Models (v1)

```swift
struct PRSummary: Identifiable, Equatable {
    var id: Int { number }
    let number: Int
    let title: String
    let headRefName: String
    let url: URL
    let checklistDone: Int
    let checklistTotal: Int
    let checks: CheckSummary
}

struct CheckSummary: Equatable {
    let passing: Int
    let failing: Int
    let pending: Int
    // derived: overall enum green/yellow/red
}
```

## 8. Error handling

- Catch non-zero `gh` exit; surface `localizedDescription` + truncated stderr.
- Detect common cases via message/exit: auth, missing binary, not a repo.
- Never crash the panel on parse failure; show error banner, keep previous PRs if refresh fails mid-poll.
- Timeout: kill `Process` after ~30s; show “`gh` timed out”.

## 9. Security & privacy

- No tokens stored by the app; relies on `gh`’s existing credentials.
- Only runs `gh` and opens HTTPS PR URLs; no shell metacharacters—pass arguments as argv array, never `bash -c`.
- Repo path is local filesystem only.

## 10. Testing

| Layer | What |
|-------|------|
| Unit | `ChecklistParser` (empty body, mixed checked, nested indentation, no tasks) |
| Unit | Check rollup → green/yellow/red mapping |
| Unit | JSON fixtures → `PRSummary` decoding (sample `gh` output files) |
| Manual | Real repo with open PR; unauthenticated; bad path; collapse/expand; always-on-top over fullscreen apps if possible |

## 11. Future (not v1)

- Agent highlights panel (Claude / Grok session summaries from local logs or APIs)
- Multi-repo watch list
- Click checklist item deep-link to GitHub
- Sparkle / brew cask distribution
- Notifications when checks go red

## 12. Success criteria

1. App runs as menu bar + floating panel without a Dock icon (or optional Dock—prefer accessory).
2. User selects a repo once; on relaunch it restores and refreshes.
3. Open PRs by `@me` appear with accurate checklist counts for standard GitHub task lists.
4. CI failing/pending/passing is visible without opening the browser.
5. “Open” navigates to the correct PR URL.
6. Missing `gh` / auth / empty list all show clear empty states.
7. Checklist parser unit tests pass.

## 13. Implementation order (for planning)

1. Scaffold macOS app + floating `NSPanel` + menu bar toggle  
2. `GitHubCLIService` + models + fixture tests  
3. `ChecklistParser` + tests  
4. `PRStatusStore` + wire UI rows  
5. Repo picker, persistence, timer  
6. Polish: collapse, colors, error banner, README  

## 14. Open decisions (resolved)

| Decision | Choice |
|----------|--------|
| Primary glance content | PR checklist status |
| Data source | GitHub CLI (`gh`) |
| Agent highlights | Skip v1 |
| Which PRs | Open, authored by me, current (selected) repo |
| UI shell | SwiftUI floating panel + menu bar |
