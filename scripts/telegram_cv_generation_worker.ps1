param(
    [Parameter(Mandatory=$true)][string]$JobId,
    [Parameter(Mandatory=$true)][string]$BotToken,
    [Parameter(Mandatory=$true)][string]$ChatId
)

. "$PSScriptRoot\job_state_machine.ps1"
. "$PSScriptRoot\telegram_interface.ps1"

$workspaceRoot = Join-Path $PSScriptRoot '..'
$trackerPath = Join-Path $workspaceRoot 'job_tracker.csv'
$jobsFoundPath = Join-Path $workspaceRoot 'jobs_found.json'
$jobsRawPath = Join-Path $workspaceRoot 'jobs.json'
$rocketEmoji = [char]::ConvertFromUtf32(0x1F680)

Initialize-JobTracker -TrackerPath $trackerPath

function Get-JobById {
    param([Parameter(Mandatory=$true)][string]$TargetJobId)

    foreach ($path in @($jobsFoundPath, $jobsRawPath)) {
        if (Test-Path $path) {
            try {
                $jobs = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
                $job = @($jobs) | Where-Object { "$($_.id)" -eq "$TargetJobId" } | Select-Object -First 1
                if ($job) { return $job }
            } catch {}
        }
    }

    return $null
}

function Get-NextCvPath {
    param([Parameter(Mandatory=$true)][string]$TargetJobId)

    $jobDir = Join-Path $workspaceRoot ("Generated_CVs/" + $TargetJobId)
    if (-not (Test-Path $jobDir)) {
        New-Item -ItemType Directory -Path $jobDir | Out-Null
    }

    $version = 1
    while ($true) {
        $candidate = Join-Path $jobDir ("draft_v$version.pdf")
        if (-not (Test-Path $candidate)) {
            return $candidate
        }
        $version += 1
    }
}

$rows = Get-TrackerRows -TrackerPath $trackerPath
$row = $rows | Where-Object { "$($_.job_id)" -eq "$JobId" } | Select-Object -First 1
if (-not $row) {
    try {
        $msg = "&#9888;&#65039; Could not start CV generation for <b>$JobId</b>: job not found in tracker."
        Send-TelegramTextDeterministic -BotToken $BotToken -ChatId $ChatId -Text $msg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
    } catch {}
    exit 1
}

$job = Get-JobById -TargetJobId $JobId
if (-not $job) {
    $job = [PSCustomObject]@{
        id = $JobId
        title = "$($row.title)"
        company = "$($row.company)"
        location = "$($row.location)"
        job_url = "$($row.job_url)"
        description = "Role: $($row.title)`nCompany: $($row.company)`nLocation: $($row.location)`nLink: $($row.job_url)"
    }
}

$desc = if ($job.description) { "$($job.description)" } else { "Role: $($job.title)`nCompany: $($job.company)`nLocation: $($job.location)`nLink: $($job.job_url)" }
$jobDescPath = Join-Path $workspaceRoot 'current_job_desc.txt'
Set-Content -Path $jobDescPath -Value $desc -Encoding UTF8

$cvPath = Get-NextCvPath -TargetJobId $JobId
$pushed = $false

try {
    Push-Location $workspaceRoot
    $pushed = $true
    & node dist/cli.js generate --profile profile.md --job current_job_desc.txt --out "$cvPath" --theme modern
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0 -or -not (Test-Path $cvPath)) {
        throw "CV generation command failed (exit=$exitCode)."
    }

    $caption = "CV draft generated for Job ID: $JobId`nPlease review manually.`nReact with $rocketEmoji only after approval."
    Send-TelegramDocumentDeterministic -BotToken $BotToken -ChatId $ChatId -FilePath $cvPath -Caption $caption -MaxRetries 3 -RetryDelaySeconds 2 | Out-Null

    Set-JobStatus -TrackerPath $trackerPath -JobId $JobId -NewStatus 'CV_Ready_For_Review' -Reason 'Draft CV sent to Telegram for manual review' -FieldUpdates @{ latest_cv_path = $cvPath; last_error = '' }
    Write-DispatchLog -JobId $JobId -Status 'CV_Ready_For_Review' -Reason 'cv_sent_for_manual_review'
} catch {
    try {
        Set-JobStatus -TrackerPath $trackerPath -JobId $JobId -NewStatus 'Apply_Failed' -Reason 'CV generation/send failed' -FieldUpdates @{ last_error = "$_" }
    } catch {}
    Write-DispatchLog -JobId $JobId -Status 'Apply_Failed' -Reason 'cv_generation_or_send_failed'

    try {
        $msg = "&#9888;&#65039; CV generation failed for <b>$JobId</b>. Check logs for details."
        Send-TelegramTextDeterministic -BotToken $BotToken -ChatId $ChatId -Text $msg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
    } catch {}
} finally {
    if ($pushed) {
        Pop-Location
    }
    if (Test-Path $jobDescPath) {
        Remove-Item $jobDescPath -ErrorAction SilentlyContinue
    }
}
