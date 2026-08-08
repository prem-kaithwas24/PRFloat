# PR Float

Small **always-on-top** macOS panel showing two things at a glance:

- **Your open pull requests** across every repo you can see — checklist progress and CI health
- **Your running Claude Code agents** — who is working, who finished, and who is blocked on you

Agents working on a branch with an open PR are badged onto that PR's row.

## Requirements

- macOS 14+
- Swift 5.9+ (Xcode or Command Line Tools)
- A GitHub OAuth app for sign-in (see below) — **no `gh` CLI required**

## Setup

PR Float signs in with GitHub's OAuth **device flow**, which needs a client ID. Device
flow has no client secret, so the ID is not sensitive.

1. Go to [github.com/settings/developers](https://github.com/settings/developers) → **New OAuth App**
2. Any name and homepage URL will do
3. Tick **Enable Device Flow**, then **Register application**
4. Copy the **Client ID**

Give it to the app either way:

```bash
# Baked into the bundle at build time
PRFLOAT_GITHUB_CLIENT_ID=Iv1.your_client_id ./scripts/package-app.sh
```

…or paste it into the app's sign-in screen (also under Settings → Account). The token is
stored in the **macOS Keychain**; the app never sees your password.

## Build & run

```bash
swift test                  # unit tests
./scripts/package-app.sh    # build + bundle + sign
open dist/PRFloat.app
```

Debug run without a bundle:

```bash
swift run PRFloat
```

> Ad-hoc signed builds run fine locally. Copied from another Mac, Gatekeeper will
> quarantine them — clear it with `xattr -d com.apple.quarantine /Applications/PRFloat.app`,
> or notarize properly (below).

## Usage

1. Launch **PR Float** — a checklist icon appears in the menu bar and the panel opens.
2. **Sign in with GitHub**, enter the code shown, and authorise.
3. The panel then shows:

**Agents** — every live Claude Code session on this Mac:

| State | Meaning |
|-------|---------|
| **Working** | Busy on a task (pulsing blue) |
| **Just finished** | Went idle in the last 5 minutes (highlighted green) |
| **Done** | Idle — control is back with you |
| **Needs you** | Blocked, e.g. a permission dialog (amber) |

Each row shows the repo and branch, and the last thing you asked it to do.

**Pull Requests** — your open PRs, grouped by repository, with checklist progress from the
PR body (`- [ ]` / `- [x]`), a CI summary, a Draft pill, and an agent badge where one is
working on that branch. Double-click a row, or use the arrow button, to open it on GitHub.

Collapse the panel to a one-line strip; what needs you outranks what is merely running.

## Menu bar

| Action | Shortcut |
|--------|----------|
| Show / Hide Panel | ⌘P |
| Refresh | ⌘R |
| Settings… | ⌘, |
| Quit | ⌘Q |

## Settings

- **Account** — signed-in user, sign out, OAuth client ID
- **General** — poll interval (30s / 1m / 5m / manual), which sections show, launch at login
- **Panel** — always-on-top, reset position

## How it works

PRs come from a **single GraphQL search** (`is:pr is:open author:@me`) rather than
per-repo calls.

Agents are read from Claude Code's own session registry at `~/.claude/sessions/*.json`,
which already carries a `busy` / `idle` / `waiting` status. The directory is watched with
a filesystem event source, so status changes appear near-instantly. Sessions whose process
has exited are pruned via `kill(pid, 0)`.

The task line comes from the session transcript. A fixed tail read is not enough — in real
transcripts the last user prompt sits 100–180 lines from the end, buried under tool
results — so the reader scans backwards in growing windows and caches on file mtime.

## Project layout

- `Sources/PRFloatCore` — auth, GitHub API, agent tracking, models (no AppKit, fully testable)
- `Sources/PRFloat` — menu bar app, floating `NSPanel`, SwiftUI views, stores
- `Tests/PRFloatTests` — 102 tests over auth, API decoding, agents, git resolution
- `scripts/` — packaging, icon generation, notarization

## Notarization

Requires an Apple Developer Program membership:

```bash
export DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
export NOTARY_PROFILE="prfloat"     # xcrun notarytool store-credentials
./scripts/package-app.sh release
./scripts/notarize.sh
```

## Design

- `docs/2026-08-06-pr-float-design.md` — v1
- `docs/2026-08-08-pr-float-v2-design.md` — v2 (native auth, all-repo PRs, agent tracking)

## Not included

- Cloud agents (Claude on the web, Copilot agent) — local sessions only
- Controlling agents from the panel; it is a read-only view
- Review-requested PRs (authored only)
- Multiple GitHub accounts, GitHub Enterprise Server
