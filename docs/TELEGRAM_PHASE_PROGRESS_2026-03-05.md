# Telegram Integration Progress (2026-03-05)

## Completed milestones

### Phase A — Telegram Intake Stability ✅
- Added startup webhook guard to prevent polling/webhook conflicts.
- Enforced deterministic `allowed_updates` set for polling.
- Added quick callback acknowledgement path to avoid Telegram client spinner hangs.
- Stabilized update offset handling:
  - trim raw offset value before numeric parse
  - save offset without trailing newline
- Fixed command scope override behavior so command menu is stable.

### Phase B — Model Selection Reliability ✅
- Added `/models` command with inline keyboard model picker.
- Added callback routing for model selection and model-status actions.
- Added `/model status` and `/model <value>` command fallback parsing.
- Implemented per-chat active model persistence in local runtime state.
- Added user-facing model status output including fallback chain.

### Phase C — FSM Guard & Runtime Reliability ✅
- Centralized Telegram-triggered status transitions through a guarded helper.
- Added user-friendly guidance for invalid transitions and business-guard violations.
- Fixed reaction handler crash on unmapped messages (`MapRow` nullable flow).
- Ensured single-listener stability after repeated live troubleshooting (409 conflict cleanup).
- Fixed command latency under load by moving CV generation into an async worker process.

## Manual validations completed
- `/open_tasks` no longer loops or spams; single deterministic response observed.
- `/paths` command now responds correctly after HOME-variable conflict fix.
- `/models` displays picker, and `/model status` returns expected active model output.
- Reaction-driven CV flow responds and no longer blocks command handling during generation.

## Commits delivered
- `7f30c50` — fix(telegram): stabilize offset parsing and repair /paths handler
- `e1e3e56` — feat(telegram): add /models flow with callback-based model selection
- `37a5f14` — docs(telegram): checkpoint progress and validated milestones
- `9c24cf3` — feat(fsm): centralize Telegram transitions with user-friendly guard errors
- `4d02aba` — fix(telegram): handle unmapped reactions without null-binding crash
- `39f56c0` — fix(telegram): make CV generation async to keep commands responsive

## Issues encountered and how they were solved

1. **`/open_tasks` menu/response instability**
  - **Root cause:** command scope precedence and duplicate listener behavior.
  - **Fix:** cleaned chat-scope override; kept merged default/private command registration.

2. **Repeated `/open_tasks` messages (loop-like behavior)**
  - **Root cause:** offset parsing edge case and newline persistence.
  - **Fix:** trim offset before numeric parse; save offset with `-NoNewline`.

3. **`/paths` command failed**
  - **Root cause:** PowerShell variable name collision (`$home` vs read-only `$HOME`).
  - **Fix:** renamed to `$userHomeDir`.

4. **Reaction sometimes produced no response**
  - **Root cause:** concurrent listeners causing Telegram 409 conflicts + null binding on unmapped message row.
  - **Fix:** enforced single running listener in ops flow and made mapped-row check null-safe.

5. **Commands delayed during CV generation (`/open_tasks`, `/model`)**
  - **Root cause:** synchronous CV generation blocking polling loop.
  - **Fix:** introduced async worker (`scripts/telegram_cv_generation_worker.ps1`) and launched generation in background.

6. **`CV generation failed` after reaction despite working Telegram flow**
  - **Root cause:** CV generation runtime/agent was not active or unavailable at execution time.
  - **Fix:** reclassified as runtime prerequisite issue (not Telegram send path). Documentation and plan updated to require generator runtime preflight before reaction-driven generation tests.

## Known open issue (current)
- CV generation requires active generation runtime/agent context.
- If generator runtime is unavailable, reaction flow correctly reaches:
  - `⚠️ CV generation failed for <job_id>. Check logs for details.`
- Next focus: add explicit preflight runtime check and user-facing guidance before generation starts.

## Next phase target
- Start **Phase D — Apply Adapter (manual_assist)** after CV generation failure is stabilized:
  1. Add manual_assist apply adapter entrypoint.
  2. Map apply outcomes deterministically to `Applied` / `Apply_Failed`.
  3. Keep full status+error traceability in tracker fields.
