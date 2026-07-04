# Quick Start

This guide gets Slacker running locally and connected to Slack for development or
personal testing.

## Requirements

- macOS
- Xcode
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- A Slack workspace where you can create an internal/custom app
- An AI provider key or local/CLI provider for LLM features

Install XcodeGen:

```sh
brew install xcodegen
```

## Build the App

Generate the Xcode project and run a local build:

```sh
xcodegen generate
xcodebuild build -project Slacker.xcodeproj -scheme Slacker -destination 'platform=macOS'
open Slacker.xcodeproj
```

Run the `Slacker` scheme from Xcode.

## Connect Slack

Slacker uses your own Slack app and a read-only user token. There is no shared
OAuth app or Slacker-operated service.

1. Launch Slacker.
2. Choose a Slack access variant.
3. Copy the manifest from Slacker.
4. Open Slack's app dashboard and create a new app **from a manifest**.
5. Install the Slack app to your workspace.
6. Open **OAuth & Permissions** and copy **OAuth Tokens -> User OAuth Token**.
7. Paste the `xoxp-...` token into Slacker.
8. Choose the channels Slacker should process.
9. Connect your AI provider.

The Slack token is stored in Keychain. Slacker only processes selected channels.

## Slack Access Variants

| Variant | Reads | User-token scopes |
| --- | --- | --- |
| Public + private channels | Public and private channels you already belong to | `channels:history`, `channels:read`, `groups:history`, `groups:read`, `users:read` |
| Public channels only | Public channels you already belong to | `channels:history`, `channels:read`, `users:read` |

Manifest files:

- [Public + private](Slacker/Slack/Manifest/manifest-public-private.json)
- [Public only](Slacker/Slack/Manifest/manifest-public-only.json)

Both variants are read-only. Neither variant can read DMs.

## Run Tests

Run the full test suite:

```sh
xcodebuild test -project Slacker.xcodeproj -scheme Slacker -destination 'platform=macOS'
```

Run a focused test:

```sh
xcodebuild test -project Slacker.xcodeproj -scheme Slacker -destination 'platform=macOS' \
  -only-testing:SlackerTests/KeychainStoreTests
```

## Reset Local Onboarding State

During development, you can reset local onboarding state:

```sh
scripts/reset-onboarding.sh --dry-run
scripts/reset-onboarding.sh
```

Use the dry run first. The reset script is for local development state, not for
changing Slack app permissions.

## Privacy Boundaries

Keep these constraints intact while testing or developing:

- No backend, telemetry, analytics, or remote logging.
- Slack tokens and LLM API keys stay in Keychain.
- Network egress is limited to `slack.com` and the configured LLM endpoint.
- Slack scopes stay read-only and exclude DMs.
- Needs attention stays item-centric; do not add person-level dashboards.
