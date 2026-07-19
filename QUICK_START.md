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

Slacker uses your own Slack app, a read-only user token, and an app-level Socket Mode
token. There is no shared OAuth app or Slacker-operated service.

1. Launch Slacker.
2. Choose a Slack access variant.
3. Copy the manifest from Slacker.
4. Open Slack's app dashboard and create a new app **from a manifest**.
5. Install the Slack app to your workspace.
6. Open **OAuth & Permissions** and copy **OAuth Tokens -> User OAuth Token**.
7. In **Basic Information -> App-Level Tokens**, generate a token with
   `connections:write` and copy the `xapp-...` value.
8. Paste both the `xoxp-...` and `xapp-...` tokens into Slacker.
9. Choose the channels Slacker should process.
10. Connect your AI provider.

Both Slack tokens are stored per workspace in Keychain. Slacker only processes selected
channels. New activity arrives over Socket Mode; HTTP catch-up runs on launch, wake,
reconnect, and foreground activation. Closing the window leaves the menu-bar app connected;
after a real Quit,
the next launch resumes from durable per-channel cursors.

## Slack Access Variants

| Variant | Reads | User-token scopes |
| --- | --- | --- |
| Public + private channels | Public and private channels you already belong to | `channels:history`, `channels:read`, `groups:history`, `groups:read`, `reactions:read`, `users:read` |
| Public channels only | Public channels you already belong to | `channels:history`, `channels:read`, `reactions:read`, `users:read` |

Manifest files:

- [Public + private](Slacker/Slack/Manifest/manifest-public-private.json)
- [Public only](Slacker/Slack/Manifest/manifest-public-only.json)

Both variants are read-only, enable Socket Mode, and exclude DMs. The separate app-level
token needs `connections:write` only to open the WebSocket.

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
- Slack user/app tokens and LLM API keys stay in Keychain.
- Network egress is limited to `slack.com`, the configured LLM endpoint, and GitHub's
  release endpoints for signed Slacker updates.
- Slack scopes stay read-only and exclude DMs.
- Needs attention stays item-centric; do not add person-level dashboards.
