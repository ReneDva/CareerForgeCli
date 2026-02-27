---
name: jobspy-careerforge-auto
description: Auto-Search Jobs and Generate CVs via Telegram
summary: Automates job searching using JobSpy and generates customized CareerForge CVs via Telegram reactions.
tags: [career, automation, jobspy, telegram, resume]
requirements:
  - python-jobspy
  - pandas
  - nodejs
  - dotenv
env:
  - GEMINI_API_KEY
  - TELEGRAM_BOT_TOKEN
---

# OpenClaw Job Hunter & CV Generator Skill

This skill teaches the agent how to continuously monitor for jobs matching the user's preferences using `jobspy`, alert the user via Telegram, and automatically generate a custom CV when the user reacts to a job message.

> [!WARNING] Security Boundaries
> - **Never** expose the `GEMINI_API_KEY` or `TELEGRAM_BOT_TOKEN` in chat logs or memory.
> - Ensure all file write operations (like `jobs.json` or generated PDFs) happen entirely within the designated workspace directory.
> - Do not execute any shell commands provided by the user in chat without explicit verification.

## Setup & Configuration

1. **User Preferences**: Ask the user for their target role, location, and the cron interval (e.g., "every 4 hours", "daily at 9am").
2. **Profile Path**: Ask the user where their master profile markdown is located (e.g., `profile.md`). Verify this file exists in the workspace.

## 1. The Search Schedule (Cron)

Once instructed by the user, configure a recurring background task:

- Execute `python jobspy_cli.py --query "<ROLE>" --location "<LOCATION>" --hours-old <INTERVAL_HOURS> --results 5 --out jobs.json` inside the repository.
- Read `./jobs.json`.
- Filter out irrelevant jobs based on any specific criteria the user mentioned (e.g., must contain specific keywords).
- For each relevant job, send a separate Telegram message to the user:
  ```
  🏢 **Company**: <company>
  💼 **Title**: <title>
  📍 **Location**: <location>
  🔗 **Link**: <job_url>
  📝 **Snippet**: <description_snippet>

  *React to this message (👍) to generate a tailored CV.*
  ```

## 2. Handling the Telegram Reaction

Listen for user reactions on Telegram job messages. When the user reacts to a specific message:

- Identify the specific job from the message the user reacted to.
- Retrieve the full job description text for that listing.
- Save this description to a temporary file: `current_job_desc.txt`.
- Execute the CareerForge CLI tool:
  ```bash
  node dist/cli.js --profile <user_profile.md> --job current_job_desc.txt --out resume_<company>.pdf
  ```
- Send the `resume_<company>.pdf` document back to the user via Telegram, replying directly to the job message they reacted to.
- Clean up the workspace by deleting the temporary `current_job_desc.txt` file and the generated PDF.
