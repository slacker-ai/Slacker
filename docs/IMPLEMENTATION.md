# Implementation Requirements — Slacker (macOS)

**Audience:** Claude Code. This is the build spec.
**Stack:** Native Swift / SwiftUI, macOS 14+.
**Build order:** Phases are sequential — each is shippable and testable before the next. Do not start a phase until the prior phase's acceptance criteria pass.

> App name: **Slacker**. Avoid surveillance-flavored words ("monitor," "track employees") in user-facing strings; prefer "catch-up," "open loops," "needs attention."

---

## 0. Product in one paragraph

A local-first macOS menu-bar app. The user creates their own Slack app from a published manifest, installs it to their workspace, and provides its read-only user token plus an app-level Socket Mode token. Socket Mode delivers activity from selected channels in real time; targeted Slack Web API reconciliation closes gaps on launch, wake, reconnect, and foreground activation. Full threads feed a detection pipeline that surfaces **missed follow-ups**, **stale items**, and direct **mentions** in a ranked "Needs attention" list. Ambiguous items go to a **review queue**; the user's triage there calibrates detection over time. An **overview tab** gives an at-a-glance, per-channel daily summary. All message processing is local; outbound calls are limited to Slack's API/Socket Mode, the user's own LLM provider (BYO key), and GitHub release assets for signed application updates.

---

## 1. Tech stack & dependencies

| Concern | Choice | Notes |
|---|---|---|
| Language / UI | Swift 5.9+, SwiftUI | macOS 14 Sonoma minimum (modern `MenuBarExtra`, `Observation`) |
| App shell | `MenuBarExtra` (menu bar) + a unique main `Window` | Closing the window keeps the menu-bar process connected |
| Concurrency | Swift Concurrency (`async/await`, actors) | Socket Mode, reconciliation, and detection run off the main actor |
| Local DB | SQLite via **GRDB.swift** | Mature, typed, migrations, observation. Do NOT hand-roll SQLite |
| Secrets | **Keychain Services** | Per-workspace `xoxp-` + `xapp-` tokens and LLM API key. Never UserDefaults/plist/SQLite |
| HTTP | `URLSession` (native) | No Alamofire needed |
| JSON | `Codable` | |
| Realtime | Native `URLSessionWebSocketTask` | No Slack/Bolt dependency and no recurring poll timer |
| Updates | **Sparkle 2** | HTTPS appcast, EdDSA verification, Developer ID signed/notarized DMG |
| Packaging | Xcode project, signed `.app`, notarized DMG | GitHub Actions builds test artifacts and tag-driven public releases |

**No backend. No third-party analytics. No telemetry that leaves the device.** This is a hard requirement, not a preference — it is the product's core differentiator.

Release CI/CD:
- Pull requests and pushes to `main` run `xcodegen generate`, Swift package resolution,
  `xcodebuild build`, and `xcodebuild test`.
- Tags matching `v*` run the same tests, then archive a Release build, Developer ID sign,
  export, package a drag-to-Applications DMG, notarize, staple, checksum, EdDSA-sign the
  update, generate `appcast.xml`, and publish a draft GitHub Release.
- Public DMGs require Apple Developer account secrets in GitHub Actions. Ad-hoc local
  builds are not acceptable for public distribution because Gatekeeper will block or warn
  on normal downloads.

---

## 2. Project structure

```
Slacker/
├── SlackerApp.swift             // @main, MenuBarExtra + WindowGroup
├── Core/
│   ├── Models/                  // Codable + GRDB records (see §4)
│   ├── Database/                // GRDB setup, migrations, DAOs
│   ├── Keychain/                // per-workspace Slack tokens + API key storage
│   └── Config/                  // AppSettings (thresholds, selected channels)
├── Slack/
│   ├── SlackClient.swift        // API calls (conversations.*, auth.test, users.*)
│   ├── SlackModels.swift        // API response Codables
│   ├── SocketModeClient.swift   // URLSession WebSocket, ack, dedupe, reconnect (actor)
│   ├── SocketModeModels.swift   // envelopes, user events, connection state
│   ├── SyncCoordinator.swift    // event routing/debounce + lifecycle reconciliation
│   └── Manifest/                // bundled manifest JSON variants (§5)
├── Detection/
│   ├── RuleEngine.swift         // high-confidence pattern matching
│   ├── LLMClient.swift          // BYO-key provider abstraction
│   ├── Classifier.swift         // orchestrates rules → LLM → routing
│   ├── ResolutionDetector.swift // closes loops (§7.4)
│   ├── ItemThreadSummaryService.swift // thread summaries + LLM resolution backstop
│   ├── SummaryService.swift     // interval-gated daily channel summaries
│   ├── Calibration.swift        // per-channel threshold calibration (§7.5)
│   ├── LearnedPatterns.swift    // injectable phrase bank + RuleBucket (§7.5a)
│   ├── PatternStore.swift       // learned-pattern/guidance read-write façade (§7.5a)
│   └── PatternEvolutionService.swift // immediate phrase/prompt learning (§7.5a)
├── Features/
│   ├── Onboarding/              // manifest choice, xoxp/xapp paste, validation
│   ├── AttentionList/           // ranked needs-attention view
│   ├── Overview/                // per-channel summaries
│   ├── ReviewQueue/             // triage UI
│   └── Settings/                // channels, thresholds, summary cadence, provider credentials
└── Resources/
```

---

## 3. Non-functional requirements (apply to every phase)

- **Privacy:** message text never leaves through the updater. Runtime egress is limited to
  `slack.com`, the configured LLM endpoint, and the fixed GitHub feed for signed releases.
- **Secrets:** Slack user/app tokens and LLM key live only in Keychain. Never log them.
  Redact `xoxp-`, `xapp-`, and provider keys in every error surface. Never persist or log
  the temporary URL returned by `apps.connections.open`.
- **Resilience:** all Slack/LLM calls wrapped with retry + exponential backoff; honor HTTP 429 `Retry-After`. Network loss must never crash or corrupt state.
- **Performance:** detection runs off the main actor; UI stays responsive with 20 channels × thousands of messages. Backfill is incremental, never a full re-scan.
- **Idempotency:** re-processing the same message must not create duplicate items (dedupe on Slack message `ts` + channel id).
- **Observability (local only):** structured logs to a local file (rotating), used for onboarding drop-off and detection debugging. No remote logging.

---

## 4. Data model (GRDB / SQLite)

Define migrations from day one. Tables:

- **appSettings** — single-row config: `id`, `staleness_hours` (default 48), `summary_refresh_interval_minutes` (default 360), `manifest_variant`, `llm_provider`, `llm_model`, `llm_base_url`, `cli_path_override`, `onboarding_completed`, `team_id`. The legacy `poll_interval_seconds` column remains for append-only database compatibility but is ignored. Secrets are not stored here.
- **workspace** — `id`, `name`, `auth_user_id`, `manifest_variant`, `created_at`. Keychain stores `slack.user.token.<workspaceID>` and `slack.app.token.<workspaceID>`.
- **channel** — `id` (Slack channel id, PK), `workspace_id`, `name`, `is_private` (bool), `is_watched` (bool), `sensitivity` (enum: low/normal/high; default normal), `last_polled_ts` (durable HTTP reconciliation cursor; name retained to avoid a migration), `last_detected_ts`.
- **message** — `id` (PK, `channelId+ts`), `channel_id` (FK), `thread_ts` (nullable), `user_id`, `text`, `ts` (Slack timestamp), `reactions` (JSON), `first_observed_at`, `content_edited_at`, `open_reaction_observed_at`, `resolved_reaction_observed_at`, `resolved_reaction_removed_at` (nullable local observation times), `ingested_at`. Index on `(channel_id, ts)` and `thread_ts`.
- **item** — the unit of attention. `id` (UUID), `channel_id`, `root_message_ts`, `thread_ts`, `type` (enum: missed_followup / stale / mention), `state` (enum: open / surfaced / review / resolved / dismissed; legacy local DBs may contain snoozed), `confidence` (double), `created_at`, `last_evaluated_at`, `snoozed_until` (legacy nullable), `resolution_reason` (nullable enum). Index on `state`.
- **label** — calibration training data. `id`, `item_id` (nullable), `message_ts`, `channel_id`, `user_verdict` (enum: matters / ignore), `source` (enum: review_triage / dismissal / mark_resolved), `created_at`.
- **summary** — `id`, `channel_id`, `date`, `text`, `generated_at`. One row per channel per day; regeneration is gated by new activity plus `summary_refresh_interval_minutes`.
- **user** — `id` (Slack user id), `display_name`, `real_name`. Cache for grounding (§7).
- **learnedPattern** — self-evolution (§7.5a). `id`, `channel_id` (nullable; NULL = global), `bucket` (enum: ask/blocker/problem/help/decision/deadline), `phrase`, `status` (enum: proposed/approved/rejected/retired), `source` (enum: llm/manual), `rationale` (nullable), `supporting_label_count`, `created_at`, `decided_at` (nullable). Unique index on `(channel_id, bucket, phrase)`.
- **learnedGuidance** — self-evolution (§7.5a). `id`, `channel_id` (nullable), `text`, `status`, `version`, `created_at`, `decided_at` (nullable). The newest approved row per scope is the editable active document; automatic appends, condensation, and manual edits create versions.
- **evolutionRun** — *deprecated.* Cadence bookkeeping for the former batched evolution pass
  (`channel_id` PK, `last_run_at`). Learning is now per-triage with no cadence gate, so this
  table is unused; it remains only because migrations are append-only.

Migrations are append-only through `v18_automatic_evolution`.

---

## 5. Phase 1 — Slack connection & onboarding

**Goal:** user goes from download to validated, Keychain-stored user and Socket Mode tokens with channels selectable.

### 5.1 Manifest variants (bundled as resources, also published in repo)
Two JSON manifests, identical except private-channel access:
- **Default (public + private) user scopes:** `channels:history`, `channels:read`, `groups:history`, `groups:read`, `reactions:read`, `users:read`.
- **Public-only user scopes:** `channels:history`, `channels:read`, `reactions:read`, `users:read`.

Both set `socket_mode_enabled: true` and subscribe user events for `message.channels`,
`reaction_added`, and `reaction_removed`; the private variant also subscribes
`message.groups`. No bot scopes and no `im:*`/`mpim:*` scopes. Content access stays
read-only. The separately generated app-level token has `connections:write`, which only
authorizes `apps.connections.open`.

### 5.2 Onboarding flow (Features/Onboarding)
1. First-run screen: explain "you create your own Slack app; we never see your workspace; ~5 min."
2. **Manifest choice screen:** present the two variants with the tradeoff stated plainly (private coverage vs. strictest privacy). Selection stored in settings. *(This is the PRD's recommended first-run choice — implement it as a choice, not a silent default.)*
3. Button: open `https://api.slack.com/apps?new_app=1`. Copy the chosen manifest JSON to clipboard and show paste instructions (manifest-URL prefill is brittle; clipboard + instructions is the reliable path).
4. Instruct: Create → **Install to Workspace** for the selected workspace → approve consent screen.
5. Open **OAuth & Permissions** and copy **OAuth Tokens → User OAuth Token** (`xoxp-`).
6. Open **Basic Information → App-Level Tokens**, generate an `xapp-` token with
   `connections:write`, and paste both credentials into secure fields.
7. Validate the user token with `auth.test` and the app token with
   `apps.connections.open`. Persist neither until both succeed. Store both under the
   returned team ID in Keychain and cache the user.
8. Show "Connected to {team} as {user}" and proceed to channel picker.

### 5.3 Failure handling (explicit states, not dead ends)
- Not signed into Slack in browser → detect failure, instruct to sign in.
- Wrong workspace → show `auth.test` team name so user can verify/redo.
- Admin-restricted app creation → show "send this manifest to your admin" message with the manifest.
- Invalid/expired user token → clear, friendly `xoxp-` re-paste prompt.
- Missing/revoked app token or missing `connections:write` → actionable `xapp-` setup copy.
- Existing installations without an app token stay onboarded but show a prominent
  **Socket Mode setup required** banner and per-workspace secure input in Settings.

### 5.4 Acceptance criteria
- [ ] A user with no prior setup can reach a validated token and a channel list in <10 min.
- [ ] Both tokens are isolated per workspace in Keychain; neither appears in UserDefaults,
      plist, DB, logs, or error UI.
- [ ] Choosing public-only produces a consent screen without `groups:*`.
- [ ] Each failure mode shows actionable copy, never a blank/dead screen.

---

## 6. Phase 2 — Realtime ingestion and reconciliation

**Goal:** keep a local mirror of messages + threads for watched channels, with correct backfill.

### 6.1 Channel selection
- `conversations.list` (types: `public_channel`, and `private_channel` if default manifest) → store/refresh `channel` rows for channels the user is in.
- Settings UI: an Add channel catalog plus compact watched-channel rows grouped by workspace.
  Each watched channel has a `sensitivity` control and remove action (used in §7.5).

### 6.2 Socket Mode transport (`SocketModeClient` actor)
- Call `apps.connections.open` with the workspace's `xapp-` token and immediately create a
  native `URLSessionWebSocketTask` from the returned temporary `wss://` URL.
- Decode envelope headers first and acknowledge every envelope ID before doing database,
  HTTP, detection, or LLM work. Malformed/duplicate Events API payloads are acknowledged
  and ignored; event IDs are de-duplicated in a bounded in-memory window.
- Route events by payload `team_id`. A delivery is accepted only when its team matches the
  connection and its channel belongs to that watched workspace.
- Replace the connection on Slack `disconnect`/`refresh_requested`. Network/API failures
  expose a safe connection state and retry with bounded exponential backoff plus jitter.
- Never persist, display, or log the app token or temporary WebSocket URL.

### 6.3 Event-driven sync (`SyncCoordinator` actor)
- Debounce bursts per `(workspace, channel)` (currently 350 ms).
- New top-level message → `conversations.history(oldest: last_polled_ts)` for that channel.
- Reply → `conversations.replies` for its root.
- Reaction add/remove → resolve the affected local message to its root and refresh that thread.
- Edit → refresh the affected thread and force that root through detection even when its
  timestamp predates `last_detected_ts`; remove an active item if edited text is no longer actionable.
- Delete → remove the local message. Root deletion removes its replies/item; reply deletion
  refreshes the surviving parent thread.
- Resolve unknown users via cached `users.info` and persist messages idempotently on
  `(channel_id, ts)`.
- After each debounced ingestion batch, run detection only for the affected roots and
  update the UI immediately. Thread and eligible daily summaries run in one coalesced,
  root-scoped background worker, so they never hold up message evaluation.

### 6.4 Gap recovery and lifecycle
- HTTP gap recovery runs only on launch, system wake, and successful reconnect. There is
  no recurring timer, manual message refresh, or poll-interval setting.
- Marking a channel as watched immediately launches an asynchronous channel-only backfill.
  Its imported roots go through targeted detection immediately.
- For each watched channel, `conversations.history` starts from durable `last_polled_ts`.
  A brand-new channel starts at local midnight and retrieves only the current day's activity. Tracked item threads are compared
  as full snapshots in background batches of 12. Slack HTTP work is capped at three
  concurrent requests. Only roots whose stable Slack snapshot changed proceed to detection,
  thread summaries, and channel summaries.
- Closing the main window leaves the menu-bar app and Socket Mode connections running.
  A true Quit stops the process; the next launch resumes from the durable channel cursors.
- Detection keeps independent `last_detected_ts`; staleness uses Slack message timestamps,
  so sleep/offline gaps do not distort age.
- Web API 429 handling still honors `Retry-After` with bounded retries.

### 6.5 Acceptance criteria
- [ ] Watched-channel messages, replies, reactions, edits, and deletions update without a timer.
- [ ] Bursts produce one targeted ingestion batch and one downstream analysis pass.
- [ ] Killing the app or going offline then reconnecting backfills with no duplicates.
- [ ] Idle runtime produces no scheduled `conversations.history` traffic.
- [ ] Multiple workspaces remain isolated by team ID, Keychain accounts, channels, and sockets.

---

## 7. Phase 3 — Detection (Detection/) — the core

Detection is a layered classification engine. Build in this order; gate aggressively on
precision. Lower levels are cheap and deterministic; higher levels add context or LLM
judgment only when needed.

### 7.1 Classification (commodity — keep simple)
Determine whether a message is a question / request / decision-pending / blocker /
context-only.

**Level 0 — ingestion eligibility**
- Only watched channels are evaluated.
- Top-level/root messages newer than `channel.last_detected_ts`, active item roots, and
  roots with new messages mentioning the connected user are classified.
- Thread replies are still fetched because later levels need context and resolution.

**Level 1 — deterministic rules (`RuleEngine`)**
- Handles high-confidence cases without an LLM. This includes directed questions, ask verbs,
  review/approval/share requests, ping/page/loop-in handoffs, deadlines, owner/help
  questions, blockers, access/dependency waits, failed build/test/deploy pipelines,
  timeouts, incidents, degraded service, outages, release/deploy blockers, and pending decisions.
- Strip triple-backtick fenced blocks before rules, LLM prompts, summaries, resolution, and
  evolution. Pasted logs often contain words like "failed", "blocked", "done", or "fixed";
  for now anything inside ``` fences is evidence to ignore, not user intent.
- Emits `MessageClass` + confidence:
  - `openQuestion`
  - `decisionPending`
  - `blocker`
  - `contextOnly`
- Precedence matters: explicit blockers win over generic question words, but explicit
  coordination asks ("ping/page/loop in on-call about timeouts") remain `openQuestion`.
  Rules must stay narrow; broad single-word patterns are rejected for learned phrases.

### 7.2 Salience → map to surfaced signals
**Level 2 — signal mapping**
- open question (unanswered, directed) → candidate **missed_followup**
- decision-pending / blocker (no movement) → candidate **stale**
- direct tag of the connected user (`<@workspace.auth_user_id>`) → candidate **mention**
- context-only → **not surfaced**
Salience uses **thread context** (the whole thread) and **channel norms**, not the message in isolation. Follow-up/bump/checking-in replies inside a thread are stale signals, and active item roots are rechecked so new reply context can retag an existing item.

### 7.3 Confidence-gated routing
**Level 3 — thresholds and LLM escalation**
- Default thresholds:
  - `confidence ≥ 0.80` → create/update `item` in `surfaced` state (Needs attention).
  - `0.50 ≤ confidence < 0.80` → `review` state (Review queue only).
  - `< 0.50` or `contextOnly` → no item.
- Channel sensitivity and calibration may shift thresholds, but only within the same model:
  high → surfaced, medium → review, low → no item.
- `LLMClassifier` is invoked for review-band candidates and, when approved guidance exists,
  as a precision check on surfaced rule hits. It runs only if an LLM provider is configured.
  Prompt returns strict JSON:
  `{"class":"openQuestion|decisionPending|blocker|contextOnly","confidence":0.0-1.0}`.
  Parse/provider failure keeps the rules verdict unchanged. LLM output can promote
  review → surfaced or demote a matching learned-ignore case to context-only, but cannot
  crash the ingestion batch.
- `DetectionService` upserts on `(channel_id, root_message_ts)`. Ordinary root
  reclassification does not overwrite resolved/dismissed/legacy-snoozed states; only the
  explicit new-activity path below may reopen resolved or dismissed work.
- **Never auto-surface uncertain items.** Precision over recall everywhere.

### 7.4 Resolution detection (ResolutionDetector — first-class)
Runs continuously over open/surfaced items, re-evaluating against new thread activity:
- A reply from the asked party → resolved (`reason: replied`).
- A resolved emoji/reaction (✅/☑/👍-style) anywhere in the thread → resolved. If the
  done reaction is newly observed on an older message, use local observation time for
  ordering so the added reaction can close newer open text without making stale reactions
  re-close reopened items. A newly-added done reaction beats an older open reaction on the
  same message.
  (`reason: reacted`).
- An open/in-progress emoji/reaction (👀/⏳/⚠️-style) keeps the item open and blocks
  keyword-only false closes such as "not fixed yet 👀".
- Explicit "done/resolved/shipped/fixed/merged" in-thread → resolved (`reason: stated`).
  Completion phrases are phrase-matched, not raw substrings; speculative wording such as
  "can be done" does not close an item. Same-message actionable text also wins over
  keyword closure.
- Coordination asks to ping/page/notify/hand off someone can resolve on concrete handoff
  replies such as "paging now", "pinged", "notified", or "looped them in".
- Re-check uses the *whole thread*, not just the original message. This is the top false-positive lever: an answered question must auto-close before it ever nags the user.
- LLM thread analysis may auto-close a confidently resolved thread, but only when the
  latest message is not itself actionable by deterministic rules.
- Reopen path: event ingestion and lifecycle recovery compare resolved and dismissed item
  threads. New replies and edits use local first-observed/edit times rather than comparing
  Slack's server clock to the Mac's clock. A compiled regex bank detects explicit recurrence,
  failure, impact, follow-up, ask, and decision language before falling back to learned/base
  phrases and optional LLM guidance. Actionable activity clears `resolution_reason`, resets
  the thread summary, and routes to surfaced/review by confidence. New open reactions/emoji
  reopen immediately. Removing the final done reaction reopens an item whose resolution
  reason was `reacted`. Non-actionable activity like "thanks" does not reopen; legacy snoozed
  rows remain terminal.
- Mention path: lifecycle gap recovery also compares dismissed item threads. A newer message in a root
  or reply that tags the connected user revives a dismissed/resolved item as `mention`.
  Existing active items are not retagged to mention.

### 7.5 Calibration (Calibration — the flywheel)
- Every triage writes a `label` row (matters/ignore + source).
- Per **channel**, maintain adjustable confidence thresholds derived from accumulated labels (start with sensible defaults; shift thresholds as labels accumulate). High-sensitivity channels surface more; "ignore"-heavy channels surface less.
- v1: threshold tuning from label counts is sufficient. (Learned models / fine-tunes are v2+, only once labels exist.)

#### 7.5a Self-evolving patterns (label-driven phrase + prompt learning)
Calibration tunes *thresholds*; the self-evolving loop tunes the *patterns themselves*,
so detection adapts to each company's language (e.g. team jargon for a blocker).
- Every explicit action immediately calls `evolveFromTriage` with the current thread,
  reactions, effective prompts, and recent contrasting labels. The strict-JSON response
  contains optional global guidance, source-channel guidance, and one validated phrase.
  Useful output is stored as approved immediately; there is no approval queue or cadence.
- Ignore and mark-resolved actions cannot create trigger phrases. All phrases remain
  multi-word, admissible, scoped, and deduplicated before entering `RuleEngine`.
- Global and channel guidance are independently editable/versioned. Their composition is
  appended to both LLM system prompts. If an automatic append makes the combined learned
  text reach 8,000 characters, a separate call condenses both documents; an optimistic
  version check prevents overwriting concurrent manual edits.
- The Evolution board column and approval notifications are removed. Settings provides
  a global editor, live-searchable expandable channel editors, character counts, a collapsed
  Approved phrases manager, and Revert all. The composed internal system prompts are not exposed.
- The base rule banks and the base LLM prompt remain fixed in code; only the learned
  overlay (composed at `RuleEngine.init` / appended to the LLM `system` prompt) changes.

### 7.6 Pre-build calibration check (do before trusting the pipeline)
Provide a small offline harness: take ~100 real messages, let 2–3 people label "needs attention," compute inter-rater agreement and pipeline precision against that set. This number is the real precision ceiling. Build this harness early; it gates whether the definition is narrow enough.

### 7.7 Acceptance criteria
- [ ] On a real channel sample, surfaced-item precision ≥80% (or ≥ measured inter-rater ceiling).
- [ ] An answered question auto-closes in the event batch and never remains a missed follow-up.
- [ ] No uncertain item ever appears in Needs attention (only in Review queue).
- [ ] Triaging items measurably shifts subsequent thresholds for that channel.
- [ ] Without approved guidance, LLM is not called for messages the rules resolve confidently;
  with approved guidance, surfaced rule hits receive one precision check (verify call count).
- [ ] Each user action fires one automatic evolution call; a missing/pruned message writes nothing; validated phrases and global/channel guidance are active immediately; crossing 8,000 learned characters triggers condensation.

---

## 8. Phase 4 — UI (Features/)

### 8.1 Menu bar (`MenuBarExtra`)
- Icon shows a badge count of open surfaced items. Click → popover with top items + "Open app" to the main window.

### 8.2 Needs attention (default view)
- Ranked list grouped by type (missed follow-ups, stale, mentions). Each row: channel, snippet, age, confidence indicator.
- Row actions: **Open in Slack** (deep link `slack://channel?team={teamId}&id={channelId}` + thread ts), **Resolve**, **Dismiss**. Resolve/dismiss write `label` rows (§7.5).
- This is always the landing view and the headline.

### 8.3 Overview tab
- One row per watched channel: today's summary (from `summary`), open-item count, last activity. Channel-scoped only — **never** per-person breakdowns.
- Daily summary generation: first summary per channel/day via LLMClient over that day's messages; regeneration requires newer activity and the configurable summary interval. Store in `summary`.

### 8.4 Review queue tab
- Ambiguous items. Each: **This matters** (→ promote to surfaced + label) / **Ignore** (→ dismiss + label). Triage feeds calibration.

### 8.5 Settings
- The icon-only toolbar gear opens Settings; its accessible label and tooltip remain
  **Settings**. Changes autosave and expose their status in the toolbar.
- Watched channels + per-channel sensitivity; compact expandable workspace rows for Socket
  Mode state, secure `xapp-` replacement, and disconnect; staleness threshold; summary
  interval; LLM provider/model + API key (Keychain). No poll interval.

### 8.6 Acceptance criteria
- [ ] Badge count matches open surfaced items.
- [ ] "Open in Slack" lands on the exact thread.
- [ ] No view anywhere aggregates by person.
- [ ] Empty states read "All caught up," never blank.

---

## 9. LLM integration (Detection/LLM)

- **Provider abstraction** (`LLMClient` protocol) with **seven** backends behind one
  factory (`LLMClientFactory`), selected in settings (expanded from the original
  Anthropic+OpenAI plan):
  - **HTTP/key:** OpenAI (Chat Completions), Anthropic (Messages), Google Gemini,
    a generic OpenAI-compatible endpoint (BYO base URL), and Ollama (local Llama, localhost).
  - **CLI/subprocess:** OpenAI Codex CLI (`codex exec`) and Claude Code (`claude -p`,
    prompt via stdin). Binary located by override path → PATH → common install dirs.
  - Default provider shown in onboarding: **Anthropic** (resolves §11.3).
- Model + key from settings/Keychain. HTTP providers share the `HTTPTransport` seam;
  CLI providers share a `CLIRunner` seam — both are unit-testable without real I/O.
- **App Sandbox is intentionally OFF** (see `Slacker.entitlements`) so the CLI
  backends can spawn subprocesses and read their own home-dir auth. Trust guarantees
  do not depend on the sandbox: egress is restricted to Slack, the user's LLM endpoint,
  and the signed GitHub update feed, while secrets live only in the Keychain.
- Used for: (a) ambiguous-message classification and approved-guidance precision checks,
  (b) thread summaries and LLM resolution backstop, (c) daily channel summaries, and
  (d) learned phrase/guidance proposals. Confident rule hits avoid the LLM unless an
  approved guidance document exists.
- Strict-JSON contract for classification; defensive parsing (tolerates code fences /
  surrounding prose); parse failure → "uncertain" (→ review queue), never a crash.
- Failures degrade gracefully: rules-only detection still functions; summaries skippable.

---

## 10. Build milestones (suggested commits/PRs)

1. **M0 — Scaffold:** Xcode project, `MenuBarExtra` + window, GRDB setup + migrations, Keychain wrapper. App launches, empty.
2. **M1 — Connection:** Socket Mode manifests, onboarding flow, `auth.test` +
   `apps.connections.open`, both tokens in Keychain, channel list. (Phase 1)
3. **M2 — Ingestion:** native Socket Mode + targeted thread/channel reconciliation +
   lifecycle backfill, local mirror. Verify via DB inspection. (Phase 2)
4. **M3 — Detection core:** RuleEngine + routing + Review queue plumbing (no LLM yet). (Phase 3.1–7.3 rules path)
5. **M4 — LLM + resolution:** LLMClient, ambiguous classification, ResolutionDetector. Precision harness (§7.6). (Phase 3 complete)
6. **M5 — UI:** Needs attention, Review queue, Settings, menu bar badge. (Phase 4 core)
7. **M6 — Overview + summaries + calibration:** overview tab, daily summaries, threshold tuning from labels. (Phase 4 + 7.5)
8. **M7 — Hardening:** backoff/429, failure states, no-egress test, sign/notarize.

Ship M1–M5 to the first design partner before polishing M6–M7.

---

## 11. Decisions to confirm before/while building

1. **Private-channel default** — spec implements the first-run *choice* (§5.2). Confirm this over a silent default.
2. **Summary scope in v1** — daily summaries + overview are specced; confirm they're in M6 and not cut to reach a design partner faster (PRD flags testing whether they earn their place).
3. **LLM default provider/model** — RESOLVED: default provider is **Anthropic**;
   seven providers supported (§9). Model is user-entered per provider.
4. **Staleness default** — 48h assumed; confirm. (Implemented as 48h default.)
