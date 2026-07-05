<p align="center">
  <img src="logo.png" alt="Slacker logo" width="160">
</p>

<h1 align="center">Slacker</h1>

<p align="center">
  Local-first Slack catch-up for macOS.
</p>

<p align="center">
  <a href="LICENSE"><img alt="License: AGPL v3" src="https://img.shields.io/badge/license-AGPL--3.0-blue"></a>
  <img alt="Platform: macOS" src="https://img.shields.io/badge/platform-macOS-lightgrey">
  <img alt="Version: 1.0.0" src="https://img.shields.io/badge/release-v1.0.0-blue">
</p>

Slacker is a self-evolving, local-first macOS app that surfaces the Slack
threads that actually need attention.

Slack is good at real-time conversation and bad at showing what still needs a
decision, response, or follow-up. Slacker keeps the focus on unresolved threads,
open issues, and stale conversations.

## Status

Slacker currently supports macOS 14 and later. An enterprise version is in
development; for enterprise inquiries, contact Daanish Hindustani.

## Features

- **Needs attention**: missed follow-ups, stale items, and mentions in one focused
  list.
- **Review queue**: ambiguous messages go to triage instead of becoming noisy
  alerts.
- **Local learning loop**: triage labels can propose learned rules and guidance,
  but nothing changes detection until you approve it.
- **Daily overview**: per-channel summaries provide context without replacing the
  action list.
- **Bring your own Slack app**: create an internal Slack app from the included
  manifest and paste your own read-only `xoxp-` user token.
- **Bring your own LLM provider**: configure the provider or local/CLI model you
  want to use.
- **Local-first storage**: Slack data is processed locally and stored in SQLite.

## Privacy Model

Slacker is designed so there is no Slacker-operated backend.

- No backend, telemetry, analytics, or remote logging.
- Slack data is processed locally in the macOS app.
- Slack tokens and LLM API keys stay in Keychain.
- Local SQLite stores messages, channels, items, summaries, and labels.
- Network egress is limited to `slack.com` and your configured LLM endpoint.
- Slack scopes are read-only. No DM scopes, bot scopes, or write scopes.

You create your own Slack app from a manifest in this repo. No shared OAuth app
or third-party server receives a token for your workspace.

## Intall Binary
Install the newest release [here](https://github.com/slacker-ai/Slacker/releases/download/untagged-ebcb89697785924c7dc5/Slacker.dmg)

## Quick Start

See [Quick Start](QUICK_START.md) for the full local setup and Slack
connection flow.

```sh
brew install xcodegen
xcodegen generate
xcodebuild build -project Slacker.xcodeproj -scheme Slacker -destination 'platform=macOS'
open Slacker.xcodeproj
```

Run the `Slacker` scheme from Xcode.

## Slack Permissions

During onboarding, choose one manifest variant:

| Variant | Reads | User-token scopes |
| --- | --- | --- |
| Public + private channels | Public and private channels you already belong to | `channels:history`, `channels:read`, `groups:history`, `groups:read`, `users:read` |
| Public channels only | Public channels you already belong to | `channels:history`, `channels:read`, `users:read` |

Manifest files:

- [Public + private](Slacker/Slack/Manifest/manifest-public-private.json)
- [Public only](Slacker/Slack/Manifest/manifest-public-only.json)

Both variants are read-only. Neither variant can read DMs.

## Development

Common commands:

```sh
xcodegen generate
xcodebuild build -project Slacker.xcodeproj -scheme Slacker -destination 'platform=macOS'
xcodebuild test -project Slacker.xcodeproj -scheme Slacker -destination 'platform=macOS'
xcodebuild -project Slacker.xcodeproj -scheme Slacker -resolvePackageDependencies
```

Run a focused test:

```sh
xcodebuild test -project Slacker.xcodeproj -scheme Slacker -destination 'platform=macOS' \
  -only-testing:SlackerTests/KeychainStoreTests
```

Reset local onboarding state during development:

```sh
scripts/reset-onboarding.sh --dry-run
scripts/reset-onboarding.sh
```

GitHub Actions runs the generated-project build and XCTest suite on pull
requests and pushes to `main`.

## Project Structure

Slacker is a SwiftUI app backed by local SQLite through GRDB.

- `Slacker/Core`: database, settings, Keychain, logging, redaction, models
- `Slacker/Slack`: Slack API client, ingestion, polling, manifests
- `Slacker/Detection`: rules, LLM classification, resolution, summaries, learning
- `Slacker/Features`: onboarding, attention list, overview, review queue, settings
- `SlackerTests`: XCTest coverage

Detection is precision-first: rules handle high-confidence cases, LLMs handle
ambiguous cases, and uncertain items go to review.

## Documentation

- [Quick Start](QUICK_START.md)
- [Contributing](CONTRIBUTING.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Implementation plan](docs/IMPLEMENTATION.md)
- [Manual testing](docs/MANUAL_TESTING.md)

## Contributing

Contributions are welcome. Start with [Contributing](CONTRIBUTING.md), and keep
changes aligned with the privacy model.

Before opening a PR:

```sh
xcodegen generate
xcodebuild test -project Slacker.xcodeproj -scheme Slacker -destination 'platform=macOS'
```

Do not add telemetry, hosted services, write scopes, DM scopes, broad
person-level views, or dependencies that move Slack data off the user's machine
outside their configured LLM provider.

## Security

Please do not file public issues for vulnerabilities involving token storage,
secret redaction, database leakage, network egress, or Slack scope expansion.
Open a private report with the maintainer instead.

Security-sensitive invariants:

- Secrets must stay in Keychain.
- Tokens and API keys must be redacted in logs and errors.
- SQLite must not store secrets.
- Network access must remain limited to Slack and the user-configured LLM endpoint.
- Slack scopes must remain read-only and exclude DMs.

## Releases

Public releases are created by pushing a version tag:

```sh
git tag v0.1.0
git push origin v0.1.0
```

The release workflow builds and tests the app, archives a Release build, signs
it with Developer ID, packages `Slacker.app` into a drag-to-Applications DMG,
notarizes and staples the DMG, then opens a draft GitHub Release with the DMG
and SHA-256 checksum attached.

Local development uses ad-hoc signing. Public release DMGs must be Developer ID
signed and notarized before normal user download.

## License

Slacker is licensed under the [GNU Affero General Public License v3.0](LICENSE).
