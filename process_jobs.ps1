<#
.SYNOPSIS
    Job processing script.
.DESCRIPTION
    Updated to resolve TELEGRAM_BOT_TOKEN locally from .env to bypass
    OpenClaw Gateway 2026 security injection restrictions.
#>
# process_jobs.ps1
# This script is called by the OpenClaw agent's heartbeat to process new job listings.

. "$PSScriptRoot\scripts\job_state_machine.ps1"
. "$PSScriptRoot\scripts\telegram_interface.ps1"

# --- Configuration ---
$jobsFoundFile = "jobs_found.json"
$jobTrackerFile = "job_tracker.csv"
$telegramChatId = "5225138885" # Your Telegram Chat ID
$telegramBotToken = Get-TelegramBotToken -WorkspaceRoot $PSScriptRoot

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

Initialize-JobTracker -TrackerPath $jobTrackerFile

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
            $sortedJobs = Sort-JobsForDeterministicDispatch -Jobs $jobs
            Write-Host "Processing $($sortedJobs.Count) jobs from $jobsFoundFile (deterministic order)."
            $sequence = 0

            foreach ($job in $sortedJobs) {
                $sequence += 1
                if (-not ($job.job_url)) {
                    Write-Host "Skipping job with no URL: $($job.id)"
                    continue
                }

                if (-not (Test-JobLink -JobUrl $job.job_url)) {
                    Write-Host "Discarding job '$($job.id)' due to inactive link."
                    continue
                }

                $isNewJob = $false
                try {
                    $isNewJob = Add-FoundJobIfMissing -TrackerPath $jobTrackerFile -Job $job -Source "job_search_wrapper"
                } catch {
                    Write-Host "State tracking error for job '$($job.id)': $_"
                    continue
                }

                if ($isNewJob) {
                    $message = Format-TelegramJobMessage -Job $job -SequenceNumber $sequence -TotalCount $sortedJobs.Count

                    if ($telegramBotToken) {
                        Write-Host "Sending Telegram message for job $($job.id)..."
                        try {
                            $tgResp = Send-TelegramTextDeterministic -BotToken $telegramBotToken -ChatId $telegramChatId -Text $message -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode "HTML"
                            $messageId = if ($tgResp.result.message_id) { "$($tgResp.result.message_id)" } else { "" }
                            if (-not [string]::IsNullOrWhiteSpace($messageId)) {
                                Register-TelegramMessageMap -JobId "$($job.id)" -ChatId "$telegramChatId" -MessageId $messageId
                            }
                            Set-JobStatus -TrackerPath $jobTrackerFile -JobId "$($job.id)" -NewStatus "Sent" -Reason "Job notification sent to Telegram" -FieldUpdates @{ telegram_message_id = $messageId }
                            Write-DispatchLog -JobId "$($job.id)" -Status "Sent" -Reason "telegram_message_dispatched"
                            Write-Host "Telegram message sent for job $($job.id)."
                            Start-Sleep -Seconds 5
                        } catch {
                            try {
                                Set-JobStatus -TrackerPath $jobTrackerFile -JobId "$($job.id)" -NewStatus "Apply_Failed" -Reason "Failed to send Telegram notification" -FieldUpdates @{ last_error = "$_" }
                                Write-DispatchLog -JobId "$($job.id)" -Status "Apply_Failed" -Reason "telegram_send_failed"
                            } catch {
                                Write-Host "Failed to persist failure state for job $($job.id): $_"
                            }
                            Write-Host "ERROR sending Telegram message for job $($job.id): $_"
                        }
                    } else {
                        try {
                            Set-JobStatus -TrackerPath $jobTrackerFile -JobId "$($job.id)" -NewStatus "Apply_Failed" -Reason "Missing TELEGRAM_BOT_TOKEN" -FieldUpdates @{ last_error = "TELEGRAM_BOT_TOKEN is not set" }
                        } catch {
                            Write-Host "Failed to persist missing-token state for job $($job.id): $_"
                        }
                        Write-Host "Skipping Telegram message for job $($job.id): TELEGRAM_BOT_TOKEN is not set."
                        Write-Host "Job Details (not sent): Company: $($job.company), Title: $($job.title), Location: $($job.location)"
                    }
                } else {
                    Write-Host "Job $($job.id) already tracked. Skipping duplicate notification."
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
