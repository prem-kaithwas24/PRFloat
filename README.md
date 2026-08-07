# PR Float

Small **always-on-top** macOS panel that shows **your open PRs** in a selected repo: markdown **checklist** progress + **CI checks**, via the GitHub CLI (`gh`).

## Requirements

- macOS 14+
- Swift 5.9+ (Xcode or Command Line Tools)
- Authenticated [GitHub CLI](https://cli.github.com/): `gh auth login`

## Build & run

```bash
cd PRFloat

# Unit tests
swift test

# Build .app and open it
./scripts/package-app.sh
open dist/PRFloat.app
```

Debug run (no bundle):

```bash
swift run PRFloat
```

## Usage

1. Launch **PR Float** — a checklist icon appears in the menu bar and a floating panel opens.
2. **Choose Repo…** (panel or menu) and pick a local git checkout that `gh` understands.
3. Your **open PRs authored by you** appear with:
   - Checklist `done/total` from the PR body (`- [ ]` / `- [x]`)
   - CI summary from `statusCheckRollup`
   - **Open ↗** to open the PR in the browser
4. Refreshes every **60s**, or click the refresh control / menu **Refresh**.
5. Collapse the panel to a thin status strip; menu bar → **Show / Hide Panel**.

## Menu bar

| Action | Shortcut |
|--------|----------|
| Show / Hide Panel | ⌘P |
| Refresh | ⌘R |
| Choose Repo… | ⌘O |
| Quit | ⌘Q |

Settings (repo path, window position) are stored in `UserDefaults`.

## Project layout

- `Sources/PRFloatCore` — models, checklist parser, `gh` service (testable)
- `Sources/PRFloat` — menu bar app, floating `NSPanel`, SwiftUI UI
- `Tests/PRFloatTests` — parser, health colors, JSON fixtures

## Design

See `../docs/superpowers/specs/2026-08-06-pr-float-design.md` (or copy under this repo later).

## Tests

```bash
swift test
```

Tests use [swift-testing](https://github.com/swiftlang/swift-testing), which ships with the
Swift toolchain, so they run under Command Line Tools alone — the full Xcode app is not
required.

## Not in v1

- Multi-repo watch lists  
- Agent highlights (Claude / Grok)  
- Direct GitHub API tokens (uses `gh` only)
