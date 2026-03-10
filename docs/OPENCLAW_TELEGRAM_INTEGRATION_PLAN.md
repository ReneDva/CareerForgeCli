# OpenClaw + Telegram Integration Plan (CareerForge)

_Last updated: 2026-03-06_

## 1) Goal

Build a reliable, low-noise, state-machine-driven Telegram control surface for CareerForge, while integrating OpenClaw as the execution layer for semi-automated apply flows.

## 2) Design Principles

- Human-in-the-loop first: no apply without explicit user approval.
- Deterministic behavior: same input => same dispatch/order/outcome.
- Telegram UI is transport, state machine is source of truth.
- OpenClaw handles browser workflow orchestration, not business rules.
- Auditability: each action must be traceable by `job_id` + `trace_id`.

## 3) Scope Boundaries

### BotFather responsibilities (configuration only)
- bot profile settings
- command list defaults
- privacy/inline/group toggles

### Code responsibilities (runtime logic)
- command authorization & routing
- inline keyboard flows (`/models`, `/model` selection)
- callback/reaction handling
- state transitions & transition guards
- retries, fallback model policy, and anti-spam behavior

## 4) Target Runtime Contract (Telegram -> Controller -> OpenClaw)

All inbound events normalized into:

```json
{
  "trace_id": "uuid",
  "event_type": "message|callback_query|reaction",
  "chat_id": "string",
  "user_id": "string",
  "message_id": "string|null",
  "job_id": "string|null",
  "command": "string|null",
  "payload": {},
  "received_at": "iso8601"
}
```

Controller returns:

```json
{
  "action": "send_message|update_status|generate_cv|openclaw_apply|ignore",
  "reason": "string",
  "next_state": "Found|Sent|CV_Generating|CV_Ready_For_Review|CV_Revision_Requested|Approved_For_Apply|Applied|Apply_Failed|Rejected_By_User|null",
  "side_effects": []
}
```

## 5) Phased Plan

## Phase A — Stabilize Telegram Intake

### Tasks
1. Enforce one update mode (polling in local): no webhook/polling conflicts.
2. Restrict `allowed_updates` for listener to minimal required set:
   - `message`
   - `callback_query`
   - `message_reaction`
   - `my_chat_member`
3. Ensure callback UX rule: always call answer-callback equivalent quickly.
4. Keep stale-update suppression and offset progression deterministic.
5. Add generator-runtime preflight check before starting CV generation jobs.
6. Validate generation prerequisites at runtime:
   - `profile.md` exists and is readable.
   - `profile.md` is treated as the generic baseline CV source in **Markdown** (not PDF).
   - `node` runtime + `dist/cli.js` are available.
   - required env vars exist (`GEMINI_API_KEY`, `TELEGRAM_BOT_TOKEN`).
7. Replace global `current_job_desc.txt` with job-scoped temp path (e.g. `temp/<job_id>/job_desc.txt`) to avoid parallel-run collisions.
8. Tune strict CV factual guardrails to validate immutable core facts only (identity/contact + education core facts), not all descriptive bullets.
9. Implement one-page control loop in generation runtime:
   - section output budgets in prompts,
   - runtime A4 page estimator,
   - conditional compaction pass with bounded retries before strict failure.

### Files
- `scripts/telegram_reaction_listener.ps1`
- `scripts/telegram_interface.ps1`
- `memory/telegram_update_offset.txt`

### Exit Criteria
- No duplicate processing after restart.
- No 409 polling conflicts.
- Callback spinner does not hang.

---

## Phase B — Model Selection Reliability

### Tasks
1. Keep static command menu via BotFather/API only.
2. Runtime inline keyboards drive model/provider selection.
3. Persist active model/provider state per user/chat.
4. Wire selected model into CV generation runtime (selection must affect `generate`, not just UI state).
4. Add deterministic fallback chain on overload:
   1) `google/gemini-3-pro-preview`
   2) `google/gemini-2.5-pro`
   3) `google/gemini-2.0-flash`
5. Send explicit fallback notification once per request.

### Files
- `scripts/telegram_reaction_listener.ps1`
- `scripts/telegram_interface.ps1`
- optional state file under `memory/`

### Exit Criteria
- `/models` + selection works in one flow.
- selected model is actually used by the generation pipeline.
- overload => fallback => successful response or terminal error with clear reason.

---

## Phase C — FSM Contract Enforcement

### Tasks
1. Route all Telegram-triggered actions through state machine guards.
2. Reject illegal transitions with user-friendly guidance.
3. Track `status_reason`, `last_error`, `updated_at` on every transition.
4. Validate no path reaches `Applied` without `Approved_For_Apply`.

### Files
- `scripts/job_state_machine.ps1`
- `scripts/telegram_reaction_listener.ps1`
- `job_tracker.csv` schema handling logic

### Exit Criteria
- Transition tests pass.
- No illegal transition observed in logs.

---

## Phase D — OpenClaw Apply Adapter (Start with manual_assist)

### Tasks
1. Add adapter function for OpenClaw invocation using `job_id` + `submitted_cv_path`.
2. Default mode for LinkedIn: `manual_assist`.
3. Capture OpenClaw result codes and map to:
   - `Applied`
   - `Apply_Failed`
4. Add minimal retry only where safe (navigation/transient), not on final submit.

### Files
- `process_jobs.ps1`
- `src/cli.ts` (mode split `manual_assist` / `auto_apply`)
- OpenClaw invocation layer/scripts

### Exit Criteria
- one full apply assist flow completes with audit trail.

---

## Phase E — Observability & Noise Controls

### Tasks
1. Standard structured logs include `trace_id`, `job_id`, `state_before`, `state_after`.
2. Keep and extend dedupe rules for invalid reactions/messages.
3. Add quick health command output (`/status`) with:
   - listener alive
   - queue depth
   - active model/provider

### Files
- `memory/telegram_dispatch.log`
- `memory/telegram_message_map.csv`
- `memory/telegram_invalid_notice_log.csv`
- `scripts/telegram_reaction_listener.ps1`

### Exit Criteria
- Can reconstruct a full event path for any `job_id`.

## 6) Testing Strategy

## Unit / parser checks
- PowerShell parse check on changed scripts.

## Integration checks
1. Send test messages (`scripts/telegram_send_test_messages.ps1`).
2. Start listener.
3. Verify CV generation runtime/agent is active before reaction tests.
4. Verify `profile.md` is present and valid as the generic Markdown resume source.
4. Run commands:
   - `/models`
   - `/model status`
   - `/open_tasks`
   - `/paths`
5. React 👍 to mapped job message.
6. Verify:
   - status progression to `CV_Ready_For_Review`
   - PDF returned to Telegram
   - logs and map files updated
   - strict validation blocks changed factual entities (education/institution/years, injected residence/city), but does not fail on legitimate professional bullet rewriting.
   - strict one-page mode retries compaction first and fails only if final rendered output still exceeds one A4 page.

## Runtime prerequisite note
- CV generation success depends on active generation runtime/agent context.
- `profile.md` is the canonical generic CV source (Markdown), while generated outputs are PDF artifacts per job/version.
- If runtime is unavailable, controller should fail fast with a clear user message and retain deterministic status updates.

## E2E (OpenClaw)
- Approved CV -> OpenClaw manual_assist -> final status + archived artifacts.

## 7) Risk Register

- Polling/webhook conflict -> enforce one mode + startup guard.
- Telegram command scope override -> merge strategy across scopes.
- Backlog noise on restart -> stale window + offset persistence.
- Overload spam -> one notification per context + fallback once.
- State drift -> centralize transitions in FSM only.

## 8) First Execution Slice (immediately after snapshot push)

1. Implement startup guard in listener:
   - detect active webhook and fail fast with remediation text.
2. Enforce explicit `allowed_updates` list on poll requests.
3. Add/update structured startup log line including mode and allowed updates.
4. Run parser validation + one dry run.

---

This plan is intentionally execution-oriented and mapped to current repository structure.

---

## 9) Change Rationale + Ready Fallback Options (Telegram Search Control)

### Why this change

נדרש להוסיף שליטה מלאה מהטלגרם על ריצות חיפוש משרות כדי לצמצם תלות בהפעלה ידנית ולשפר עקביות תפעולית:

1. הפעלה מיידית מהצ'אט (`/search_start`) ללא כניסה לטרמינל.
2. אוטומציה מתוזמנת (`/search_timer`) כל X שעות/ימים.
3. עצירה נקייה של אוטומציה (`/search_stop`).
4. שינוי פרמטרים תפעוליים של מנוע החיפוש מהטלגרם (`/search_config`, `/search_set`).

השינוי מיישר קו עם עקרונות המערכת: Human-in-the-loop, determinism, auditability, ו-reliability over magic.

### Primary solution

- Listener יחזיק scheduler state מקומי בקובץ `memory/telegram_search_scheduler.json`.
- פקודות Telegram יפעילו:
  - הרצת חיפוש מיידית,
  - תזמון אוטומטי,
  - עצירת תזמון,
  - עדכון קונפיג עם allowlist key validation.

### Alternative fallback solutions (if primary approach fails)

1. **Windows Task Scheduler fallback**
   - ליצור משימה מערכתית חיצונית במקום scheduler בתוך listener.
   - יתרון: יציבות גבוהה לאורך זמן/ריסטארטים.
   - חסרון: מורכבות תפעול והרשאות.

2. **External cron/service wrapper**
   - תזמון מחוץ ל-listener (service נפרד).
   - יתרון: הפרדת אחריות טובה יותר.
   - חסרון: עוד רכיב לתחזק.

3. **Config staging mode**
   - `search_set` כותב ל-pending config ורק `/search_apply` מחיל בפועל.
   - יתרון: מניעת טעויות תפעול בזמן אמת.
   - חסרון: צעד נוסף למשתמש.

4. **Safe mode (no live config writes)**
   - פקודות טלגרם מציגות קונפיג והמלצות בלבד; שינוי בפועל רק מקומית.
   - יתרון: סיכון מינימלי.
   - חסרון: פחות אוטומציה.

### Rollback plan

- אם יש תקלה בפקודות החדשות:
  1. להשבית את הפקודות מה-menu merge.
  2. להשאיר `search` ידני בלבד.
  3. להשתמש ב-runbook טרמינלי (`job_search_wrapper.ps1` + `process_jobs.ps1`) עד תיקון.

---

## 10) Current Snapshot (2026-03-10)

- Commands sync is now config-driven and safely merged (no blind overwrite).
- Pre-change backups are written under `memory/telegram_command_backups/`.
- Dual search commands are registered: `search_agent` and `search_cli`.
- Interactive search config editor is available (`/search_config`, `/search_set`, callbacks + pending state).
- CLI pipeline now emits per-job outcome notifications (including skip reasons) during search processing.
- Known runtime behavior: if multiple Telegram pollers run concurrently, one consumer may receive commands unexpectedly (`409 getUpdates conflict`).

## 11) Agent/CLI Mode Switch Plan (in progress)

### Objective
Allow explicit operational switching between:
- **CLI mode**: `/search` aliases run direct CLI automation (`job_search_wrapper.ps1` + `process_jobs.ps1`) with per-job notifications.
- **Agent mode**: `/search` aliases route to agent-guided behavior messaging, with explicit `/search_agent` flow.

### Implemented in code
- Added `careerforge.telegram.runtimeMode` config (default: `cli`).
- Added Telegram commands:
   - `/mode_status`
   - `/mode_cli`
   - `/mode_agent`
- Added alias routing logic:
   - in `cli` mode, `/search` + `/search_start` execute CLI pipeline.
   - in `agent` mode, `/search` + `/search_start` return agent-mode guidance and require `/search_agent`.

### Remaining operational step
- Stabilize single Telegram consumer during runtime (avoid concurrent OpenClaw poller + local listener).
