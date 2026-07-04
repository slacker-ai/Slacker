# Implementation Requirements — Slacker (macOS)

**Audience:** Claude Code. This is the build spec.
**Stack:** Native Swift / SwiftUI, macOS 14+.
**Build order:** Phases are sequential — each is shippable and testable before the next. Do not start a phase until the prior phase's acceptance criteria pass.

> App name: **Slacker**. Avoid surveillance-flavored words ("monitor," "track employees") in user-facing strings; prefer "catch-up," "open loops," "needs attention."

---

## 0. Product in one paragraph

A local-first macOS menu-bar app. The user creates their own Slack app from a published manifest, installs it to their workspace, and pastes the resulting user token into this app. The app polls selected channels, pulls full threads, and runs a detection pipeline that surfaces **missed follow-ups**, **stale items**, and direct **mentions** in a ranked "Needs attention" list. Ambiguous items go to a **review queue**; the user's triage there calibrates detection over time. An **overview tab** gives an at-a-glance, per-channel daily summary. All message processing is local; the only outbound network calls are to Slack's API and to the user's own LLM provider (BYO key).

---

## 1. Tech stack & dependencies

| Concern | Choice | Notes |
|---|---|---|
| Language / UI | Swift 5.9+, SwiftUI | macOS 14 Sonoma minimum (modern `MenuBarExtra`, `Observation`) |
| App shell | `MenuBarExtra` (menu bar) + a main `WindowGroup` | Menu bar is primary entry; main window for lists/settings |
| Concurrency | Swift Concurrency (`async/await`, actors) | Detection + polling run off the main actor |
| Local DB | SQLite via **GRDB.swift** | Mature, typed, migrations, observation. Do NOT hand-roll SQLite |
| Secrets | **Keychain Services** (via a thin wrapper or `KeychainAccess`) | Slack token + LLM API key. Never UserDefaults/plist/SQLite |
| HTTP | `URLSession` (native) | No Alamofire needed |
| JSON | `Codable` | |
| Scheduling | `Task` + async timer loop; optional `NSBackgroundActivityScheduler` | For periodic polling |
| Packaging | Xcode project, signed `.app`, notarized DMG | GitHub Actions builds test artifacts and tag-driven public releases |

**No backend. No third-party analytics. No telemetry that leaves the device.** This is a hard requirement, not a preference — it is the product's core differentiator.

Release CI/CD:
- Pull requests and pushes to `main` run `xcodegen generate`, Swift package resolution,
  `xcodebuild build`, and `xcodebuild test`.
- Tags matching `v*` run the same tests, then archive a Release build, Developer ID sign,
  export, package a drag-to-Applications DMG, notarize, staple, checksum, and publish a
  draft GitHub Release.
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
│   ├── Keychain/                // token + API key storage
│   └── Config/                  // AppSettings (thresholds, selected channels)
├── Slack/
│   ├── SlackClient.swift        // API calls (conversations.*, auth.test, users.*)
│   ├── SlackModels.swift        // API response Codables
│   ├── Poller.swift             // polling loop + backfill (actor)
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
│   └── PatternEvolutionService.swift // label-driven phrase/prompt proposals (§7.5a)
├── Features/
│   ├── Onboarding/              // manifest choice, token paste, validation
│   ├── AttentionList/           // ranked needs-attention view
│   ├── Overview/                // per-channel summaries
│   ├── ReviewQueue/             // triage UI
│   └── Settings/                // channels, thresholds, summary cadence, API key, manifest variant
└── Resources/
```

---

## 3. Non-functional requirements (apply to every phase)

- **Privacy:** message text never written anywhere off-device. The only egress is `slack.com` and the configured LLM endpoint. Add a unit/integration check that asserts no other hosts are contacted.
- **Secrets:** Slack token and LLM key live only in Keychain. Never log them. Redact tokens in any error output.
- **Resilience:** all Slack/LLM calls wrapped with retry + exponential backoff; honor HTTP 429 `Retry-After`. Network loss must never crash or corrupt state.
- **Performance:** detection runs off the main actor; UI stays responsive with 20 channels × thousands of messages. Backfill is incremental, never a full re-scan.
- **Idempotency:** re-processing the same message must not create duplicate items (dedupe on Slack message `ts` + channel id).
- **Observability (local only):** structured logs to a local file (rotating), used for onboarding drop-off and detection debugging. No remote logging.

---

## 4. Data model (GRDB / SQLite)

Define migrations from day one. Tables:

- **appSettings** — single-row config: `id`, `staleness_hours` (default 48), `poll_interval_seconds` (default 180), `summary_refresh_interval_minutes` (default 360), `manifest_variant`, `llm_provider`, `llm_model`, `llm_base_url`, `cli_path_override`, `onboarding_completed`, `team_id`. Secrets are not stored here.
- **workspace** — `id`, `name`, `auth_user_id`, `manifest_variant`, `created_at`. One Slack token per workspace lives in Keychain.
- **channel** — `id` (Slack channel id, PK), `workspace_id`, `name`, `is_private` (bool), `is_watched` (bool), `sensitivity` (enum: low/normal/high; default normal), `last_polled_ts`, `last_detected_ts`.
- **message** — `id` (PK, `channelId+ts`), `channel_id` (FK), `thread_ts` (nullable), `user_id`, `text`, `ts` (Slack timestamp), `reactions` (JSON), `resolved_reaction_observed_at` (nullable local observation time), `ingested_at`. Index on `(channel_id, ts)` and `thread_ts`.
- **item** — the unit of attention. `id` (UUID), `channel_id`, `root_message_ts`, `thread_ts`, `type` (enum: missed_followup / stale / mention), `state` (enum: open / surfaced / review / resolved / dismissed; legacy local DBs may contain snoozed), `confidence` (double), `created_at`, `last_evaluated_at`, `snoozed_until` (legacy nullable), `resolution_reason` (nullable enum). Index on `state`.
- **label** — calibration training data. `id`, `item_id` (nullable), `message_ts`, `channel_id`, `user_verdict` (enum: matters / ignore), `source` (enum: review_triage / dismissal / mark_resolved), `created_at`.
- **summary** — `id`, `channel_id`, `date`, `text`, `generated_at`. One row per channel per day; regeneration is gated by new activity plus `summary_refresh_interval_minutes`.
- **user** — `id` (Slack user id), `display_name`, `real_name`. Cache for grounding (§7).
- **learnedPattern** — self-evolution (§7.5a). `id`, `channel_id` (nullable; NULL = global), `bucket` (enum: ask/blocker/problem/help/decision/deadline), `phrase`, `status` (enum: proposed/approved/rejected/retired), `source` (enum: llm/manual), `rationale` (nullable), `supporting_label_count`, `created_at`, `decided_at` (nullable). Unique index on `(channel_id, bucket, phrase)`.
- **learnedGuidance** — self-evolution (§7.5a). `id`, `channel_id` (nullable), `text`, `status`, `version`, `created_at`, `decided_at` (nullable). Proposed rows are mined suggestions; the active AI guidance is one editable global Markdown/text document stored as the newest approved global row. Changed autosaves create new versions instead of overwriting history; unchanged text is ignored.
- **evolutionRun** — *deprecated.* Cadence bookkeeping for the former batched evolution pass
  (`channel_id` PK, `last_run_at`). Learning is now per-triage with no cadence gate, so this
  table is unused; it remains only because migrations are append-only.

Migrations are append-only through `v15_resolved_reaction_observed_at`.

---

## 5. Phase 1 — Slack connection & onboarding

**Goal:** user goes from download to a validated, stored token with channels selectable.

### 5.1 Manifest variants (bundled as resources, also published in repo)
Two JSON manifests, identical except scopes (all **user-token** scopes, `oauth_config.scopes.user`):
- **Default (public + private):** `channels:history`, `channels:read`, `groups:history`, `groups:read`, `users:read`.
- **Public-only opt-out:** `channels:history`, `channels:read`, `users:read`.
No bot scopes, no `im:history`/`mpim:history`, no write scopes. No event subscriptions, no Socket Mode (polling).

### 5.2 Onboarding flow (Features/Onboarding)
1. First-run screen: explain "you create your own Slack app; we never see your workspace; ~3 min."
2. **Manifest choice screen:** present the two variants with the tradeoff stated plainly (private coverage vs. strictest privacy). Selection stored in settings. *(This is the PRD's recommended first-run choice — implement it as a choice, not a silent default.)*
3. Button: open `https://api.slack.com/apps?new_app=1`. Copy the chosen manifest JSON to clipboard and show paste instructions (manifest-URL prefill is brittle; clipboard + instructions is the reliable path).
4. Instruct: Create → **Install to Workspace** for the selected workspace → approve consent screen.
5. Instruct: after installation, open the Slack app dashboard's **OAuth & Permissions** page and copy **OAuth Tokens → User OAuth Token** (`xoxp-`). Token paste field accepts that value. (v1.x: capture via a temporary `localhost` redirect to remove the paste — out of scope for v1.)
6. Validate with `auth.test`; on success show "Connected to {team} as {user}", store token in Keychain, cache the user.
7. Proceed to channel picker.

### 5.3 Failure handling (explicit states, not dead ends)
- Not signed into Slack in browser → detect failure, instruct to sign in.
- Wrong workspace → show `auth.test` team name so user can verify/redo.
- Admin-restricted app creation → show "send this manifest to your admin" message with the manifest.
- Invalid/expired token → clear, friendly re-paste prompt.

### 5.4 Acceptance criteria
- [ ] A user with no prior setup can reach a validated token and a channel list in <10 min.
- [ ] Token is in Keychain; not present in UserDefaults, plist, DB, or logs (assert in a test).
- [ ] Choosing public-only produces a consent screen without `groups:*`.
- [ ] Each failure mode shows actionable copy, never a blank/dead screen.

---

## 6. Phase 2 — Ingestion (Slack/Poller)

**Goal:** keep a local mirror of messages + threads for watched channels, with correct backfill.

### 6.1 Channel selection
- `conversations.list` (types: `public_channel`, and `private_channel` if default manifest) → store/refresh `channel` rows for channels the user is in.
- Settings UI: checkbox list; toggling `is_watched`. Per-channel `sensitivity` control (used in §7.5).

### 6.2 Polling loop (actor `Poller`)
- Every 2–5 min (configurable; default 3): for each watched channel, `conversations.history` with `oldest = last_polled_ts` to fetch only new top-level messages. If a channel has never been polled, start with a bounded recent-history window (currently 3 days), not the full channel archive. Update `last_polled_ts` to newest received.
- For any message that is a thread root or has `reply_count > 0` / a new `latest_reply`, call `conversations.replies` to pull/refresh the full thread. Threads are required for detection and resolution.
- Resolve unknown `user_id`s via `users.info` (batch/caching; populate `user` table).
- Persist messages idempotently (dedupe on `channel_id + ts`). Capture `reactions`.

### 6.3 Backfill on wake/launch
- On app launch or system wake: for each watched channel, fetch since `last_polled_ts`; re-run detection on the gap. Staleness is computed from message `ts`, never observation time — a closed laptop over a weekend yields a correct Monday state.
- Detection keeps its own per-channel `last_detected_ts` cursor so restart cycles do not reclassify every stored message, including non-actionable roots that never create item rows.

### 6.4 Rate limits
- Internal/custom app tier (~50 req/min on history methods). Budget requests across channels; backoff on 429 honoring `Retry-After`. With 20 channels at 3-min cadence this is comfortable.

### 6.5 Acceptance criteria
- [ ] New messages in watched channels appear in the local DB within one poll cycle.
- [ ] Thread replies are captured, not just roots.
- [ ] Killing the app for an hour then relaunching backfills the gap with no duplicates.
- [ ] Sustained polling of 20 channels never trips 429s under normal volume.

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
- `LLMClassifier` is invoked only for review-band candidates from the rules and only if an
  LLM provider is configured. Prompt returns strict JSON:
  `{"class":"openQuestion|decisionPending|blocker|contextOnly","confidence":0.0-1.0}`.
  Parse/provider failure keeps the regex/rules review verdict unchanged. LLM output can
  promote review → surfaced or demote to context-only, but cannot crash the poll cycle.
- `DetectionService` upserts on `(channel_id, root_message_ts)` and does not overwrite
  user-terminal states (`dismissed`, plus legacy `snoozed` rows). Resolved items only
  reopen through the explicit reply-reopen path below.
- **Never auto-surface uncertain items.** Precision over recall everywhere.

### 7.4 Resolution detection (ResolutionDetector — first-class)
Runs continuously over open/surfaced items, re-evaluating against new thread activity:
- A reply from the asked party → resolved (`reason: replied`).
- A resolved emoji/reaction (✅/☑/👍-style) anywhere in the thread → resolved. If the
  done reaction is newly observed on an older message, use local observation time for
  ordering so the added reaction can close newer open text without making stale reactions
  re-close reopened items.
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
- Reopen path: ingestion keeps refreshing resolved item threads too. If a reply newer than
  the item's `last_evaluated_at` is itself actionable, detection reopens the existing item
  (clears `resolution_reason`, resets thread summary, and routes to surfaced/review by
  confidence). Non-actionable replies like "thanks" do not reopen. Dismissed items do not
  reopen through this path, and legacy snoozed rows remain user-terminal.
- Mention path: ingestion also refreshes dismissed item threads. A newer message in a root
  or reply that tags the connected user revives a dismissed/resolved item as `mention`.
  Existing active items are not retagged to mention.

### 7.5 Calibration (Calibration — the flywheel)
- Every triage writes a `label` row (matters/ignore + source).
- Per **channel**, maintain adjustable confidence thresholds derived from accumulated labels (start with sensible defaults; shift thresholds as labels accumulate). High-sensitivity channels surface more; "ignore"-heavy channels surface less.
- v1: threshold tuning from label counts is sufficient. (Learned models / fine-tunes are v2+, only once labels exist.)

#### 7.5a Self-evolving patterns (label-driven phrase + prompt learning)
Calibration tunes *thresholds*; the self-evolving loop tunes the *patterns themselves*,
so detection adapts to each company's language (e.g. team jargon for a blocker).
- `PatternEvolutionService` learns **per-triage**: every triage verdict (resolve / dismiss /
  review-queue "this matters" / "ignore") immediately fires `evolveFromTriage`, anchored on
  the just-triaged thread (root plus replies plus compact metadata such as emoji reactions).
  It asks the LLM to propose the smallest
  correct change — for a review-promotion `matters` verdict a new rule-engine phrase in one
  bucket; for an `ignore`/dismiss verdict a short LLM "skill" guidance note using both the
  main message, replies, and metadata to describe what *not* to surface; for `mark_resolved`,
  resolution guidance from replies/context/emoji reactions and no new root-trigger phrases.
  Example: a root "can you ping oncall?" plus reply "paging now" or a checkmark reaction
  should learn that the handoff/resolution signal resolves the ask, not propose "ping oncall"
  as a new detection trigger. The contract is
  strict JSON with defensive parsing (a parse/LLM
  failure proposes nothing, never crashes). The prompt also includes recent contrasting
  labels for the channel so a single example can't over-fit. There is no batched/cadence
  gate: the system learns within a single click.
- Proposals are stored as `status = proposed` in `learnedPattern` / `learnedGuidance`
  (`channelID` NULL = global, else per-channel). **Human-gated:** phrase proposals are inert
  until approved; guidance proposals are inert until the user appends them into the single
  active AI guidance document in Settings → Learned patterns (the Settings tab badge
  surfaces the pending count). The user can edit that document directly; saves are versioned.
- When an evolution run increases the pending proposal count, post a local macOS
  notification prompting the user to review the update. Coalesce repeated notifications so
  triage does not spam Notification Center.
- Precision safety: learned phrases must be multi-word, ≥4 chars, and not already a base
  phrase (`RuleEngine.isAdmissibleLearnedPhrase`); proposals are capped at 3 per triage. The
  review UI shows an offline precision/false-positive delta (`PrecisionHarness` over the
  channel's labeled messages) before approval. Approve → injected into `RuleEngine`; the
  active guidance document is appended to `LLMClassifier` and the thread summary/resolution
  analyzer next cycle. Retire (or "Revert all") rolls back to base behavior.
- The base rule banks and the base LLM prompt remain fixed in code; only the learned
  overlay (composed at `RuleEngine.init` / appended to the LLM `system` prompt) changes.

### 7.6 Pre-build calibration check (do before trusting the pipeline)
Provide a small offline harness: take ~100 real messages, let 2–3 people label "needs attention," compute inter-rater agreement and pipeline precision against that set. This number is the real precision ceiling. Build this harness early; it gates whether the definition is narrow enough.

### 7.7 Acceptance criteria
- [ ] On a real channel sample, surfaced-item precision ≥80% (or ≥ measured inter-rater ceiling).
- [ ] An answered question auto-closes within one poll cycle and never appears as a missed follow-up.
- [ ] No uncertain item ever appears in Needs attention (only in Review queue).
- [ ] Triaging items measurably shifts subsequent thresholds for that channel.
- [ ] LLM is not called for messages the rules resolve confidently (verify call count).
- [ ] Each triage verdict fires one evolution proposal (verify call count); a missing/pruned message proposes nothing; an approved learned phrase surfaces a previously-missed message; proposed (un-approved) patterns never affect detection.

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
- Watched channels + per-channel sensitivity; staleness threshold; poll interval; summary interval; LLM provider/model + API key (Keychain); manifest variant (with re-onboard path if switching to private).

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
  do not depend on the sandbox: only egress is slack.com + the user's LLM endpoint
  (no-egress test), and secrets live only in the Keychain.
- Used for: (a) ambiguous-message classification (rules escalate only review-band
  candidates → the LLM is never called on rule-resolved messages), (b) thread summaries
  and LLM resolution backstop, (c) daily channel summaries, and (d) learned
  phrase/guidance proposals.
- Strict-JSON contract for classification; defensive parsing (tolerates code fences /
  surrounding prose); parse failure → "uncertain" (→ review queue), never a crash.
- Failures degrade gracefully: rules-only detection still functions; summaries skippable.

---

## 10. Build milestones (suggested commits/PRs)

1. **M0 — Scaffold:** Xcode project, `MenuBarExtra` + window, GRDB setup + migrations, Keychain wrapper. App launches, empty.
2. **M1 — Connection:** manifest variants, onboarding flow, `auth.test`, token in Keychain, channel list. (Phase 1)
3. **M2 — Ingestion:** poller + thread fetch + backfill, local mirror. Verify via DB inspection. (Phase 2)
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
