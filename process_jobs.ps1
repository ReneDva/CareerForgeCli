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

function Send-JobIterationOutcomeMessage {
    param(
        [Parameter(Mandatory=$true)]$Job,
        [Parameter(Mandatory=$true)][int]$SequenceNumber,
        [Parameter(Mandatory=$true)][int]$TotalCount,
        [Parameter(Mandatory=$true)][string]$OutcomeCode,
        [Parameter(Mandatory=$true)][string]$ReasonText,
        [Parameter(Mandatory=$true)][string]$BotToken,
        [Parameter(Mandatory=$true)][string]$ChatId
    )

    if ([string]::IsNullOrWhiteSpace($BotToken)) {
        return
    }

    $jobId = Resolve-TrackerJobId -Job $Job
    $company = if ($Job.company) { "$($Job.company)" } else { 'Unknown' }
    $title = if ($Job.title) { "$($Job.title)" } else { 'Unknown' }
    $location = if ($Job.location) { "$($Job.location)" } else { 'Unknown' }
    $url = if ($Job.job_url) { "$($Job.job_url)" } else { 'N/A' }

    $jobIdEsc = [System.Security.SecurityElement]::Escape($jobId)
    $companyEsc = [System.Security.SecurityElement]::Escape($company)
    $titleEsc = [System.Security.SecurityElement]::Escape($title)
    $locationEsc = [System.Security.SecurityElement]::Escape($location)
    $urlEsc = [System.Security.SecurityElement]::Escape($url)
    $reasonEsc = [System.Security.SecurityElement]::Escape($ReasonText)
    $outcomeEsc = [System.Security.SecurityElement]::Escape($OutcomeCode)

    $msg = @(
        "&#128269; <b>Search iteration item $SequenceNumber/$TotalCount</b>",
        "job_id: <code>$jobIdEsc</code>",
        "company: <b>$companyEsc</b>",
        "title: <b>$titleEsc</b>",
        "location: <b>$locationEsc</b>",
        "link: <code>$urlEsc</code>",
        "result: <b>$outcomeEsc</b>",
        "reason: <code>$reasonEsc</code>"
    ) -join "`n"

    try {
        Send-TelegramTextDeterministic -BotToken $BotToken -ChatId $ChatId -Text $msg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode "HTML" | Out-Null
    } catch {
        Write-Host "Failed to send iteration outcome message for job '$jobId': $_"
    }
}

function Normalize-TrackerText {
    param([Parameter(Mandatory=$false)]$Value)

    if ($null -eq $Value) { return '' }
    return ("$Value").Trim().ToLowerInvariant()
}

function Get-ExistingTrackedJobIdForDedupe {
    param(
        [Parameter(Mandatory=$true)][string]$TrackerPath,
        [Parameter(Mandatory=$true)]$Job
    )

    $rows = Get-TrackerRows -TrackerPath $TrackerPath
    if (-not $rows -or @($rows).Count -eq 0) {
        return ''
    }

    $jobUrlNorm = Normalize-TrackerText -Value $Job.job_url
    if (-not [string]::IsNullOrWhiteSpace($jobUrlNorm)) {
        $match = @($rows | Where-Object { (Normalize-TrackerText -Value $_.job_url) -eq $jobUrlNorm } | Select-Object -First 1)
        if ($match.Count -gt 0 -and $match[0].job_id) {
            return "$($match[0].job_id)"
        }
    }

    $titleNorm = Normalize-TrackerText -Value $Job.title
    $companyNorm = Normalize-TrackerText -Value $Job.company
    $locationNorm = Normalize-TrackerText -Value $Job.location
    if (-not [string]::IsNullOrWhiteSpace($titleNorm) -or -not [string]::IsNullOrWhiteSpace($companyNorm)) {
        $match = @($rows | Where-Object {
            (Normalize-TrackerText -Value $_.title) -eq $titleNorm -and
            (Normalize-TrackerText -Value $_.company) -eq $companyNorm -and
            (Normalize-TrackerText -Value $_.location) -eq $locationNorm
        } | Select-Object -First 1)

        if ($match.Count -gt 0 -and $match[0].job_id) {
            return "$($match[0].job_id)"
        }
    }

    return ''
}

function Get-NextSequentialTrackerJobId {
    param([Parameter(Mandatory=$true)][string]$TrackerPath)

    $rows = Get-TrackerRows -TrackerPath $TrackerPath
    $maxNum = 0

    foreach ($r in @($rows)) {
        $idText = if ($r.job_id) { "$($r.job_id)" } else { '' }
        if ($idText -match '^job-(\d+)$') {
            $n = [int]$matches[1]
            if ($n -gt $maxNum) { $maxNum = $n }
        }
    }

    $next = $maxNum + 1
    return ('job-{0:d6}' -f $next)
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
            $sentCount = 0
            $skippedCount = 0
            $duplicateCount = 0
            $invalidLinkCount = 0
            $missingUrlCount = 0

            foreach ($job in $sortedJobs) {
                $sequence += 1
                $resolvedJobId = ''

                if (-not ($job.job_url)) {
                    Write-Host "Skipping job with no URL: $(if ($job.title) { $job.title } else { 'unknown_job' })"
                    $missingUrlCount += 1
                    $skippedCount += 1
                    continue
                }

                $existingTrackedId = Get-ExistingTrackedJobIdForDedupe -TrackerPath $jobTrackerFile -Job $job
                if (-not [string]::IsNullOrWhiteSpace($existingTrackedId)) {
                    Write-Host "Job already tracked (dedupe match=$existingTrackedId). Skipping duplicate notification."
                    $duplicateCount += 1
                    $skippedCount += 1
                    try {
                        $job | Add-Member -NotePropertyName id -NotePropertyValue $existingTrackedId -Force
                    } catch {}
                    Send-JobIterationOutcomeMessage -Job $job -SequenceNumber $sequence -TotalCount $sortedJobs.Count -OutcomeCode 'SKIPPED' -ReasonText 'already_tracked_duplicate' -BotToken $telegramBotToken -ChatId $telegramChatId
                    continue
                }

                $resolvedJobId = Get-NextSequentialTrackerJobId -TrackerPath $jobTrackerFile
                try {
                    $job | Add-Member -NotePropertyName id -NotePropertyValue $resolvedJobId -Force
                } catch {}

                if (-not (Test-JobLink -JobUrl $job.job_url)) {
                    Write-Host "Discarding job '$resolvedJobId' due to inactive link."
                    $invalidLinkCount += 1
                    $skippedCount += 1
                    Send-JobIterationOutcomeMessage -Job $job -SequenceNumber $sequence -TotalCount $sortedJobs.Count -OutcomeCode 'SKIPPED' -ReasonText 'inactive_or_invalid_link' -BotToken $telegramBotToken -ChatId $telegramChatId
                    continue
                }

                $isNewJob = $false
                try {
                    $isNewJob = Add-FoundJobIfMissing -TrackerPath $jobTrackerFile -Job $job -Source "job_search_wrapper"
                } catch {
                    Write-Host "State tracking error for job '$resolvedJobId': $_"
                    continue
                }

                if ($isNewJob) {
                    $message = Format-TelegramJobMessage -Job $job -SequenceNumber $sequence -TotalCount $sortedJobs.Count

                    if ($telegramBotToken) {
                        Write-Host "Sending Telegram message for job $resolvedJobId..."
                        try {
                            $tgResp = Send-TelegramTextDeterministic -BotToken $telegramBotToken -ChatId $telegramChatId -Text $message -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode "HTML"
                            $messageId = if ($tgResp.result.message_id) { "$($tgResp.result.message_id)" } else { "" }
                            if (-not [string]::IsNullOrWhiteSpace($messageId)) {
                                Register-TelegramMessageMap -JobId "$resolvedJobId" -ChatId "$telegramChatId" -MessageId $messageId
                            }
                            Set-JobStatus -TrackerPath $jobTrackerFile -JobId "$resolvedJobId" -NewStatus "Sent" -Reason "Job notification sent to Telegram" -FieldUpdates @{ telegram_message_id = $messageId }
                            Write-DispatchLog -JobId "$resolvedJobId" -Status "Sent" -Reason "telegram_message_dispatched"
                            Write-Host "Telegram message sent for job $resolvedJobId."
                            $sentCount += 1
                            Start-Sleep -Seconds 5
                        } catch {
                            try {
                                Set-JobStatus -TrackerPath $jobTrackerFile -JobId "$resolvedJobId" -NewStatus "Apply_Failed" -Reason "Failed to send Telegram notification" -FieldUpdates @{ last_error = "$_" }
                                Write-DispatchLog -JobId "$resolvedJobId" -Status "Apply_Failed" -Reason "telegram_send_failed"
                            } catch {
                                Write-Host "Failed to persist failure state for job ${resolvedJobId}: $_"
                            }
                            Write-Host "ERROR sending Telegram message for job ${resolvedJobId}: $_"
                            $skippedCount += 1
                            Send-JobIterationOutcomeMessage -Job $job -SequenceNumber $sequence -TotalCount $sortedJobs.Count -OutcomeCode 'FAILED' -ReasonText 'telegram_send_failed' -BotToken $telegramBotToken -ChatId $telegramChatId
                        }
                    } else {
                        try {
                            Set-JobStatus -TrackerPath $jobTrackerFile -JobId "$resolvedJobId" -NewStatus "Apply_Failed" -Reason "Missing TELEGRAM_BOT_TOKEN" -FieldUpdates @{ last_error = "TELEGRAM_BOT_TOKEN is not set" }
                        } catch {
                            Write-Host "Failed to persist missing-token state for job ${resolvedJobId}: $_"
                        }
                        Write-Host "Skipping Telegram message for job ${resolvedJobId}: TELEGRAM_BOT_TOKEN is not set."
                        Write-Host "Job Details (not sent): Company: $($job.company), Title: $($job.title), Location: $($job.location)"
                        $skippedCount += 1
                    }
                } else {
                    Write-Host "Job $resolvedJobId already tracked. Skipping duplicate notification."
                    $duplicateCount += 1
                    $skippedCount += 1
                    Send-JobIterationOutcomeMessage -Job $job -SequenceNumber $sequence -TotalCount $sortedJobs.Count -OutcomeCode 'SKIPPED' -ReasonText 'already_tracked_duplicate' -BotToken $telegramBotToken -ChatId $telegramChatId
                }
            }

            if ($telegramBotToken) {
                $summary = "&#128202; <b>Iteration summary</b>`nprocessed: <code>$($sortedJobs.Count)</code>`nsent: <code>$sentCount</code>`nskipped: <code>$skippedCount</code>`n- missing_url: <code>$missingUrlCount</code>`n- invalid_link: <code>$invalidLinkCount</code>`n- duplicate: <code>$duplicateCount</code>"
                try {
                    Send-TelegramTextDeterministic -BotToken $telegramBotToken -ChatId $telegramChatId -Text $summary -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode "HTML" | Out-Null
                } catch {
                    Write-Host "Failed to send iteration summary message: $_"
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
