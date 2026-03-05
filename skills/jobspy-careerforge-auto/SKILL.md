
---
name: jobspy-careerforge-auto
description: Auto-Search Jobs, Generate CVs, and Human-like Auto-Apply via Telegram
# Requirements managed via OpenClaw Gateway environment

---

# OpenClaw Job Hunter, CV Generator & Auto-Apply Skill (v2026.03.05.FINAL)

This skill teaches the agent how to monitor jobs, generate tailored PDFs, and perform human-like applications using the CareerForge CLI and OpenClaw browser tools.

> [!WARNING] Security Boundaries
> - **Never** expose API keys or tokens in logs.
> - All file operations must stay within the workspace.
> - Execution of `apply` command requires explicit user confirmation of the generated PDF.

## Setup & Configuration

1. **User Preferences**: Ask for target role, location, and search interval.
2. **Profile Path**: Ensure `profile.md` exists in the workspace.
3. **Identity Check**: Read `IDENTITY.md` and `SOUL.md` to align with the user's persona.

## 1. The Search Schedule (Cron)

Configure a recurring background task:
- **Execute**: `./venv/Scripts/python.exe jobspy_cli.py --query "<ROLE>" --location "<LOCATION>" --hours-old <INTERVAL_HOURS> --results 5 --out jobs.json`
- **Deduplication**: Reference `job_tracker.csv` before alerting the user about jobs in `jobs.json`.
- **Message Dispatch**: For each relevant job, send a **SEPARATE** Telegram message:

```text
🏢 **Company**: <company>
💼 **Title**: <title>
📍 **Location**: <location>
🔗 **Link**: <job_url>

*React with 👍 to generate CV | React with 🚀 to Generate & Apply*

```

## 2. Step A: Generate & Verify CV (Reaction: 👍)

When the user reacts with 👍 or 🚀:

1. **Prepare**: Save job description to `current_job_desc.txt`.
2. **Execute CLI Generate**:

```bash
# Internal Documentation: Initial PDF named by company for internal archive
node dist/cli.js generate --profile profile.md --job current_job_desc.txt --out resumes/resume_<company>.pdf --theme modern

```

3. **Action (Review)**: Upload the generated PDF `resumes/resume_<company>.pdf` to the Telegram chat.
4. **Message**: "✅ כאן קורות החיים המותאמים שיצרתי עבור **<company>**. המערכת תגיש אותם תחת השם **Rene_Dvash.pdf**. האם לאשר הגשה אוטומטית? (הגיבי 'אשר' או לחצי 🚀)"
5. **Hard Stop**: Wait for explicit user confirmation.
6. **Cleanup**: Delete `current_job_desc.txt` immediately after generation.

## 3. Step B: Human-like Application (Reaction: 🚀 or Approval)

When approval is received:

1. **Browser Preparation**:
* Verify: `openclaw browser status`.
* Use profile: `chrome` (Extension Relay).


2. **File Branding Logic**:
* Create a copy of `resumes/resume_<company>.pdf` named `Rene_Dvash.pdf` in the workspace root for the recruiter's view.


3. **Stealth Execution**:
* **Scroll/Hover**: Move through page and hover over "Apply" for 1.5s-2s.
* **Jitter Click**: Non-centered click simulation.


4. **Execute CLI Apply**:

```bash
# Internal Documentation: Use the branded Rene_Dvash.pdf for submission
node dist/cli.js apply --file Rene_Dvash.pdf --url "<JOB_URL>"

```

5. **Confirmation & Human-in-the-Loop**:
* Notify: "🌐 הדפדפן פתוח בנקודת ההגשה. בדקי שהכל תקין ולחצי על Submit, או שאני אמשיך אם תתני לי אישור."
* Take screenshot: `openclaw browser screenshot` and send to Telegram.


6. **Final Cleanup**:
* Delete `Rene_Dvash.pdf` after submission.
* Keep the original PDF in `resumes/` for records.
* Move legacy `.md` files to `memory/`.



---

## 📝 תיעוד פנימי (English Documentation)

```typescript
/**
 * 2026.03.05 COMPREHENSIVE UPDATE:
 * 1. BRANDING: Renamed submission file to 'Rene_Dvash.pdf' to ensure professional presentation to recruiters.
 * 2. SEPARATION: Forced atomic messaging (one job per message) to prevent reaction confusion.
 * 3. SYNC GATE: Implemented mandatory PDF review stage before browser interaction.
 * 4. WORKSPACE HYGIENE: Automated deletion of 'current_job_desc.txt' and redirection of md files to 'memory/'.
 */

```
