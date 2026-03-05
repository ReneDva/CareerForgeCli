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

## Manual validations completed
- `/open_tasks` no longer loops or spams; single deterministic response observed.
- `/paths` command now responds correctly after HOME-variable conflict fix.
- `/models` displays picker, and `/model status` returns expected active model output.

## Commits delivered
- `7f30c50` — fix(telegram): stabilize offset parsing and repair /paths handler
- `e1e3e56` — feat(telegram): add /models flow with callback-based model selection

## Known open issue (next focus after Phase C kickoff)
- CV document send path currently fails in some runs with:
  - `A parameter cannot be found that matches parameter name 'Form'.`
- This likely depends on PowerShell runtime differences and should be normalized in Telegram document upload helper.

## Next phase target
- Start **Phase C — FSM Contract Enforcement**:
  1. Centralize all Telegram-triggered transitions through state-machine guards.
  2. Emit clearer user guidance on illegal transitions.
  3. Keep `status_reason`, `last_error`, and timestamps consistent on every path.
