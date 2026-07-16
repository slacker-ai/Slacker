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
- **Local learning loop**: Resolve, Dismiss, and Review actions immediately activate
  validated learned phrases plus global and per-channel AI guidance. Prompts remain
  directly editable in Settings.
- **Daily overview**: per-channel summaries provide context without replacing the
  action list.
- **Real-time Slack delivery**: Socket Mode receives watched-channel activity without
  scheduled polling; launch, wake, and reconnect use bounded, changed-root HTTP gap recovery.
- **Bring your own Slack app**: create an internal Slack app from the included
  manifest and provide its read-only `xoxp-` user token plus an `xapp-` Socket Mode token.
- **Bring your own LLM provider**: configure the provider or local/CLI model you
  want to use.
- **Local-first storage**: Slack data is processed locally and stored in SQLite.

## Privacy Model

Slacker is designed so there is no Slacker-operated backend.

- No backend, telemetry, analytics, or remote logging.
- Slack data is processed locally in the macOS app.
- Slack user/app tokens and LLM API keys stay in Keychain.
- Local SQLite stores messages, channels, items, summaries, and labels.
- Network egress is limited to `slack.com`, your configured LLM endpoint, and GitHub's
  release endpoints for cryptographically signed application updates.
- Slack scopes are read-only. No DM scopes, bot scopes, or write scopes.

You create your own Slack app from a manifest in this repo. No shared OAuth app
or third-party server receives a token for your workspace.

## Intall Binary
Install the newest release [here](https://github.com/slacker-ai/Slacker/releases/latest/download/Slacker.dmg)

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
| Public + private channels | Public and private channels you already belong to | `channels:history`, `channels:read`, `groups:history`, `groups:read`, `reactions:read`, `users:read` |
| Public channels only | Public channels you already belong to | `channels:history`, `channels:read`, `reactions:read`, `users:read` |

Manifest files:

- [Public + private](Slacker/Slack/Manifest/manifest-public-private.json)
- [Public only](Slacker/Slack/Manifest/manifest-public-only.json)

Both variants enable Socket Mode and user-event subscriptions for messages and reactions.
They remain read-only and neither variant can read DMs. Each workspace also needs an
app-level `xapp-` token with `connections:write`; that scope opens the socket and does not
grant access to Slack content.

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
- `Slacker/Slack`: Slack API client, Socket Mode, reconciliation, ingestion, manifests
- `Slacker/Detection`: rules, LLM classification, resolution, summaries, learning
- `Slacker/Features`: onboarding, attention list, overview, review queue, settings
- `SlackerTests`: XCTest coverage

Detection is precision-first: rules handle high-confidence cases, LLMs handle
ambiguous cases and approved-guidance checks, and uncertain items go to review.

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
- Network access must remain limited to Slack, the user-configured LLM endpoint, and
  GitHub release endpoints used for signed application updates.
- Slack scopes must remain read-only and exclude DMs.

## Releases

Public releases are created by pushing a version tag:

```sh
git tag v0.1.0
git push origin v0.1.0
```

The release workflow derives the application version from the tag, builds and tests the
app, signs it with Developer ID, packages `Slacker.app` into a drag-to-Applications DMG,
notarizes and staples the DMG, signs it for Sparkle, and opens a draft GitHub Release with
the DMG, SHA-256 checksum, and `appcast.xml` attached. Publishing the draft makes the
release visible to installed copies through **Check for Updates…** and scheduled Sparkle
checks.

One-time Sparkle signing setup:

```sh
scripts/setup-sparkle-signing.sh ~/secure/slacker-sparkle-private-key
# Run the two `gh variable set` / `gh secret set` commands printed by the script.
```

The private key must be retained in a secure offline backup and must never be committed.
Existing installations from before Sparkle was added require one final manual DMG update;
later releases can update in place.

Local development uses ad-hoc signing. Public release DMGs must be Developer ID
signed and notarized before normal user download.

## License

Slacker is licensed under the [GNU Affero General Public License v3.0](LICENSE).
