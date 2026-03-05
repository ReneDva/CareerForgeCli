
# JOB SEARCH AUTOMATION

## Config
- **Interval**: 4 hours
- **Search Script**: `powershell -File job_search_wrapper.ps1`
- **Processing Script**: `powershell -File process_jobs.ps1`
- **Last Run File**: `memory/job_search_last_run.txt`

## Instructions
1. Read the last run timestamp from `memory/job_search_last_run.txt`.
2. If > 4 hours ago (or `memory/job_search_last_run.txt` is missing):
   a. Execute the **Search Script** (`job_search_wrapper.ps1`) to find new jobs.
   b. Execute the **Processing Script** (`process_jobs.ps1`) to filter, track, and notify about new jobs.
   c. The `process_jobs.ps1` script will handle updating `memory/job_search_last_run.txt` internally.
3. If < 4 hours, do nothing (HEARTBEAT_OK).

## Agent Reaction Handling (Internal)
- When the user reacts with 👍 to a job message or explicitly approves for application, update the status for that `job_id` in `job_tracker.csv` to 'Applied'. This logic will be handled directly by the agent upon receiving the reaction.
