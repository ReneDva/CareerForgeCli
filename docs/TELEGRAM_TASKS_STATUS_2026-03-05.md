# Telegram Tasks Status (2026-03-05)

## Completed tasks
- [x] Preflight sanity checks
- [x] Send fresh Telegram test jobs
- [x] Start listener for live test
- [x] Validate commands and reactions
- [x] Collect logs and conclude
- [x] Fix command scope override
- [x] Fix offset loop spam
- [x] Diagnose open_tasks delay
- [x] Fix paths command failure
- [x] Implement models callback routing
- [x] Add model command fallback
- [x] Run Telegram command smoke tests
- [x] Implement Phase C FSM guard layer
- [x] Debug reaction no-response issue
- [x] Fix command delay during generation (async worker)

## Added tasks (newly tracked)
- [x] Document successes checkpoint
- [x] Fix CV generation no-response crash path (null map-row handling)
- [ ] Fix CV generation failure (Telegram document send/runtime compatibility)

## Open tasks
- [ ] Implement Phase D apply adapter
- [ ] Add manual_assist apply mode
- [ ] Map apply outcomes to FSM

## Notes
- Runtime-generated files (`job_tracker.csv`, `memory/*.csv`, `memory/telegram_update_offset.txt`) are intentionally excluded from code-fix commits.
- CV generation is now asynchronous to keep `/open_tasks` and `/model` responsive during long-running generation.
