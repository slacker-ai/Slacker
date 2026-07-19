# Manual Testing Guide

How to exercise Slacker end-to-end against a real Slack workspace before deployment.
Pair this with the `[Slacker]` console logs; they narrate connection, reconciliation, ingest, detect,
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
- App launches without starting live Socket Mode under the hosted test app.
- Logs redact Slack user/app tokens and LLM API keys.

## 1.1 Release packaging smoke test

CI creates public builds from `v*` tags only. Before publishing a release draft:

1. Confirm the GitHub release workflow passed tests, Developer ID signing, notarization,
   stapling, Sparkle EdDSA signing, appcast generation, and checksum creation.
2. Download the draft release DMG from GitHub Releases onto a clean macOS machine or
   user account.
3. Open the DMG, drag `Slacker.app` to Applications, and launch it from Applications.
4. If macOS shows an unidentified-developer or damaged-app warning, do not publish the
   release. The Developer ID signing or notarization step is broken.
5. Run the onboarding checks below against a test Slack workspace.
6. Publish the draft, launch the previous signed release, and choose **Check for Updates…**.
   Verify Sparkle offers the new version, validates it, replaces the app, and relaunches
   without losing the local database or Keychain credentials.

Pass criteria:

- The DMG opens as a normal mounted disk image with an Applications shortcut.
- Drag-and-drop installation works.
- The app launches without Gatekeeper warnings.
- First-run onboarding and Keychain storage behave the same as a local build.
- `appcast.xml` and `Slacker.dmg` are attached to the published release, and the stable
  `releases/latest/download/appcast.xml` URL resolves successfully.

## 2. First-run onboarding

1. **Welcome → Get started.**
2. **Choose a manifest variant:**
   - *Public + private* (default) — reads your public **and** private channels.
   - *Public only* — provably can't touch private channels (4 read-only scopes).
3. **Copy manifest → Open Slack.** On api.slack.com: **Create New App → From a manifest →**
   pick the workspace Slacker should read → paste the copied JSON → **Create**.
4. In the Slack app dashboard, click **Install to Workspace** → review the scopes
   (the public-only variant shows **no** `groups:*`) → **Allow**.
5. After install, stay in that Slack app dashboard and open **OAuth & Permissions**.
   Under **OAuth Tokens**, copy the **User OAuth Token** (starts with `xoxp-`).
6. Open **Basic Information → App-Level Tokens → Generate Token and Scopes**. Name it
   `Slacker Socket Mode`, add `connections:write`, generate it, and copy the `xapp-` token.
7. Back in Slacker: paste both tokens → **Connect**. You should see
   *"Connected to {workspace} as {you}"*.
8. **Pick channels** to watch → **Finish**.

Pass criteria:

- The wizard opens at 760×620 with a pinned footer, visible step progress, and each new
  step scrolled to its title rather than inheriting the previous page's scroll position.
- Manifest copies to the clipboard and opens Slack's create-app page.
- Public-only manifest contains no `groups:*` scopes.
- Both manifests enable Socket Mode and subscribe to public message/reaction user events;
  only the public+private variant subscribes to `message.groups`.
- User token must start with `xoxp-`; inline validation identifies the wrong token type and
  bot tokens are rejected.
- App token must start with `xapp-`; inline validation identifies the wrong token type and
  Slack still verifies that it has `connections:write`.
- Channel search, **Select visible**, and **Clear visible** update the selected count and
  persist watch state.
- Both Slack tokens are stored per workspace in Keychain, not UserDefaults, plist, SQLite, or logs.
- Re-launching skips onboarding and opens the main window directly.

## 3. Configure the LLM (Settings tab)

- Open Settings from the icon-only gear in the main toolbar. Confirm its **Settings**
  tooltip appears on hover.
- **Provider:** Anthropic (default), OpenAI, Gemini, Generic API, Ollama, Codex CLI,
  or Claude Code.
- **Model:** e.g. `claude-opus-4-8`, `gpt-4o`, `gemini-2.0-flash`, `llama3` (Ollama).
- **API key:** stored only in the Keychain (HTTP providers). Ollama/CLI need no key.
- **Endpoint URL:** for Generic API / Ollama (defaults to `localhost:11434` for Ollama).
- **CLI path:** optional override for Codex/Claude Code (otherwise auto-detected on PATH).
- **Summary interval** (default 6h) and **staleness threshold** (default 48h). There is
  no poll-interval setting.
- Wait for the toolbar status to return to **Autosaved**. Provider/model changes take
  effect on next launch.

Pass criteria:

- HTTP provider keys are stored only in Keychain.
- Saving settings does not print secrets.
- Ollama/CLI providers work without an API key.
- If no LLM is configured, rules-only detection still works and summaries/evolution are
  skipped cleanly.

## 4. Core detection scenarios

Socket Mode should process these without clicking anything. There is no message Refresh
button; bounded gap recovery runs automatically at lifecycle and foreground boundaries.

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
- Verify useful output is active immediately and no approval alert or Evolution column appears.
- Add a manual learned phrase with type **Dismiss**. A matching actionable message should
  not surface; if a matching item is already active, the next detection pass should dismiss it.
- Verify **Approved phrases** starts collapsed, displays its active count, and reveals phrase
  management only when expanded.
- In Settings, verify the global document affects every channel and an expanded channel
  document affects only that channel. Filter the expandable rows with both `general` and
  Slack-style `#general` searches; results should update on every keystroke and clear action.
- Edit the global guidance document, wait for the autosave status to return to **Saved**,
  repeat for a channel document, and verify both persist after reopening Settings.
- Dismiss `Did anyone record yesterdays meeting?`, then post
  `Did anyone record todays meeting?`. The second message should remain out of
  Needs attention even though the built-in `did anyone` rule would otherwise surface it.
- Dismiss another meeting-recording variant. Evolution should not append a duplicate rule.
- Resolve a coordination-only thread such as `Can you page on-call?` → `Paging now`.
  Evolution should not append a new resolution rule because that behavior is already in
  the built-in classifier and thread-resolution prompts.
- Use **Revert all learned patterns** and verify phrase detection and active AI guidance
  return to base behavior.
- Seed or manually create learned guidance near 8,000 combined characters, perform an action,
  and verify a second model call condenses the global/channel documents below the threshold.

Without an LLM configured:

- Triage still writes labels.
- Evolution logs a no-LLM skip.
- No automatic prompt update is created.

## 6. Resolution and reopen behavior

- **Heuristic resolution:** on a surfaced question, add a resolved reaction/emoji
  (`✅`, `☑`, `👍`) or reply with explicit "fixed/done/shipped/resolved" wording.
  The item should leave Needs attention automatically as resolved.
- **Open/in-progress guard:** add an open/in-progress reaction/emoji (`👀`, `⏳`, `⚠️`) to
  an unresolved thread. The item should stay open.
- **Reopened-thread checkmark:** reopen a thread while an older 👀 remains, then add ✅.
  The newer checkmark should close the item immediately.
- **LLM resolution:** on a surfaced item, have a 3+ message back-and-forth that ends
  resolved without explicit resolution keywords, for example "cleared the cache, green
  now". Refresh. With an LLM configured, the item should auto-close if confidence is high.
- **Reopen:** after resolving an item, add a newer actionable reply such as "actually this
  is failing again, can someone look?" The item should reopen and clear the old
  resolution reason.
- **Edited activity:** resolve an item, then edit an older reply to "this is still failing".
  It should reopen even though the Slack message timestamp is old.
- **Dismissed activity:** dismiss an item, add "the outage is back", and verify it reopens.
  Repeat with a non-actionable "thanks" reply; that one must stay dismissed.
- **Reaction reversal:** close an item with ✅, remove the final ✅, and verify it reopens.
  Adding 👀/⏳/⚠️ to a resolved item should also reopen it.
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
- Adding a watched channel in Settings should immediately backfill only today's history and
  update Overview and Needs attention without waiting for lifecycle recovery.

### Realtime mutation coverage

- Add or leave a watched public/private channel. Slack's generated join/leave history
  notice must not appear in Review or Needs attention, even when it mentions the connected
  user. It must not create a calibration label or evolution proposal.
- Edit an older root message from context-only text to an actionable ask. It should be
  reclassified even though its Slack timestamp predates `lastDetectedTS`.
- Edit an active root so it is no longer actionable. Its stale local item should disappear.
- Delete a reply. The reply should disappear locally and its parent thread should refresh.
- Delete a root. Its local thread and item should be removed.
- Add and remove a reaction on a root and on a reply. Resolution should update from a
  direct thread refresh without a full workspace history request.

## 8. Socket Mode, gap recovery, and app lifecycle

- Quit Slacker, post messages in watched channels, relaunch. The app should backfill and
  process messages posted while it was offline.
- Put the Mac to sleep, post while it sleeps, wake it, and verify one HTTP reconciliation
  closes the gap before realtime delivery continues.
- Disconnect networking, post activity, restore networking, and verify Socket Mode
  reconnects with backoff followed by one workspace catch-up.
- Let the app sit idle for at least 10 minutes. Verify there are no recurring
  `conversations.history` calls; only the WebSocket remains active.
- Close the main window without choosing Quit, post a watched-channel message, and reopen
  Slacker from the menu bar. Verify the message was processed while the window was closed.
- During relaunch recovery, verify tracked threads are requested at no more than three at
  once and only changed roots are re-evaluated; unchanged roots must not invoke summaries.
- Restart after settings changes and verify provider/model/channel choices persist.
- Force a Slack `refresh_requested` disconnect (or wait for Slack connection rotation) and
  verify the old socket is replaced without crashing or exposing its URL in logs.

## 9. Multi-workspace and channel settings

- Add another workspace from Settings if available. Expand each compact workspace row and
  verify it has its own connection state, `xapp-` replacement control, and channel list.
  Confirm its `xoxp-` token remains stored separately in Keychain.
- Post simultaneously in watched channels in both workspaces. Verify events and items never
  cross workspace boundaries.
- Remove one workspace. Verify both of its Keychain tokens are deleted and its socket stops,
  while the other workspace remains live.
- Refresh channel list after joining a new Slack channel. The new channel should appear in
  the Add channel flow.
- Add that channel. Today's history should begin processing immediately in the background;
  no main Refresh click should be required.
- Stop watching a channel. Refresh. New messages from that channel should not produce items.
- Change channel sensitivity and verify high sensitivity surfaces more, low sensitivity
  surfaces less, without violating "uncertain goes to review."

## 10. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `Ingestion: 0 watched channel(s)` | No channels selected → pick some in Settings. |
| No realtime update after sending | Open Settings, expand the workspace row, and check its connection state. Configure/replace its `xapp-` token if setup is required or Slack rejected it. |
| `Ingestion[#x]: no new…` after Refresh | Wrong channel, not a member, or already reconciled. |
| Message ingested but no item | It wasn't actionable (expected). Check for `… not actionable`. |
| Nothing in Overview | No LLM configured (`Summary skipped: no LLM configured`) → set provider + key. |
| Token rejected on Connect | Re-copy the full `xoxp-` **User** token (not a bot token). |
| Socket Mode token rejected | Generate an `xapp-` app-level token under Basic Information with `connections:write`. |
| Private channels missing | Use the **public + private** manifest variant; you must be a member. |
| Socket connection issue | Network/Slack interruption or revoked app token. The client retries with bounded backoff; replace the token if it persists. |
| HTTP `rateLimited` during Refresh/recovery | Transient; Web API retries honor `Retry-After`. |
| CLI provider error | Set the explicit **CLI path** in Settings; ensure the tool is logged in. |
| No evolution update after an action | No LLM configured, no reusable change was returned, or output was rejected by safety filters. |
| Learned update does nothing | Verify self-evolution is enabled and inspect the saved global/channel guidance documents in Settings. |
| Dismissed item does not reopen | Expected only for old or non-actionable activity. New actionable text, a direct mention, or an open reaction reopens it. |

## 11. Privacy and security sanity check

- Slacker only contacts `slack.com`, your configured LLM endpoint, and GitHub release
  endpoints for EdDSA-verified updates. Confirm in Console.app / a proxy if you like.
- Both Slack tokens + the LLM key live only in the Keychain (search Keychain Access for
  `com.slacker.Slacker`); they are never written to the DB, plist, or logs (redacted).
- Slack content scopes are read-only user-token scopes. No DM or bot scopes. The app-level
  token's `connections:write` scope can only open Socket Mode.
- Confirm neither `xapp-` values nor temporary `wss://` URLs appear in logs or error UI.
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
