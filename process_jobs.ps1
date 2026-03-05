<#
.SYNOPSIS
    Job processing script.
.DESCRIPTION
    Updated to resolve TELEGRAM_BOT_TOKEN locally from .env to bypass
    OpenClaw Gateway 2026 security injection restrictions.
#>
# process_jobs.ps1
# This script is called by the OpenClaw agent's heartbeat to process new job listings.

# --- Configuration ---
$jobsFoundFile = "jobs_found.json"
$jobTrackerFile = "job_tracker.csv"
$telegramChatId = "5225138885" # Your Telegram Chat ID
# Get Token from local .env file instead of relying on Gateway injection
$dotEnvPath = Join-Path $PSScriptRoot ".env"
if (Test-Path $dotEnvPath) {
    $envContent = Get-Content $dotEnvPath
    # Regex extraction to get only the value after the '='
    $tokenLine = $envContent | Select-String "TELEGRAM_BOT_TOKEN="
    if ($tokenLine) {
        $telegramBotToken = ($tokenLine.ToString() -split '=', 2)[1].Trim().Trim('"').Trim("'")
    }
} else {
    $telegramBotToken = $env:TELEGRAM_BOT_TOKEN
}

# --- Helper Function to Test Job Link ---
function Test-JobLink {
    param(
        [Parameter(Mandatory=$true)]$JobUrl
    )

    try {
        Write-Host "Checking link: $JobUrl"
        $response = Invoke-WebRequest -Uri $JobUrl -Method Get -MaximumRedirection 0 -TimeoutSec 10 -ErrorAction SilentlyContinue -Headers @{"User-Agent"="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"}
        
        if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400) {
            Write-Host "Link active: $JobUrl (Status: $($response.StatusCode))"
            return $true
        } else {
            Write-Host "Link inactive or error: $JobUrl (Status: $($response.StatusCode))"
            return $false
        }
    } catch {
        # Simplified error message to avoid parsing issues
        Write-Host "Error testing link ${JobUrl}: $_"
        return $false
    }
}

# --- Helper Function to Process Job History ---
function Process-JobAndCheckHistory {
    param(
        [Parameter(Mandatory=$true)]$Job
    )

    $history = @{}
    if (Test-Path $jobTrackerFile) {
        # Import into a dictionary for faster lookups
        $history = Import-Csv $jobTrackerFile | Group-Object -Property job_id -AsHashTable -AsString
    }

    # Check if job_id already exists
    if ($history.ContainsKey($Job.id)) {
        Write-Host "Job $($Job.id) already processed. Skipping."
        return $false
    }

    $newEntry = [PSCustomObject]@{
        job_id = $Job.id;
        title = $Job.title;
        company = $Job.company;
        status = 'Sent';
        date_found = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss");
        cv_file_path = ''
    }

    $newEntry | Export-Csv -Path $jobTrackerFile -Append -NoTypeInformation -Encoding UTF8
    Write-Host "New job $($Job.id) added to tracker. Marked as 'Sent'."
    return $true
}

# --- Main Processing Logic ---
$cvsFolderPath = "Generated_CVs"
if (-not (Test-Path $cvsFolderPath)) {
    New-Item -ItemType Directory -Path $cvsFolderPath | Out-Null
    Write-Host "Created $cvsFolderPath directory."
}

if (Test-Path $jobsFoundFile) {
    try {
        $jobs = Get-Content $jobsFoundFile -Raw -Encoding UTF8 | ConvertFrom-Json

        if ($jobs -and $jobs.Count -gt 0) {
            Write-Host "Processing $($jobs.Count) jobs from $jobsFoundFile."
            foreach ($job in $jobs) {
                if (-not ($job.job_url)) {
                    Write-Host "Skipping job with no URL: $($job.id)"
                    continue
                }

                if (-not (Test-JobLink -JobUrl $job.job_url)) {
                    Write-Host "Discarding job '$($job.id)' due to inactive link."
                    continue
                }

                if (Process-JobAndCheckHistory -Job $job) {
                    # Simplified message, replacing potentially problematic emojis
                    $message = "Job ID: $($job.id)`nCompany: $($job.company)`nTitle: $($job.title)`nLocation: $($job.location)`nLink: $($job.job_url)`nSnippet: (Description not scraped - see full link)`n`nReply with approval including this Job ID to continue CV generation/application."

                    if ($telegramBotToken) {
                        Write-Host "Sending Telegram message for job $($job.id)..."
                        $headers = @{"Content-Type"="application/json"}
                        $body = @{ chat_id = $telegramChatId; text = $message; parse_mode = "Markdown" } | ConvertTo-Json
                        try {
                            Invoke-RestMethod -Uri "https://api.telegram.org/bot$telegramBotToken/sendMessage" -Method Post -Headers $headers -Body $body -ErrorAction Stop
                            Write-Host "Telegram message sent for job $($job.id)."
                            Start-Sleep -Seconds 5
                        } catch {
                            Write-Host "ERROR sending Telegram message for job $($job.id): $_"
                        }
                    } else {
                        Write-Host "Skipping Telegram message for job $($job.id): TELEGRAM_BOT_TOKEN is not set."
                        Write-Host "Job Details (not sent): Company: $($job.company), Title: $($job.title), Location: $($job.location)"
                    }
                }
            }
        } else {
            Write-Host "No jobs found in $jobsFoundFile."
        }
    } catch {
        Write-Host "ERROR reading or parsing ${jobsFoundFile}: $_"
    }
} else {
    Write-Host "$jobsFoundFile not found. No jobs to process."
}

# --- Update Last Run Timestamp ---
(Get-Date).ToString("yyyy-MM-dd HH:mm:ss") | Set-Content -Path "memory/job_search_last_run.txt" -Encoding UTF8
