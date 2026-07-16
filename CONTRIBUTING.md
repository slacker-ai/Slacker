# Contributing

Contributions are welcome while Slacker is early, but changes need to preserve
the product's privacy and trust model.

## Before You Start

Read the relevant docs before substantial changes:

- [Architecture](docs/ARCHITECTURE.md)
- [Implementation requirements](docs/IMPLEMENTATION.md)
- [Manual testing](docs/MANUAL_TESTING.md)

For local setup, see [Quick Start](QUICK_START.md).

## Development Workflow

Generate the Xcode project after changing `project.yml`, targets, packages, or
source layout:

```sh
xcodegen generate
```

Run the full test suite before opening a PR:

```sh
xcodebuild test -project Slacker.xcodeproj -scheme Slacker -destination 'platform=macOS'
```

Run focused tests while developing:

```sh
xcodebuild test -project Slacker.xcodeproj -scheme Slacker -destination 'platform=macOS' \
  -only-testing:SlackerTests/KeychainStoreTests
```

## Code Guidelines

- Use Swift 5, SwiftUI, Swift Concurrency, `URLSession`, and `Codable`.
- Keep view models `@MainActor`.
- Keep Socket Mode, Slack reconciliation/ingestion, detection, and LLM work off the main actor.
- Use GRDB for SQLite access; do not hand-roll SQLite.
- Prefer small injectable seams for Slack, LLM, database, subprocess, and clock
  behavior.
- Match the existing file structure under `Slacker/Core`, `Slacker/Slack`,
  `Slacker/Detection`, and `Slacker/Features`.
- Avoid broad abstractions unless they remove real duplication.

## Testing Guidelines

Add focused XCTest coverage for behavior you change, especially around:

- Slack ingestion idempotency
- GRDB migrations
- Detection and routing thresholds
- Resolution behavior
- Calibration and learned-pattern approval gates
- LLM JSON parsing failures
- Keychain, redaction, and network egress regressions

Tests must not hit real Slack, real LLM providers, live Keychain secrets, or
external network. Use stubs such as `StubTransport`.

## Product and Security Invariants

Do not add:

- Backends, telemetry, analytics, or remote logging
- DM scopes, bot scopes, write scopes, or broad Slack permissions
- Secret storage in UserDefaults, plist files, SQLite, or logs
- Network egress beyond `slack.com`, the user-configured LLM endpoint, and the fixed
  GitHub release feed used for signed application updates
- Per-person or employee-aggregated views

User-facing copy should avoid surveillance language such as "monitor" or "track
employees." Prefer "catch-up," "open loops," and "needs attention."

## Pull Requests

PRs should include:

- What behavior changed
- Tests run
- Docs updated, if behavior, setup, scopes, data model, or trust claims changed
- Screenshots or recordings for UI changes
- Explicit notes for changes touching Slack scopes, Keychain, egress, logging,
  signing, or LLM/subprocess behavior

Use short Conventional Commit-style subjects for commits, such as:

```text
feat: add channel summary refresh setting
fix: redact llm api keys in validation errors
docs: add local setup guide
```

## Security Reports

Please do not file public issues for vulnerabilities involving token storage,
secret redaction, database leakage, network egress, or Slack scope expansion.
Open a private report with the maintainer instead.
