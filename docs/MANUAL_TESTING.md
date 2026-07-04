# Manual Testing Guide

How to exercise Slacker end-to-end against a real Slack workspace before deployment.
Pair this with the `[Slacker]` console logs; they narrate every poll, ingest, detect,
resolve, summary, and learning step.

Use a test Slack workspace/channel when possible. Do not paste real customer message
content into issues, docs, screenshots, or notes.

## 0. Prerequisites

- macOS 14+, Xcode 26+, `xcodegen` (`brew install xcodegen`).
- A Slack workspace where you can create an app (or an admin who can).
- Optional but recommended: an LLM API key (Anthropic/OpenAI/Gemini) or a local
  Ollama / Codex CLI / Claude Code install. Without an LLM, rules-only detection,
  heuristic resolution, and **no** summaries.

## 1. Build, test, and run

Run the automated checks first so manual QA focuses on product behavior:

```sh
cd ~/Documents/slacker
xcodegen generate
xcodebuild test -project Slacker.xcodeproj -scheme Slacker -destination 'platform=macOS'
```

Then run the app:

```sh
cd ~/Documents/slacker
xcodegen generate
open Slacker.xcodeproj      # then ⌘R
```

To see logs in a terminal instead of Xcode:

```sh
"$(find ~/Library/Developer/Xcode/DerivedData/Slacker-*/Build/Products/Debug -name Slacker.app | head -1)/Contents/MacOS/Slacker"
```

Debug builds print `[Slacker] ...` lines for every cycle (also visible in Console.app
under subsystem `com.slacker.Slacker`).

Pass criteria:

- App builds cleanly.
- Tests pass.
- App launches without starting live polling under the hosted test app.
- Logs redact Slack tokens and LLM API keys.

## 1.1 Release packaging smoke test

CI creates public builds from `v*` tags only. Before publishing a release draft:

1. Confirm the GitHub release workflow passed tests, signing, notarization, stapling,
   and checksum creation.
2. Download the draft release DMG from GitHub Releases onto a clean macOS machine or
   user account.
3. Open the DMG, drag `Slacker.app` to Applications, and launch it from Applications.
4. If macOS shows an unidentified-developer or damaged-app warning, do not publish the
   release. The Developer ID signing or notarization step is broken.
5. Run the onboarding checks below against a test Slack workspace.

Pass criteria:

- The DMG opens as a normal mounted disk image with an Applications shortcut.
- Drag-and-drop installation works.
- The app launches without Gatekeeper warnings.
- First-run onboarding and Keychain storage behave the same as a local build.

## 2. First-run onboarding

1. **Welcome → Get started.**
2. **Choose a manifest variant:**
   - *Public + private* (default) — reads your public **and** private channels.
   - *Public only* — provably can't touch private channels (3 scopes).
3. **Copy manifest → Open Slack.** On api.slack.com: **Create New App → From a manifest →**
   pick the workspace Slacker should read → paste the copied JSON → **Create**.
4. In the Slack app dashboard, click **Install to Workspace** → review the scopes
   (the public-only variant shows **no** `groups:*`) → **Allow**.
5. After install, stay in that Slack app dashboard and open **OAuth & Permissions**.
   Under **OAuth Tokens**, copy the **User OAuth Token** (starts with `xoxp-`).
6. Back in Slacker: paste the token → **Connect**. You should see
   *"Connected to {workspace} as {you}"*.
7. **Pick channels** to watch → **Finish**.

Pass criteria:

- Manifest copies to the clipboard and opens Slack's create-app page.
- Public-only manifest contains no `groups:*` scopes.
- User token must start with `xoxp-`; bot tokens are rejected.
- Slack token is stored in Keychain, not UserDefaults, plist, SQLite, or logs.
- Re-launching skips onboarding and opens the main window directly.

## 3. Configure the LLM (Settings tab)

- **Provider:** Anthropic (default), OpenAI, Gemini, Generic API, Ollama, Codex CLI,
  or Claude Code.
- **Model:** e.g. `claude-opus-4-8`, `gpt-4o`, `gemini-2.0-flash`, `llama3` (Ollama).
- **API key:** stored only in the Keychain (HTTP providers). Ollama/CLI need no key.
- **Endpoint URL:** for Generic API / Ollama (defaults to `localhost:11434` for Ollama).
- **CLI path:** optional override for Codex/Claude Code (otherwise auto-detected on PATH).
- **Poll interval** (default 180s), **summary interval** (default 6h), and
  **staleness threshold** (default 48h).
- Click **Save**. (Provider/model changes take effect on next launch.)

Pass criteria:

- HTTP provider keys are stored only in Keychain.
- Saving settings does not print secrets.
- Ollama/CLI providers work without an API key.
- If no LLM is configured, rules-only detection still works and summaries/evolution are
  skipped cleanly.

## 4. Core detection scenarios

Use the **Refresh** button (Needs attention / Overview toolbars) to run a cycle
immediately instead of waiting for the poll interval.

| # | Send in a watched channel | Expected | Log line |
|---|---|---|---|
| 1 | Any message | Ingested to local DB | `Ingestion[#x]: N new top-level…` |
| 2 | `@you can you confirm the deploy time?` | **Needs attention → Missed follow-ups** | `Detection[#x]: … 1 surfaced …` |
| 3 | `the build is failing: <link>` / `trying to deploy but it errors` | **Needs attention → Stale** (blocker) | `… 1 surfaced …` |
| 4 | `@you FYI this changed` | **Needs attention → Mentions** | `… 1 surfaced …` |
| 5 | `thanks everyone` | Ingested, **not** surfaced (by design) | `… 1 not actionable` |
| 6 | `is staging up?` (bare question) | **Review queue** (ambiguous) | `… 1 review …` |

Pass criteria:

- Needs attention only shows `surfaced` items.
- Review tab only shows ambiguous `review` items.
- Uncertain items do not auto-surface.
- The Needs attention row actions are exactly **Open in Slack**, **Resolve**, and
  **Dismiss**. There is no Snooze action.
- **Open in Slack** lands on the exact channel/thread.
- Badge count equals the number of surfaced items.
- If a dismissed thread later gets a new `@you` reply, it returns under **Mentions**.

## 5. Triage, calibration, and self-evolution

Exercise each user action on separate items:

| Action | Expected state | Expected learning behavior |
|---|---|---|
| Needs attention → **Resolve** | Item leaves list as `resolved` | Writes `.matters` label and fires per-triage evolution |
| Needs attention → **Dismiss** | Item leaves list as `dismissed` | Writes `.ignore` label and fires per-triage evolution |
| Review → **This matters** | Item moves to Needs attention | Writes `.matters` label and fires per-triage evolution |
| Review → **Ignore** | Item leaves review as `dismissed` | Writes `.ignore` label and fires per-triage evolution |

With an LLM configured:

- After a triage action, watch logs for `LLM pattern evolution used[...]` or a clean skip/fail
  message.
- If the LLM proposes updates, Settings should show a **Self-evolution** pending count.
- Proposed learned phrases/guidance must not affect detection until approved in Settings.
- Approve one safe proposal, Refresh, and verify a matching future message uses the learned
  behavior.
- For proposed AI guidance, click **Append to document** and verify it appears in the
  **Active AI guidance document** text box. Edit the document, wait for the autosave status
  to return to **Saved**, and verify the edited text persists after leaving/reopening Settings.
- Reject a proposal and verify the pending list updates.
- Use **Revert all learned patterns** and verify phrase detection and active AI guidance
  return to base behavior.
- If notifications are enabled, a new pending proposal should post one coalesced local
  notification, not spam multiple notifications.

Without an LLM configured:

- Triage still writes labels.
- Evolution logs a no-LLM skip.
- No proposal is created.

## 6. Resolution and reopen behavior

- **Heuristic resolution:** on a surfaced question, add a resolved reaction/emoji
  (`✅`, `☑`, `👍`) or reply with explicit "fixed/done/shipped/resolved" wording.
  Refresh. The item should leave Needs attention as resolved.
- **Open/in-progress guard:** add an open/in-progress reaction/emoji (`👀`, `⏳`, `⚠️`) to
  an unresolved thread. Refresh. The item should stay open.
- **LLM resolution:** on a surfaced item, have a 3+ message back-and-forth that ends
  resolved without explicit resolution keywords, for example "cleared the cache, green
  now". Refresh. With an LLM configured, the item should auto-close if confidence is high.
- **Reopen:** after resolving an item, add a newer actionable reply such as "actually this
  is failing again, can someone look?" Refresh. The item should reopen and clear the old
  resolution reason.
- **Do not reopen dismissed:** dismiss an item, then add new replies in the thread.
  Refresh. It should stay dismissed.
- **Legacy snoozed rows:** if testing with an older local DB that already contains snoozed
  rows, they should remain terminal. The current UI should not create new snoozed rows.

## 7. Thread summaries and Overview

- Reply in a surfaced item's thread. Refresh. The row should show the reply count.
- With an LLM configured, the row should show a concise thread summary after the summary
  pass runs.
- Open the Overview tab. Each watched channel should show today's summary, open-item count,
  and last activity.
- In Settings, set **Summary interval** to a larger value. Add a new channel message and
  refresh; detection should update immediately, but the Overview summary should not
  regenerate until the interval has elapsed.
- Without an LLM, Overview should degrade cleanly and log
  `Summary skipped: no LLM configured`.
- Changing watched channels in Settings should update Overview and Needs attention after
  refresh.

## 8. Backfill, polling, and app lifecycle

- Quit Slacker, post messages in watched channels, relaunch. The app should backfill and
  process messages posted while it was offline.
- Put the Mac to sleep or simulate a wake cycle, then verify a poll runs on wake.
- Let the app sit for at least one poll interval and verify automatic polling continues.
- Use both Refresh buttons and verify they trigger one clean cycle without duplicate rows.
- Restart after settings changes and verify provider/model/channel choices persist.

## 9. Multi-workspace and channel settings

- Add another workspace from Settings if available. Verify each workspace has its own Slack
  token and channel list.
- Refresh channel list after joining a new Slack channel. The new channel should appear in
  the Add channel flow.
- Stop watching a channel. Refresh. New messages from that channel should not produce items.
- Change channel sensitivity and verify high sensitivity surfaces more, low sensitivity
  surfaces less, without violating "uncertain goes to review."

## 10. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `Ingestion: 0 watched channel(s)` | No channels selected → pick some in Settings. |
| `Ingestion[#x]: 0 new…` after sending | Wrong channel, or you're not a member, or it was already polled. |
| Message ingested but no item | It wasn't actionable (expected). Check for `… not actionable`. |
| Nothing in Overview | No LLM configured (`Summary skipped: no LLM configured`) → set provider + key. |
| Token rejected on Connect | Re-copy the full `xoxp-` **User** token (not a bot token). |
| Private channels missing | Use the **public + private** manifest variant; you must be a member. |
| `Poll cycle failed: rateLimited` | Transient; backs off automatically. Raise the poll interval if persistent. |
| CLI provider error | Set the explicit **CLI path** in Settings; ensure the tool is logged in. |
| No evolution proposal after triage | No LLM configured, LLM returned no useful proposal, or proposed phrases were rejected by safety filters. |
| Proposed pattern/guidance does nothing | Expected until approved/appended in Settings. Detection reads approved phrases and the active AI guidance document only. |
| Dismissed item does not reopen | Expected. Dismiss is terminal and also teaches `.ignore`. |

## 11. Privacy and security sanity check

- Slacker only contacts `slack.com` and your configured LLM endpoint (enforced by the
  no-egress test). Confirm in Console.app / a proxy if you like.
- The Slack token + LLM key live only in the Keychain (search Keychain Access for
  `com.slacker.Slacker`); they are never written to the DB, plist, or logs (redacted).
- Slack scopes are read-only user-token scopes. No DM scopes, bot scopes, or write scopes.
- There are no analytics, telemetry, crash uploaders, or remote logging calls.
- Screenshots for release/PRs must not include real Slack message content or secrets.

## 12. Pre-deploy sign-off

Before deployment, record:

- macOS version and Xcode version.
- Slack manifest variant tested.
- LLM provider/model tested, or "rules-only".
- Automated test command and result.
- Manual scenarios completed.
- Any known gaps, especially around Slack scopes, Keychain, egress, logging,
  LLM/subprocess behavior, or learned-pattern approval.
