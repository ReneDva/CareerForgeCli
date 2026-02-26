# CareerForge CLI & Automated Job Hunter

CareerForge CLI is a command-line interface and an automated background agent skill designed to streamline your job search. It uses `jobspy` to scrape job postings from major platforms (LinkedIn, Indeed, Glassdoor, ZipRecruiter) and integrates with OpenClaw via Telegram to automate the process of finding jobs and generating tailored resumes.

## 🚀 Key Features

*   **JobSpy CLI Wrapper (`jobspy_cli.py`)**: A command-line tool to quickly scrape job boards and save the results in JSON format.
*   **OpenClaw Job Hunter & CV Generator Skill**: A background agent skill (`jobspy-careerforge-auto`) that continuously monitors for matching jobs and alerts you via Telegram. Reacting with a thumbs up (👍) automatically generates and returns a tailored CareerForge CV using your master profile.

## 🛠 Prerequisites

*   **Python 3.x**
*   **Node.js**: (Version 16 or higher) - Required if you plan to use the CV generation features.
*   **Google Gemini API Key**: Required for the CareerForge CV generator. Get one from [Google AI Studio](https://aistudio.google.com/app/apikey).
*   **Telegram Bot Token**: Required for the OpenClaw Agent Skill.

## 📦 Installation & Setup

1.  **Clone the repository**
    ```bash
    git clone https://github.com/yourusername/CareerForgeCli.git
    cd CareerForgeCli/CareerForgeCli
    ```

2.  **Install Python Dependencies**
    ```bash
    pip install pandas python-jobspy python-dotenv
    # Alternatively, run pip install -r requirements.txt
    ```

3.  **Install Node Dependencies** (for CV generation)
    ```bash
    npm install
    ```

## 📖 User Guide

### 1. Manual Command-Line Scraping (JobSpy CLI)
You can manually run queries for jobs directly using the Python CLI script:
```bash
python jobspy_cli.py --query "Software Engineer" --location "Remote" --hours-old 24 --results 10 --out my_jobs.json
```
Arguments:
*   `--query` / `-q`: The job title or generic search term (e.g. "Data Scientist").
*   `--location` / `-l`: City, State, or "Remote".
*   `--hours-old` / `-H`: How far back to search (in hours).
*   `--results` / `-r`: Number of results to fetch per platform.
*   `--out` / `-o`: Output JSON file to save the data. Prints to terminal if not provided.

### 2. Automation (OpenClaw Telegram Skill)
To set up continuous background monitoring with automated Telegram alerts and CV generation:
1. Load the `jobspy-careerforge-auto` skill into your OpenClaw agent environment.
2. Provide the agent with your `GEMINI_API_KEY` and `TELEGRAM_BOT_TOKEN`.
3. Provide the agent with a path to your master Markdown profile (e.g., `profile.md`).
4. Tell your agent your preferences (e.g., "Find me remote UI/UX roles every 4 hours").
5. The agent runs in the background. When it sends a matching job via Telegram, **react with a 👍**. The agent will automatically use CareerForge to draft your PDF resume and reply with the file.
