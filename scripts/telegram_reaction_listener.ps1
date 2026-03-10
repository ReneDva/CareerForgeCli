param(
    [string]$ChatId = '5225138885',
    [int]$PollIntervalSeconds = 3,
    [bool]$SkipBacklogOnStart = $true,
    [int]$RecentReactionWindowMinutes = 30,
    [int]$RecentMappedMessageWindowMinutes = 60,
    [switch]$Once
)

. "$PSScriptRoot\job_state_machine.ps1"
. "$PSScriptRoot\telegram_interface.ps1"

$workspaceRoot = Join-Path $PSScriptRoot '..'
$trackerPath = Join-Path $workspaceRoot 'job_tracker.csv'
$jobsFoundPath = Join-Path $workspaceRoot 'jobs_found.json'
$jobsRawPath = Join-Path $workspaceRoot 'jobs.json'
$offsetPath = Join-Path $workspaceRoot 'memory/telegram_update_offset.txt'
$invalidNoticeLogPath = Join-Path $workspaceRoot 'memory/telegram_invalid_notice_log.csv'
$modelStatePath = Join-Path $workspaceRoot 'memory/telegram_model_state.json'
$searchSchedulerStatePath = Join-Path $workspaceRoot 'memory/telegram_search_scheduler.json'
$searchPendingEditStatePath = Join-Path $workspaceRoot 'memory/telegram_search_pending_edit_state.json'
$projectConfigLocalPath = Join-Path $workspaceRoot 'project.config.local.json'
$projectConfigExamplePath = Join-Path $workspaceRoot 'project.config.example.json'
$telegramCommandsBackupDir = Join-Path $workspaceRoot 'memory/telegram_command_backups'
$searchConfigPath = Join-Path $workspaceRoot 'search_config.json'
$searchWrapperScriptPath = Join-Path $workspaceRoot 'job_search_wrapper.ps1'
$processJobsScriptPath = Join-Path $workspaceRoot 'process_jobs.ps1'
$listenerStdoutLogPath = Join-Path $workspaceRoot 'memory/telegram_listener_background.log'
$listenerStderrLogPath = Join-Path $workspaceRoot 'memory/telegram_listener_background.err.log'
$dispatchLogPath = Join-Path $workspaceRoot 'memory/telegram_dispatch.log'
$invalidReactionCooldownSeconds = 120
$cvGeneratingRetryAfterMinutes = 10
$script:InvalidReactionNoticeCache = @{}
$script:SearchRunInProgress = $false

Initialize-JobTracker -TrackerPath $trackerPath

$thumbsUpEmoji = [char]::ConvertFromUtf32(0x1F44D)
$rocketEmoji = [char]::ConvertFromUtf32(0x1F680)
$heartEmoji = [char]::ConvertFromUtf32(0x2764)
$fireEmoji = [char]::ConvertFromUtf32(0x1F525)

function Get-Offset {
    if (Test-Path $offsetPath) {
        $v = Get-Content $offsetPath -Raw -Encoding UTF8
        $trimmed = if ($null -ne $v) { "$v".Trim() } else { '' }
        if ($trimmed -match '^\d+$') { return [int64]$trimmed }
    }
    return 0
}

function Save-Offset {
    param([int64]$Offset)
    Set-Content -Path $offsetPath -Value "$Offset" -Encoding UTF8 -NoNewline
}

function Ensure-InvalidNoticeLogFile {
    if (-not (Test-Path $invalidNoticeLogPath)) {
        'job_id,notice_type,sent_at' | Set-Content -Path $invalidNoticeLogPath -Encoding UTF8
    }
}

function Has-InvalidNoticeBeenSent {
    param(
        [Parameter(Mandatory=$true)][string]$JobId,
        [Parameter(Mandatory=$true)][string]$NoticeType
    )

    Ensure-InvalidNoticeLogFile
    try {
        $rows = Import-Csv $invalidNoticeLogPath
        $existing = $rows | Where-Object { "$($_.job_id)" -eq "$JobId" -and "$($_.notice_type)" -eq "$NoticeType" } | Select-Object -First 1
        return ($null -ne $existing)
    } catch {
        return $false
    }
}

function Register-InvalidNoticeSent {
    param(
        [Parameter(Mandatory=$true)][string]$JobId,
        [Parameter(Mandatory=$true)][string]$NoticeType
    )

    Ensure-InvalidNoticeLogFile
    $line = "$JobId,$NoticeType,$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Add-Content -Path $invalidNoticeLogPath -Value $line -Encoding UTF8
}

function Test-IsUpdateRecent {
    param(
        [Parameter(Mandatory=$false)]$UnixDate,
        [int]$WindowMinutes = 30
    )

    if ($null -eq $UnixDate -or "$UnixDate" -eq '') {
        return $true
    }

    try {
        $eventDt = [System.DateTimeOffset]::FromUnixTimeSeconds([int64]$UnixDate)
        $ageMinutes = (([System.DateTimeOffset]::UtcNow - $eventDt).TotalMinutes)
        return ($ageMinutes -le $WindowMinutes)
    } catch {
        return $true
    }
}

function Get-MessageMapRow {
    param(
        [Parameter(Mandatory=$true)][string]$ChatId,
        [Parameter(Mandatory=$true)][string]$MessageId,
        [string]$MapPath = 'memory/telegram_message_map.csv'
    )

    if (-not (Test-Path $MapPath)) {
        return $null
    }

    try {
        $rows = Import-Csv $MapPath
        return $rows | Where-Object { "$($_.chat_id)" -eq "$ChatId" -and "$($_.message_id)" -eq "$MessageId" } | Select-Object -First 1
    } catch {
        return $null
    }
}

function Test-IsMappedMessageRecent {
    param(
        [Parameter(Mandatory=$false)]$MapRow,
        [int]$WindowMinutes = 60
    )

    if ($null -eq $MapRow) {
        return $false
    }

    $createdAtText = "$($MapRow.created_at)"
    if ([string]::IsNullOrWhiteSpace($createdAtText)) {
        return $false
    }

    try {
        $createdAt = [datetime]::Parse($createdAtText)
        $ageMinutes = (New-TimeSpan -Start $createdAt -End (Get-Date)).TotalMinutes
        return ($ageMinutes -le $WindowMinutes)
    } catch {
        return $false
    }
}

function Initialize-OffsetFromLatestUpdates {
    param(
        [Parameter(Mandatory=$true)][string]$BotToken,
        [bool]$SkipBacklog = $true,
        [string[]]$AllowedUpdates = @('message', 'message_reaction')
    )

    if (-not $SkipBacklog) {
        return
    }

    try {
        $allowedUpdatesJson = $AllowedUpdates | ConvertTo-Json -Compress
        $allowedUpdates = [System.Uri]::EscapeDataString($allowedUpdatesJson)
        $uri = "https://api.telegram.org/bot$BotToken/getUpdates?timeout=0&limit=100&allowed_updates=$allowedUpdates"
        $resp = Invoke-RestMethod -Uri $uri -Method Get -ErrorAction Stop
        if ($resp.ok -and $resp.result -and @($resp.result).Count -gt 0) {
            $maxUpdate = (@($resp.result | Sort-Object { $_.update_id } | Select-Object -Last 1)[0]).update_id
            if ($null -ne $maxUpdate) {
                $nextOffset = [int64]$maxUpdate + 1
                Save-Offset -Offset $nextOffset
                Write-Host "Initialized Telegram offset to $nextOffset (skipped backlog on startup)."
            }
        }
    } catch {
        Write-Host "Could not initialize offset from latest updates: $_"
    }
}

function Get-JobById {
    param([Parameter(Mandatory=$true)][string]$JobId)

    foreach ($path in @($jobsFoundPath, $jobsRawPath)) {
        if (Test-Path $path) {
            try {
                $jobs = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
                $job = @($jobs) | Where-Object { "$($_.id)" -eq "$JobId" } | Select-Object -First 1
                if ($job) { return $job }
            } catch {}
        }
    }

    return $null
}

function Get-FileTailText {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [int]$TailLines = 20
    )

    if (-not (Test-Path $Path)) {
        return '(log file missing)'
    }

    try {
        $lines = Get-Content -Path $Path -Tail $TailLines -ErrorAction Stop
        $text = @($lines) -join "`n"
        if ([string]::IsNullOrWhiteSpace($text)) {
            return '(log file is empty)'
        }
        return $text
    } catch {
        return "(failed to read log: $($_.Exception.Message))"
    }
}

function Get-RecentSystemLogsMessage {
    param([int]$TailLines = 20)

    $outText = Get-FileTailText -Path $listenerStdoutLogPath -TailLines $TailLines
    $errText = Get-FileTailText -Path $listenerStderrLogPath -TailLines $TailLines
    $dispatchText = Get-FileTailText -Path $dispatchLogPath -TailLines $TailLines

    $latestWorkerOutPath = ''
    $latestWorkerErrPath = ''
    try {
        $workerOutCandidates = @(Get-ChildItem -Path (Join-Path $workspaceRoot 'memory') -Filter 'telegram_cv_worker_*.log' -File | Sort-Object LastWriteTime -Descending)
        if ($workerOutCandidates.Count -gt 0) {
            $latestWorkerOutPath = "$($workerOutCandidates[0].FullName)"
        }

        $workerErrCandidates = @(Get-ChildItem -Path (Join-Path $workspaceRoot 'memory') -Filter 'telegram_cv_worker_*.err.log' -File | Sort-Object LastWriteTime -Descending)
        if ($workerErrCandidates.Count -gt 0) {
            $latestWorkerErrPath = "$($workerErrCandidates[0].FullName)"
        }
    } catch {}

    $workerOutText = if ([string]::IsNullOrWhiteSpace($latestWorkerOutPath)) { '(worker log missing)' } else { Get-FileTailText -Path $latestWorkerOutPath -TailLines $TailLines }
    $workerErrText = if ([string]::IsNullOrWhiteSpace($latestWorkerErrPath)) { '(worker err log missing)' } else { Get-FileTailText -Path $latestWorkerErrPath -TailLines $TailLines }

    $outEsc = [System.Security.SecurityElement]::Escape($outText)
    $errEsc = [System.Security.SecurityElement]::Escape($errText)
    $dispatchEsc = [System.Security.SecurityElement]::Escape($dispatchText)
    $workerOutEsc = [System.Security.SecurityElement]::Escape($workerOutText)
    $workerErrEsc = [System.Security.SecurityElement]::Escape($workerErrText)

    return @(
        '&#128221; <b>Recent system logs</b>',
        "OUT (<code>$TailLines</code> lines):",
        "<pre>$outEsc</pre>",
        "ERR (<code>$TailLines</code> lines):",
        "<pre>$errEsc</pre>",
        "DISPATCH (<code>$TailLines</code> lines):",
        "<pre>$dispatchEsc</pre>",
        "CV_WORKER_OUT (<code>$TailLines</code> lines):",
        "<pre>$workerOutEsc</pre>",
        "CV_WORKER_ERR (<code>$TailLines</code> lines):",
        "<pre>$workerErrEsc</pre>"
    ) -join "`n"
}

function Get-NextCvPath {
    param([Parameter(Mandatory=$true)][string]$JobId)

    $jobDir = Join-Path $workspaceRoot ("Generated_CVs/" + $JobId)
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

function Invoke-JobTransitionWithGuidance {
    param(
        [Parameter(Mandatory=$true)][string]$JobId,
        [Parameter(Mandatory=$true)][string]$NewStatus,
        [string]$Reason,
        [hashtable]$FieldUpdates,
        [Parameter(Mandatory=$true)][string]$BotToken,
        [Parameter(Mandatory=$true)][string]$ChatId,
        [switch]$SuppressUserMessage
    )

    try {
        if ($PSBoundParameters.ContainsKey('FieldUpdates')) {
            Set-JobStatus -TrackerPath $trackerPath -JobId $JobId -NewStatus $NewStatus -Reason $Reason -FieldUpdates $FieldUpdates
        } else {
            Set-JobStatus -TrackerPath $trackerPath -JobId $JobId -NewStatus $NewStatus -Reason $Reason
        }
        return $true
    } catch {
        $errText = if ($_.Exception -and $_.Exception.Message) { "$($_.Exception.Message)" } else { "$_" }
        Write-Host "State transition failed for job_id=$JobId target=$NewStatus error=$errText"

        if (-not $SuppressUserMessage) {
            try {
                $safeJobId = [System.Security.SecurityElement]::Escape($JobId)
                $safeTarget = [System.Security.SecurityElement]::Escape($NewStatus)

                if ($errText -match "Invalid status transition: '([^']+)' -> '([^']+)'. Allowed: (.+)$") {
                    $currentEsc = [System.Security.SecurityElement]::Escape("$($matches[1])")
                    $allowedEsc = [System.Security.SecurityElement]::Escape("$($matches[3])")
                    $msg = "&#9888;&#65039; Cannot move job <b>$safeJobId</b> from <b>$currentEsc</b> to <b>$safeTarget</b>.`nAllowed next states: <b>$allowedEsc</b>."
                } elseif ($errText -match "Guard violation: cannot move to Applied from '([^']+)'") {
                    $currentEsc = [System.Security.SecurityElement]::Escape("$($matches[1])")
                    $msg = "&#9888;&#65039; Apply is blocked for job <b>$safeJobId</b>.`nCurrent state: <b>$currentEsc</b>. Must be <b>Approved_For_Apply</b> first."
                } else {
                    $msg = "&#9888;&#65039; Could not update state for job <b>$safeJobId</b> to <b>$safeTarget</b>. Please retry."
                }

                Send-TelegramTextDeterministic -BotToken $BotToken -ChatId $ChatId -Text $msg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
            } catch {
                Write-Host "Failed to send transition guidance message: $_"
            }
        }

        return $false
    }
}

function Start-CvGenerationForJob {
    param(
        [Parameter(Mandatory=$true)][string]$JobId,
        [Parameter(Mandatory=$true)][string]$BotToken,
        [Parameter(Mandatory=$true)][string]$ChatId,
        [switch]$SuppressInvalidStatusMessage
    )

    $rows = Get-TrackerRows -TrackerPath $trackerPath
    $row = $rows | Where-Object { "$($_.job_id)" -eq "$JobId" } | Select-Object -First 1
    if (-not $row) {
        Write-Host "Job '$JobId' not found in tracker."
        try {
            $msg = "&#9888;&#65039; Could not start CV generation for <b>$JobId</b>: job not found in tracker."
            Send-TelegramTextDeterministic -BotToken $BotToken -ChatId $ChatId -Text $msg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
        } catch {}
        return $false
    }

    $status = "$($row.status)"
    if ($status -ne 'Sent' -and $status -ne 'CV_Revision_Requested') {
        Write-Host "Skipping CV generation for '$JobId' from status '$status'."
        if (-not $SuppressInvalidStatusMessage) {
            try {
                $statusEsc = [System.Security.SecurityElement]::Escape($status)
                $msg = "&#8505;&#65039; Job <b>$JobId</b> is currently in status <b>$statusEsc</b>. CV generation is allowed only from <b>Sent</b> or <b>CV_Revision_Requested</b>."
                Send-TelegramTextDeterministic -BotToken $BotToken -ChatId $ChatId -Text $msg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
            } catch {}
        }
        return $false
    }

    $canGenerate = Invoke-JobTransitionWithGuidance -JobId $JobId -NewStatus 'CV_Generating' -Reason 'Triggered by Telegram thumbs-up reaction' -BotToken $BotToken -ChatId $ChatId -SuppressUserMessage:$SuppressInvalidStatusMessage
    if (-not $canGenerate) {
        return $false
    }

    $job = Get-JobById -JobId $JobId
    if (-not $job) {
        # Fallback to tracker row data (useful for test messages or if jobs files rotated)
        $job = [PSCustomObject]@{
            id = $JobId
            title = "$($row.title)"
            company = "$($row.company)"
            location = "$($row.location)"
            job_url = "$($row.job_url)"
            description = "Role: $($row.title)`nCompany: $($row.company)`nLocation: $($row.location)`nLink: $($row.job_url)"
        }
        Write-Host "Job '$JobId' not found in jobs files; using tracker row fallback."
    }

    $title = if ($job.title) { "$($job.title)" } else { 'Unknown role' }
    $titleEsc = [System.Security.SecurityElement]::Escape($title)
    $ackText = "&#9989; Started generating your CV for job <b>$JobId</b>`nRole: $titleEsc"
    try {
        Send-TelegramTextDeterministic -BotToken $BotToken -ChatId $ChatId -Text $ackText -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
    } catch {
        Write-Host "Failed to send CV-generation ACK message for '$JobId': $_"
    }

    $workerPath = Join-Path $PSScriptRoot 'telegram_cv_generation_worker.ps1'
    $workerStdoutLogPath = Join-Path $workspaceRoot ("memory/telegram_cv_worker_" + $JobId + ".log")
    $workerStderrLogPath = Join-Path $workspaceRoot ("memory/telegram_cv_worker_" + $JobId + ".err.log")
    if (-not (Test-Path $workerPath)) {
        Write-Host "CV generation worker script is missing: $workerPath"
        try {
            Invoke-JobTransitionWithGuidance -JobId $JobId -NewStatus 'Apply_Failed' -Reason 'CV generation worker missing' -FieldUpdates @{ last_error = "Worker script not found: $workerPath" } -BotToken $BotToken -ChatId $ChatId -SuppressUserMessage | Out-Null
        } catch {}
        return $false
    }

    try {
        $activeModel = Get-ActiveModelForChat -ChatId "$ChatId"
        $isAllowedModel = @((Get-ModelOptions) | Where-Object { "$($_.id)" -eq "$activeModel" }).Count -gt 0
        if (-not $isAllowedModel) {
            throw "Selected model '$activeModel' is not in allowed model list."
        }

        $psHostPath = $null
        try {
            $psHostPath = (Get-Command powershell.exe -ErrorAction Stop).Source
        } catch {
            try {
                $psHostPath = (Get-Command pwsh.exe -ErrorAction Stop).Source
            } catch {
                try {
                    $psHostPath = (Get-Command pwsh -ErrorAction Stop).Source
                } catch {
                    throw "Cannot launch CV worker: neither powershell.exe nor pwsh is available in PATH."
                }
            }
        }

        $escapeArg = {
            param([string]$Value)
            if ($null -eq $Value) { return '""' }
            $escaped = "$Value".Replace('"', '""')
            return '"' + $escaped + '"'
        }

        $argList = @(
            '-NoProfile',
            '-File', (& $escapeArg "$workerPath"),
            '-JobId', (& $escapeArg "$JobId"),
            '-BotToken', (& $escapeArg "$BotToken"),
            '-ChatId', (& $escapeArg "$ChatId"),
            '-ModelId', (& $escapeArg "$activeModel"),
            '-JobTitle', (& $escapeArg "$($job.title)"),
            '-JobCompany', (& $escapeArg "$($job.company)"),
            '-JobLocation', (& $escapeArg "$($job.location)"),
            '-JobUrl', (& $escapeArg "$($job.job_url)")
        )

        $proc = Start-Process -FilePath $psHostPath -ArgumentList $argList -WindowStyle Hidden -RedirectStandardOutput $workerStdoutLogPath -RedirectStandardError $workerStderrLogPath -PassThru
        Start-Sleep -Seconds 2
        try { $proc.Refresh() } catch {}

        if ($proc.HasExited) {
            $exitCode = $proc.ExitCode
            $launchErr = "CV worker exited immediately (exit=$exitCode). stderr log: $workerStderrLogPath"
            Write-Host "Failed async CV worker health-check for '$JobId': $launchErr"
            try {
                Invoke-JobTransitionWithGuidance -JobId $JobId -NewStatus 'Apply_Failed' -Reason 'CV worker exited immediately' -FieldUpdates @{ last_error = $launchErr } -BotToken $BotToken -ChatId $ChatId -SuppressUserMessage | Out-Null
            } catch {}
            return $false
        }

        Write-Host "Queued async CV generation worker for job_id=$JobId via host=$psHostPath (pid=$($proc.Id) stdout=$workerStdoutLogPath stderr=$workerStderrLogPath)"
        return $true
    } catch {
        Write-Host "Failed to start async CV generation worker for '$JobId': $_"
        try {
            Invoke-JobTransitionWithGuidance -JobId $JobId -NewStatus 'Apply_Failed' -Reason 'CV generation worker launch failed' -FieldUpdates @{ last_error = "$_" } -BotToken $BotToken -ChatId $ChatId -SuppressUserMessage | Out-Null
        } catch {}
        return $false
    }
}

function Get-JobTrackerRow {
    param([Parameter(Mandatory=$true)][string]$JobId)

    $rows = Get-TrackerRows -TrackerPath $trackerPath
    return $rows | Where-Object { "$($_.job_id)" -eq "$JobId" } | Select-Object -First 1
}

function Send-ManualApplyPackageForJob {
    param(
        [Parameter(Mandatory=$true)][string]$JobId,
        [Parameter(Mandatory=$true)][string]$BotToken,
        [Parameter(Mandatory=$true)][string]$ChatId
    )

    $row = Get-JobTrackerRow -JobId $JobId
    if (-not $row) {
        return $false
    }

    $currentStatus = "$($row.status)"
    if ($currentStatus -eq 'CV_Ready_For_Review') {
        $approved = Invoke-JobTransitionWithGuidance -JobId $JobId -NewStatus 'Approved_For_Apply' -Reason 'Manual CV approval confirmed via approval reaction' -BotToken $BotToken -ChatId $ChatId
        if (-not $approved) {
            return $false
        }
        $row = Get-JobTrackerRow -JobId $JobId
    } elseif ($currentStatus -ne 'Approved_For_Apply') {
        return $false
    }

    $latestCvPath = if ($row.latest_cv_path) { "$($row.latest_cv_path)" } else { '' }
    if ([string]::IsNullOrWhiteSpace($latestCvPath) -or -not (Test-Path $latestCvPath)) {
        $msg = "&#9888;&#65039; Cannot prepare manual apply package for <b>$JobId</b>: missing generated CV file."
        Send-TelegramTextDeterministic -BotToken $BotToken -ChatId $ChatId -Text $msg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
        return $false
    }

    $jobDir = Split-Path -Path $latestCvPath -Parent
    if ([string]::IsNullOrWhiteSpace($jobDir) -or -not (Test-Path $jobDir)) {
        $jobDir = Join-Path $workspaceRoot ("Generated_CVs/" + $JobId)
        if (-not (Test-Path $jobDir)) {
            New-Item -ItemType Directory -Path $jobDir -Force | Out-Null
        }
    }

    $manualPdfPath = Join-Path $jobDir 'Rene_Dvash.pdf'
    Copy-Item -Path $latestCvPath -Destination $manualPdfPath -Force

    $jobUrl = if ($row.job_url) { "$($row.job_url)" } else { '' }
    $caption = "Manual apply package for Job ID: $JobId`nFile: Rene_Dvash.pdf"
    Send-TelegramDocumentDeterministic -BotToken $BotToken -ChatId $ChatId -FilePath $manualPdfPath -Caption $caption -MaxRetries 3 -RetryDelaySeconds 2 | Out-Null

    $jobUrlEsc = [System.Security.SecurityElement]::Escape($jobUrl)
    $followup = if ([string]::IsNullOrWhiteSpace($jobUrl)) {
        "&#128230; Manual apply package is ready for <b>$JobId</b>.`nUse the attached <code>Rene_Dvash.pdf</code> for your manual submission."
    } else {
        "&#128230; Manual apply package is ready for <b>$JobId</b>.`nJob link: <code>$jobUrlEsc</code>`nUse the attached <code>Rene_Dvash.pdf</code> for your manual submission."
    }
    Send-TelegramTextDeterministic -BotToken $BotToken -ChatId $ChatId -Text $followup -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null

    Set-JobStatus -TrackerPath $trackerPath -JobId $JobId -NewStatus 'Approved_For_Apply' -Reason 'Manual apply package sent to Telegram' -FieldUpdates @{ submitted_cv_path = $manualPdfPath; last_error = '' }
    Write-DispatchLog -JobId $JobId -Status 'Approved_For_Apply' -Reason 'manual_apply_package_sent'
    return $true
}

function Get-AllowedEmojiForStatus {
    param([Parameter(Mandatory=$true)][string]$Status)

    switch ($Status) {
        'Sent' { return @('thumbs_up') }
        'CV_Revision_Requested' { return @('thumbs_up') }
        'CV_Ready_For_Review' { return @('rocket', 'heart', 'fire') }
        'Approved_For_Apply' { return @('rocket', 'heart', 'fire') }
        default { return @() }
    }
}

function Convert-EmojiKeyToHtml {
    param([Parameter(Mandatory=$true)][string]$EmojiKey)

    switch ($EmojiKey) {
        'thumbs_up' { return '&#128077;' }
        'rocket' { return '&#128640;' }
        'heart' { return '&#10084;&#65039;' }
        'fire' { return '&#128293;' }
        default { return '&#10067;' }
    }
}

function Should-SendInvalidReactionNotice {
    param(
        [Parameter(Mandatory=$true)][string]$JobId,
        [Parameter(Mandatory=$true)][string]$Status,
        [Parameter(Mandatory=$true)][string]$EmojiKey,
        [int]$CooldownSeconds = 120
    )

    $cacheKey = "$JobId|$Status|$EmojiKey"
    $now = Get-Date

    if ($script:InvalidReactionNoticeCache.ContainsKey($cacheKey)) {
        $last = $script:InvalidReactionNoticeCache[$cacheKey]
        if (($now - $last).TotalSeconds -lt $CooldownSeconds) {
            return $false
        }
    }

    $script:InvalidReactionNoticeCache[$cacheKey] = $now
    return $true
}

function Send-InvalidReactionGuidance {
    param(
        [Parameter(Mandatory=$true)][string]$JobId,
        [Parameter(Mandatory=$true)][string]$CurrentStatus,
        [Parameter(Mandatory=$true)][string]$EmojiKey,
        [Parameter(Mandatory=$true)][string]$BotToken,
        [Parameter(Mandatory=$true)][string]$ChatId
    )

    $statusEsc = [System.Security.SecurityElement]::Escape($CurrentStatus)
    $allowed = Get-AllowedEmojiForStatus -Status $CurrentStatus
    $allowedHtml = if ($allowed.Count -gt 0) { (($allowed | ForEach-Object { Convert-EmojiKeyToHtml -EmojiKey $_ }) -join ' / ') } else { 'No reaction is supported in this status' }
    $emojiHtml = Convert-EmojiKeyToHtml -EmojiKey $EmojiKey

    $nextStep = switch ($CurrentStatus) {
        'Found' { 'Please wait for the bot notification message first.' }
        'Sent' { 'Use &#128077; to generate a CV draft.' }
        'CV_Generating' { 'CV generation is already running. Please wait for the draft PDF.' }
        'CV_Ready_For_Review' { 'Review the draft, then use &#128640; / &#10084;&#65039; / &#128293; to continue apply flow.' }
        'CV_Revision_Requested' { 'Use &#128077; to generate the revised CV draft.' }
        'Approved_For_Apply' { 'Use &#128640; / &#10084;&#65039; / &#128293; to continue apply flow.' }
        'Apply_Failed' { 'This job is in Apply_Failed. Re-send the job via process pipeline before reacting again.' }
        'Rejected_By_User' { 'This job was rejected. Re-send it via process pipeline if you want to reopen it.' }
        'Applied' { 'This job is already applied. No further reaction is needed.' }
        default { 'Please re-send this job via process pipeline and react on the new notification.' }
    }

    $msg = "&#8505;&#65039; Reaction <b>$emojiHtml</b> is not valid for job <b>$JobId</b> in status <b>$statusEsc</b>.`nAllowed now: <b>$allowedHtml</b>.`n$nextStep"
    Send-TelegramTextDeterministic -BotToken $BotToken -ChatId $ChatId -Text $msg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
}

function Get-ReactionEmojiSet {
    param($ReactionArray)

    $emojis = @()
    if ($ReactionArray) {
        foreach ($r in $ReactionArray) {
            if ($r.type -eq 'emoji' -and $r.emoji) {
                $emojis += "$($r.emoji)"
            }
        }
    }
    return $emojis
}

function Get-OpenTaskStatusesMessage {
    param([Parameter(Mandatory=$true)][string]$TrackerPath)

    $rows = Get-TrackerRows -TrackerPath $TrackerPath
    if (-not $rows -or @($rows).Count -eq 0) {
        return "&#8505;&#65039; No tracked tasks found yet."
    }

    $closedStatuses = @('Applied', 'Rejected_By_User')
    $openRows = @($rows | Where-Object { $closedStatuses -notcontains "$($_.status)" })

    if ($openRows.Count -eq 0) {
        return "&#9989; No open tasks right now."
    }

    $ordered = @($openRows | Sort-Object { $_.updated_at } -Descending)
    $maxLines = 20
    $selected = @($ordered | Select-Object -First $maxLines)

    $lines = @()
    $lines += "&#128221; <b>Open tasks: $($openRows.Count)</b>"

    foreach ($r in $selected) {
        $jobId = [System.Security.SecurityElement]::Escape("$($r.job_id)")
        $status = [System.Security.SecurityElement]::Escape("$($r.status)")
        $updated = [System.Security.SecurityElement]::Escape("$($r.updated_at)")
        $lines += "- <b>$jobId</b>: $status (updated: $updated)"
    }

    if ($openRows.Count -gt $maxLines) {
        $remaining = $openRows.Count - $maxLines
        $lines += "... and $remaining more"
    }

    return ($lines -join "`n")
}

function Get-CompactJobsMessage {
    param(
        [Parameter(Mandatory=$true)][string]$TrackerPath,
        [int]$MaxRows = 15
    )

    $rows = Get-TrackerRows -TrackerPath $TrackerPath
    if (-not $rows -or @($rows).Count -eq 0) {
        return "&#8505;&#65039; No jobs in tracker yet."
    }

    $sorted = @(
        $rows | Sort-Object @{ Expression = {
            try { [datetime]::Parse("$($_.updated_at)") } catch { [datetime]::MinValue }
        }; Descending = $true }
    )

    $selected = @($sorted | Select-Object -First $MaxRows)

    $shortStatusMap = @{
        'Found' = 'Found'
        'Sent' = 'Sent'
        'CV_Generating' = 'CV_Gen'
        'CV_Ready_For_Review' = 'CV_Ready'
        'CV_Revision_Requested' = 'CV_Rev'
        'Approved_For_Apply' = 'Approved'
        'Applied' = 'Applied'
        'Apply_Failed' = 'Failed'
        'Rejected_By_User' = 'Rejected'
    }

    $lines = @()
    $lines += "&#128203; <b>Jobs summary</b> (showing $($selected.Count)/$($rows.Count))"
    foreach ($r in $selected) {
        $jobId = [System.Security.SecurityElement]::Escape("$($r.job_id)")
        $statusRaw = "$($r.status)"
        $statusShort = if ($shortStatusMap.ContainsKey($statusRaw)) { $shortStatusMap[$statusRaw] } else { $statusRaw }
        $statusEsc = [System.Security.SecurityElement]::Escape($statusShort)

        $company = if ($r.company) { "$($r.company)" } else { 'Unknown' }
        $title = if ($r.title) { "$($r.title)" } else { 'Unknown role' }
        $roleText = "$company - $title"
        if ($roleText.Length -gt 58) {
            $roleText = $roleText.Substring(0, 55) + '...'
        }
        $roleEsc = [System.Security.SecurityElement]::Escape($roleText)

        $lines += "<code>$jobId</code> | <b>$statusEsc</b> | $roleEsc"
    }

    if ($rows.Count -gt $MaxRows) {
        $remaining = $rows.Count - $MaxRows
        $lines += "... and $remaining more rows"
    }

    return ($lines -join "`n")
}

function Get-OpenClawPathsMessage {
    $userHomeDir = [Environment]::GetFolderPath('UserProfile')
    $defaultRoot = Join-Path $userHomeDir '.openclaw'

    $configPath = if ($env:OPENCLAW_CONFIG_PATH) { "$($env:OPENCLAW_CONFIG_PATH)" } else { Join-Path $defaultRoot 'openclaw.json' }
    $stateDir = if ($env:OPENCLAW_STATE_DIR) { "$($env:OPENCLAW_STATE_DIR)" } else { $defaultRoot }
    $agentId = if ($env:OPENCLAW_AGENT_ID) { "$($env:OPENCLAW_AGENT_ID)" } else { '<agentId>' }
    $workspacePath = if ($env:OPENCLAW_WORKSPACE_PATH) { "$($env:OPENCLAW_WORKSPACE_PATH)" } else { Join-Path $stateDir ("workspace-" + $agentId) }
    $agentDir = if ($env:OPENCLAW_AGENT_DIR) { "$($env:OPENCLAW_AGENT_DIR)" } else { Join-Path $stateDir ("agents/" + $agentId + "/agent") }
    $sessionsPath = if ($env:OPENCLAW_SESSIONS_DIR) { "$($env:OPENCLAW_SESSIONS_DIR)" } else { Join-Path $stateDir ("agents/" + $agentId + "/sessions") }

    $configEsc = [System.Security.SecurityElement]::Escape($configPath)
    $stateEsc = [System.Security.SecurityElement]::Escape($stateDir)
    $workspaceEsc = [System.Security.SecurityElement]::Escape($workspacePath)
    $agentEsc = [System.Security.SecurityElement]::Escape($agentDir)
    $sessionsEsc = [System.Security.SecurityElement]::Escape($sessionsPath)

    $lines = @()
    $lines += "&#128193; <b>Paths (quick map)</b>"
    $lines += "Config: <code>$configEsc</code>"
    $lines += "State dir: <code>$stateEsc</code>"
    $lines += "Workspace: <code>$workspaceEsc</code>"
    $lines += "Agent dir: <code>$agentEsc</code>"
    $lines += "Sessions: <code>$sessionsEsc</code>"

    return ($lines -join "`n")
}

function Get-ModelOptions {
    return @(
        [PSCustomObject]@{ id = 'google/gemini-3-pro-preview'; label = 'Gemini 3 Pro Preview'; short = '3-pro-preview' },
        [PSCustomObject]@{ id = 'google/gemini-2.5-pro'; label = 'Gemini 2.5 Pro'; short = '2.5-pro' },
        [PSCustomObject]@{ id = 'google/gemini-2.0-flash'; label = 'Gemini 2.0 Flash'; short = '2.0-flash' }
    )
}

function Ensure-ModelStateFile {
    if (-not (Test-Path $modelStatePath)) {
        $seed = @{ by_chat = @{} } | ConvertTo-Json -Depth 6
        Set-Content -Path $modelStatePath -Value $seed -Encoding UTF8
    }
}

function Get-ModelState {
    Ensure-ModelStateFile
    try {
        $raw = Get-Content $modelStatePath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return @{ by_chat = @{} }
        }

        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $parsed.by_chat) {
            $parsed | Add-Member -NotePropertyName by_chat -NotePropertyValue @{} -Force
        }
        return $parsed
    } catch {
        return @{ by_chat = @{} }
    }
}

function Save-ModelState {
    param([Parameter(Mandatory=$true)]$State)
    $json = $State | ConvertTo-Json -Depth 10
    Set-Content -Path $modelStatePath -Value $json -Encoding UTF8
}

function Resolve-DefaultModel {
    $options = Get-ModelOptions
    if ($env:OPENCLAW_ACTIVE_MODEL -and @($options | Where-Object { "$($_.id)" -eq "$($env:OPENCLAW_ACTIVE_MODEL)" }).Count -gt 0) {
        return "$($env:OPENCLAW_ACTIVE_MODEL)"
    }
    return "$($options[0].id)"
}

function Get-ActiveModelForChat {
    param([Parameter(Mandatory=$true)][string]$ChatId)

    $state = Get-ModelState
    $selected = $null
    if ($state.by_chat) {
        $selected = $state.by_chat.$ChatId
    }

    $options = Get-ModelOptions
    $validSelected = @($options | Where-Object { "$($_.id)" -eq "$selected" } | Select-Object -First 1)
    if ($validSelected.Count -gt 0) {
        return "$selected"
    }

    return Resolve-DefaultModel
}

function Set-ActiveModelForChat {
    param(
        [Parameter(Mandatory=$true)][string]$ChatId,
        [Parameter(Mandatory=$true)][string]$ModelId
    )

    $options = Get-ModelOptions
    $exists = @($options | Where-Object { "$($_.id)" -eq "$ModelId" }).Count -gt 0
    if (-not $exists) {
        throw "Unknown model id: $ModelId"
    }

    $state = Get-ModelState
    if ($null -eq $state.by_chat) {
        $state | Add-Member -NotePropertyName by_chat -NotePropertyValue @{} -Force
    }

    $state.by_chat | Add-Member -NotePropertyName $ChatId -NotePropertyValue $ModelId -Force
    Save-ModelState -State $state
}

function Get-ModelLabelById {
    param([Parameter(Mandatory=$true)][string]$ModelId)
    $row = Get-ModelOptions | Where-Object { "$($_.id)" -eq "$ModelId" } | Select-Object -First 1
    if ($row) { return "$($row.label)" }
    return $ModelId
}

function Get-ModelStatusMessage {
    param([Parameter(Mandatory=$true)][string]$ChatId)

    $activeModel = Get-ActiveModelForChat -ChatId $ChatId
    $activeLabel = Get-ModelLabelById -ModelId $activeModel
    $fallbackChain = @(
        'google/gemini-3-pro-preview',
        'google/gemini-2.5-pro',
        'google/gemini-2.0-flash'
    )

    $activeEsc = [System.Security.SecurityElement]::Escape($activeModel)
    $activeLabelEsc = [System.Security.SecurityElement]::Escape($activeLabel)
    $fallbackEsc = [System.Security.SecurityElement]::Escape(($fallbackChain -join ' -> '))

    $lines = @()
    $lines += "&#129504; <b>Model status</b>"
    $lines += "Active: <b>$activeLabelEsc</b>"
    $lines += "ID: <code>$activeEsc</code>"
    $lines += "Fallback chain: <code>$fallbackEsc</code>"
    $lines += "Tip: use <code>/models</code> to pick a model quickly."
    return ($lines -join "`n")
}

function Get-ModelsKeyboardMarkup {
    param([Parameter(Mandatory=$true)][string]$ChatId)

    $activeModel = Get-ActiveModelForChat -ChatId $ChatId
    $rows = @()
    foreach ($m in Get-ModelOptions) {
        $isActive = "$($m.id)" -eq "$activeModel"
        $label = if ($isActive) { "ACTIVE: $($m.label)" } else { "$($m.label)" }
        $rows += ,@(@{ text = $label; callback_data = "cf_model_set|$($m.id)" })
    }
    $rows += ,@(@{ text = 'Model status'; callback_data = 'cf_model_status' })

    return @{ inline_keyboard = $rows }
}

function Resolve-ModelInput {
    param([Parameter(Mandatory=$true)][string]$RawInput)

    $value = "$RawInput".Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    foreach ($m in Get-ModelOptions) {
        if ("$($m.id)".ToLowerInvariant() -eq $value) { return "$($m.id)" }
        if ("$($m.short)".ToLowerInvariant() -eq $value) { return "$($m.id)" }
    }

    switch ($value) {
        '3' { return 'google/gemini-3-pro-preview' }
        '2.5' { return 'google/gemini-2.5-pro' }
        '2' { return 'google/gemini-2.0-flash' }
        default { return $null }
    }
}

function Ensure-SearchSchedulerStateFile {
    if (-not (Test-Path $searchSchedulerStatePath)) {
        $seed = [PSCustomObject]@{
            enabled = $false
            interval_seconds = 0
            next_run_utc = $null
            last_run_utc = $null
            last_status = 'never'
            last_error = ''
        }
        $seed | ConvertTo-Json -Depth 6 | Set-Content -Path $searchSchedulerStatePath -Encoding UTF8
    }
}

function Get-SearchSchedulerState {
    Ensure-SearchSchedulerStateFile
    try {
        $raw = Get-Content -Path $searchSchedulerStatePath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            throw 'empty scheduler state file'
        }

        $state = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $state.enabled) { $state | Add-Member -NotePropertyName enabled -NotePropertyValue $false -Force }
        if ($null -eq $state.interval_seconds) { $state | Add-Member -NotePropertyName interval_seconds -NotePropertyValue 0 -Force }
        if ($null -eq $state.next_run_utc) { $state | Add-Member -NotePropertyName next_run_utc -NotePropertyValue $null -Force }
        if ($null -eq $state.last_run_utc) { $state | Add-Member -NotePropertyName last_run_utc -NotePropertyValue $null -Force }
        if ($null -eq $state.last_status) { $state | Add-Member -NotePropertyName last_status -NotePropertyValue 'unknown' -Force }
        if ($null -eq $state.last_error) { $state | Add-Member -NotePropertyName last_error -NotePropertyValue '' -Force }
        return $state
    } catch {
        $fallback = [PSCustomObject]@{
            enabled = $false
            interval_seconds = 0
            next_run_utc = $null
            last_run_utc = $null
            last_status = 'reset'
            last_error = 'state_parse_error'
        }
        $fallback | ConvertTo-Json -Depth 6 | Set-Content -Path $searchSchedulerStatePath -Encoding UTF8
        return $fallback
    }
}

function Save-SearchSchedulerState {
    param([Parameter(Mandatory=$true)]$State)
    $State | ConvertTo-Json -Depth 8 | Set-Content -Path $searchSchedulerStatePath -Encoding UTF8
}

function Parse-SearchTimerIntervalSeconds {
    param([Parameter(Mandatory=$true)][string]$InputText)

    $value = "$InputText".Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw 'Timer value is empty. Use formats like 6h or 2d.'
    }

    if ($value -match '^(?<n>\d+)\s*(?<u>[hd])$') {
        $n = [int]$matches['n']
        $u = "$($matches['u'])"
        if ($n -le 0) {
            throw 'Timer value must be positive.'
        }
        switch ($u) {
            'h' { return ($n * 3600) }
            'd' { return ($n * 86400) }
        }
    }

    throw "Unsupported timer format '$InputText'. Use 6h or 2d."
}

function Ensure-SearchConfigFile {
    if (-not (Test-Path $searchConfigPath)) {
        throw "search_config.json not found at '$searchConfigPath'"
    }
}

function Get-SearchConfigObject {
    Ensure-SearchConfigFile
    return (Get-Content -Path $searchConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Save-SearchConfigObject {
    param([Parameter(Mandatory=$true)]$Config)
    $Config | ConvertTo-Json -Depth 20 | Set-Content -Path $searchConfigPath -Encoding UTF8
}

function Ensure-SearchPendingEditStateFile {
    if (-not (Test-Path $searchPendingEditStatePath)) {
        $seed = @{ by_chat = @{} } | ConvertTo-Json -Depth 8
        Set-Content -Path $searchPendingEditStatePath -Value $seed -Encoding UTF8
    }
}

function Get-SearchPendingEditState {
    Ensure-SearchPendingEditStateFile
    try {
        $raw = Get-Content -Path $searchPendingEditStatePath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return @{ by_chat = @{} }
        }

        $state = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $state.by_chat) {
            $state | Add-Member -NotePropertyName by_chat -NotePropertyValue @{} -Force
        }
        return $state
    } catch {
        return @{ by_chat = @{} }
    }
}

function Save-SearchPendingEditState {
    param([Parameter(Mandatory=$true)]$State)
    $State | ConvertTo-Json -Depth 12 | Set-Content -Path $searchPendingEditStatePath -Encoding UTF8
}

function Get-SearchPendingEditForChat {
    param([Parameter(Mandatory=$true)][string]$ChatId)

    $state = Get-SearchPendingEditState
    if ($state.by_chat) {
        return $state.by_chat.$ChatId
    }
    return $null
}

function Set-SearchPendingEditForChat {
    param(
        [Parameter(Mandatory=$true)][string]$ChatId,
        [Parameter(Mandatory=$true)][string]$Key,
        [Parameter(Mandatory=$true)][string]$Mode
    )

    $validModes = @('replace', 'add', 'remove')
    if ($validModes -notcontains $Mode) {
        throw "Unsupported pending edit mode: $Mode"
    }

    $state = Get-SearchPendingEditState
    if ($null -eq $state.by_chat) {
        $state | Add-Member -NotePropertyName by_chat -NotePropertyValue @{} -Force
    }

    $state.by_chat | Add-Member -NotePropertyName $ChatId -NotePropertyValue ([PSCustomObject]@{
        key = $Key
        mode = $Mode
        updated_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    }) -Force

    Save-SearchPendingEditState -State $state
}

function Clear-SearchPendingEditForChat {
    param([Parameter(Mandatory=$true)][string]$ChatId)

    $state = Get-SearchPendingEditState
    if ($state.by_chat -and $state.by_chat.PSObject.Properties[$ChatId]) {
        $state.by_chat.PSObject.Properties.Remove($ChatId)
        Save-SearchPendingEditState -State $state
    }
}

function Test-IsSearchArrayKey {
    param([Parameter(Mandatory=$true)][string]$Key)
    return @('queries', 'locations', 'allowedLocationKeywords', 'excludeTitleKeywords') -contains $Key
}

function Get-SearchConfigKeyCurrentValueText {
    param(
        [Parameter(Mandatory=$true)]$Config,
        [Parameter(Mandatory=$true)][string]$Key
    )

    $v = $Config.$Key
    if ($null -eq $v) {
        return '<none>'
    }

    if (Test-IsSearchArrayKey -Key $Key) {
        $arr = @($v)
        if ($arr.Count -eq 0) {
            return '<none>'
        }
        return ($arr -join ', ')
    }

    return "$v"
}

function Get-SearchEditModeKeyboardMarkup {
    param([Parameter(Mandatory=$true)][string]$Key)

    $rows = @()
    $rows += ,@(@{ text = "Replace $Key"; callback_data = "cf_search_mode|$Key|replace" })
    if (Test-IsSearchArrayKey -Key $Key) {
        $rows += ,@(@{ text = "Add values to $Key"; callback_data = "cf_search_mode|$Key|add" })
        $rows += ,@(@{ text = "Remove values from $Key"; callback_data = "cf_search_mode|$Key|remove" })
    }
    $rows += ,@(@{ text = 'Cancel edit'; callback_data = 'cf_search_edit_cancel' })
    $rows += ,@(@{ text = 'Back to fields'; callback_data = 'cf_search_set_menu' })
    return @{ inline_keyboard = $rows }
}

function Apply-SearchConfigEdit {
    param(
        [Parameter(Mandatory=$true)][string]$Key,
        [Parameter(Mandatory=$true)][string]$Mode,
        [Parameter(Mandatory=$true)][string]$RawValue
    )

    $cfg = Get-SearchConfigObject
    $valueText = "$RawValue".Trim()

    if ([string]::IsNullOrWhiteSpace($valueText)) {
        throw 'Value cannot be empty.'
    }

    if ($Mode -eq 'replace') {
        Set-SearchConfigValue -Key $Key -RawValue $valueText | Out-Null
        return Get-SearchConfigObject
    }

    if (-not (Test-IsSearchArrayKey -Key $Key)) {
        throw "Mode '$Mode' is supported only for list fields."
    }

    $items = @($valueText -split ',' | ForEach-Object { "$($_)".Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($items.Count -eq 0) {
        throw 'Please provide at least one comma-separated value.'
    }

    $existing = @($cfg.$Key)
    if ($Mode -eq 'add') {
        $merged = @($existing)
        foreach ($item in $items) {
            $exists = @($merged | Where-Object { "$($_)" -ceq "$item" }).Count -gt 0
            if (-not $exists) {
                $merged += $item
            }
        }
        $cfg.$Key = $merged
    } elseif ($Mode -eq 'remove') {
        $toRemove = @{}
        foreach ($item in $items) {
            $toRemove["$item".ToLowerInvariant()] = $true
        }

        $remaining = @($existing | Where-Object {
            $k = "$_".ToLowerInvariant()
            -not $toRemove.ContainsKey($k)
        })
        $cfg.$Key = $remaining
    } else {
        throw "Unsupported edit mode: $Mode"
    }

    Save-SearchConfigObject -Config $cfg
    return $cfg
}

function Get-SearchConfigStatusMessage {
    $cfg = Get-SearchConfigObject
    $scheduler = Get-SearchSchedulerState

    $queries = if ($cfg.queries) { (@($cfg.queries) -join ', ') } else { '<none>' }
    $locations = if ($cfg.locations) { (@($cfg.locations) -join ', ') } else { '<none>' }
    $allowedLocationKeywords = if ($cfg.allowedLocationKeywords) { (@($cfg.allowedLocationKeywords) -join ', ') } else { '<none>' }
    $excludeTitleKeywords = if ($cfg.excludeTitleKeywords) { (@($cfg.excludeTitleKeywords) -join ', ') } else { '<none>' }

    $schedulerStatus = if ([bool]$scheduler.enabled) { 'enabled' } else { 'disabled' }
    $nextRun = if ($scheduler.next_run_utc) { "$($scheduler.next_run_utc)" } else { 'n/a' }

    $lines = @()
    $lines += "&#128269; <b>Search configuration</b>"
    $lines += "queries: <code>$([System.Security.SecurityElement]::Escape($queries))</code>"
    $lines += "locations: <code>$([System.Security.SecurityElement]::Escape($locations))</code>"
    $lines += "allowedLocationKeywords: <code>$([System.Security.SecurityElement]::Escape($allowedLocationKeywords))</code>"
    $lines += "excludeTitleKeywords: <code>$([System.Security.SecurityElement]::Escape($excludeTitleKeywords))</code>"
    $lines += "resultsPerQuery: <code>$($cfg.resultsPerQuery)</code>"
    $lines += "hoursOld: <code>$($cfg.hoursOld)</code>"
    $lines += "minDisqualifyingYears: <code>$($cfg.minDisqualifyingYears)</code>"
    $lines += "allowUnknownLocation: <code>$($cfg.allowUnknownLocation)</code>"
    $lines += ""
    $lines += "&#9201; scheduler: <b>$schedulerStatus</b>"
    $lines += "interval_seconds: <code>$($scheduler.interval_seconds)</code>"
    $lines += "next_run_utc: <code>$([System.Security.SecurityElement]::Escape($nextRun))</code>"
    $lines += ""
    $lines += "Use <code>/search_set &lt;key&gt; &lt;value&gt;</code> (arrays as comma-separated)."
    return ($lines -join "`n")
}

function Set-SearchConfigValue {
    param(
        [Parameter(Mandatory=$true)][string]$Key,
        [Parameter(Mandatory=$true)][string]$RawValue
    )

    $allowedKeys = @(
        'queries', 'locations', 'allowedLocationKeywords', 'excludeTitleKeywords',
        'allowUnknownLocation', 'minDisqualifyingYears', 'maxAgeHours', 'hoursOld', 'resultsPerQuery'
    )

    if ($allowedKeys -notcontains $Key) {
        throw "Key '$Key' is not editable via Telegram."
    }

    $cfg = Get-SearchConfigObject
    $valueText = "$RawValue".Trim()

    switch ($Key) {
        'queries' {
            $items = @($valueText -split ',' | ForEach-Object { "$($_)".Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($items.Count -eq 0) { throw 'queries must contain at least one item.' }
            $cfg.queries = $items
        }
        'locations' {
            $items = @($valueText -split ',' | ForEach-Object { "$($_)".Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($items.Count -eq 0) { throw 'locations must contain at least one item.' }
            $cfg.locations = $items
        }
        'allowedLocationKeywords' {
            $items = @($valueText -split ',' | ForEach-Object { "$($_)".Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $cfg.allowedLocationKeywords = $items
        }
        'excludeTitleKeywords' {
            $items = @($valueText -split ',' | ForEach-Object { "$($_)".Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $cfg.excludeTitleKeywords = $items
        }
        'allowUnknownLocation' {
            if ($valueText -match '^(true|1|yes|on)$') {
                $cfg.allowUnknownLocation = $true
            } elseif ($valueText -match '^(false|0|no|off)$') {
                $cfg.allowUnknownLocation = $false
            } else {
                throw "allowUnknownLocation must be true/false."
            }
        }
        'minDisqualifyingYears' {
            $n = [int]$valueText
            if ($n -lt 0 -or $n -gt 20) { throw 'minDisqualifyingYears must be 0..20.' }
            $cfg.minDisqualifyingYears = $n
        }
        'maxAgeHours' {
            $n = [int]$valueText
            if ($n -lt 1 -or $n -gt 720) { throw 'maxAgeHours must be 1..720.' }
            $cfg.maxAgeHours = $n
        }
        'hoursOld' {
            $n = [int]$valueText
            if ($n -lt 1 -or $n -gt 720) { throw 'hoursOld must be 1..720.' }
            $cfg.hoursOld = $n
        }
        'resultsPerQuery' {
            $n = [int]$valueText
            if ($n -lt 1 -or $n -gt 200) { throw 'resultsPerQuery must be 1..200.' }
            $cfg.resultsPerQuery = $n
        }
    }

    Save-SearchConfigObject -Config $cfg
    return $cfg
}

function Get-SearchEditableKeys {
    return @(
        'queries',
        'locations',
        'allowedLocationKeywords',
        'excludeTitleKeywords',
        'allowUnknownLocation',
        'minDisqualifyingYears',
        'maxAgeHours',
        'hoursOld',
        'resultsPerQuery'
    )
}

function Get-SearchConfigEditKeyboardMarkup {
    $rows = @()
    foreach ($k in Get-SearchEditableKeys) {
        $rows += ,@(@{ text = "Edit: $k"; callback_data = "cf_search_key|$k" })
    }
    $rows += ,@(@{ text = 'Refresh config'; callback_data = 'cf_search_config_refresh' }, @{ text = 'Cancel pending edit'; callback_data = 'cf_search_edit_cancel' })
    return @{ inline_keyboard = $rows }
}

function Get-SearchSetHelpMessage {
    param([Parameter(Mandatory=$true)][string]$Key)

    $keyEsc = [System.Security.SecurityElement]::Escape($Key)
    switch ($Key) {
        'queries' {
            return "&#9998;&#65039; Set <code>$keyEsc</code> with comma-separated values.`nExample: <code>/search_set queries Junior Fullstack Developer,Junior Backend Developer</code>"
        }
        'locations' {
            return "&#9998;&#65039; Set <code>$keyEsc</code> with comma-separated values.`nExample: <code>/search_set locations Israel,Remote</code>"
        }
        'allowedLocationKeywords' {
            return "&#9998;&#65039; Set <code>$keyEsc</code> with comma-separated city keywords.`nExample: <code>/search_set allowedLocationKeywords Tel Aviv,Ramat Gan</code>"
        }
        'excludeTitleKeywords' {
            return "&#9998;&#65039; Set <code>$keyEsc</code> with comma-separated seniority words.`nExample: <code>/search_set excludeTitleKeywords Senior,Lead,Principal</code>"
        }
        'allowUnknownLocation' {
            return "&#9998;&#65039; Set <code>$keyEsc</code> as boolean.`nExample: <code>/search_set allowUnknownLocation true</code>"
        }
        default {
            return "&#9998;&#65039; Set <code>$keyEsc</code>.`nExample: <code>/search_set $keyEsc 5</code>"
        }
    }
}

function Invoke-SearchPipeline {
    param(
        [Parameter(Mandatory=$true)][string]$Trigger,
        [Parameter(Mandatory=$true)][string]$BotToken,
        [Parameter(Mandatory=$true)][string]$ChatId
    )

    if ($script:SearchRunInProgress) {
        return [PSCustomObject]@{
            ok = $false
            message = 'Search is already in progress.'
            jobsCount = 0
        }
    }

    if (-not (Test-Path $searchWrapperScriptPath)) {
        return [PSCustomObject]@{ ok = $false; message = "Missing script: $searchWrapperScriptPath"; jobsCount = 0 }
    }
    if (-not (Test-Path $processJobsScriptPath)) {
        return [PSCustomObject]@{ ok = $false; message = "Missing script: $processJobsScriptPath"; jobsCount = 0 }
    }

    $script:SearchRunInProgress = $true
    try {
        Push-Location $workspaceRoot
        try {
            & $searchWrapperScriptPath 2>&1 | Out-Host
            $wrapperExit = $LASTEXITCODE
            if ($wrapperExit -ne 0) {
                return [PSCustomObject]@{ ok = $false; message = "job_search_wrapper failed (exit=$wrapperExit)"; jobsCount = 0 }
            }

            & $processJobsScriptPath 2>&1 | Out-Host
            $processExit = $LASTEXITCODE
            if ($processExit -ne 0) {
                return [PSCustomObject]@{ ok = $false; message = "process_jobs failed (exit=$processExit)"; jobsCount = 0 }
            }
        } finally {
            Pop-Location
        }

        $jobsCount = 0
        $jobsFoundPath = Join-Path $workspaceRoot 'jobs_found.json'
        if (Test-Path $jobsFoundPath) {
            try {
                $jobs = Get-Content -Path $jobsFoundPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($jobs) { $jobsCount = @($jobs).Count }
            } catch {}
        }

        return [PSCustomObject]@{
            ok = $true
            message = "Search completed via $Trigger. jobs_found=$jobsCount"
            jobsCount = $jobsCount
        }
    } catch {
        return [PSCustomObject]@{
            ok = $false
            message = "Search pipeline error: $($_.Exception.Message)"
            jobsCount = 0
        }
    } finally {
        $script:SearchRunInProgress = $false
    }
}

function Update-SearchSchedulerAfterRun {
    param(
        [Parameter(Mandatory=$true)][bool]$Success,
        [string]$ErrorText
    )

    $state = Get-SearchSchedulerState
    $nowUtc = (Get-Date).ToUniversalTime().ToString('o')
    $state.last_run_utc = $nowUtc
    $state.last_status = if ($Success) { 'ok' } else { 'failed' }
    $state.last_error = if ($Success) { '' } else { "$ErrorText" }

    if ([bool]$state.enabled -and [int]$state.interval_seconds -gt 0) {
        $state.next_run_utc = (Get-Date).ToUniversalTime().AddSeconds([int]$state.interval_seconds).ToString('o')
    }

    Save-SearchSchedulerState -State $state
}

function Try-RunScheduledSearch {
    param(
        [Parameter(Mandatory=$true)][string]$BotToken,
        [Parameter(Mandatory=$true)][string]$ChatId
    )

    $state = Get-SearchSchedulerState
    if (-not [bool]$state.enabled) { return }
    if ([int]$state.interval_seconds -le 0) { return }
    if ([string]::IsNullOrWhiteSpace("$($state.next_run_utc)")) { return }

    try {
        $nextRunUtc = [datetime]::Parse("$($state.next_run_utc)").ToUniversalTime()
    } catch {
        return
    }

    if ((Get-Date).ToUniversalTime() -lt $nextRunUtc) {
        return
    }

    $result = Invoke-SearchPipeline -Trigger 'scheduler' -BotToken $BotToken -ChatId $ChatId
    Update-SearchSchedulerAfterRun -Success:$result.ok -ErrorText $result.message

    try {
        $safeMsg = [System.Security.SecurityElement]::Escape($result.message)
        $prefix = if ($result.ok) { '&#9989;' } else { '&#9888;&#65039;' }
        $msg = "$prefix Auto search run: <code>$safeMsg</code>"
        Send-TelegramTextDeterministic -BotToken $BotToken -ChatId $ChatId -Text $msg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
    } catch {}
}

function Get-ProjectConfigObject {
    $candidatePaths = @($projectConfigLocalPath, $projectConfigExamplePath)
    foreach ($cfgPath in $candidatePaths) {
        if (-not (Test-Path $cfgPath)) {
            continue
        }

        try {
            $raw = Get-Content -Path $cfgPath -Raw -Encoding UTF8
            if ([string]::IsNullOrWhiteSpace($raw)) {
                continue
            }

            $cfg = $raw | ConvertFrom-Json -ErrorAction Stop
            if ($cfg) {
                return $cfg
            }
        } catch {
            Write-Host "Ignoring invalid project config file '$cfgPath': $_"
        }
    }

    return $null
}

function Get-ProjectConfigLocalWritableObject {
    if (Test-Path $projectConfigLocalPath) {
        try {
            $raw = Get-Content -Path $projectConfigLocalPath -Raw -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
                if ($parsed) {
                    return $parsed
                }
            }
        } catch {
            Write-Host "project.config.local.json invalid, recreating: $_"
        }
    }

    return [PSCustomObject]@{}
}

function Ensure-ConfigPath {
    param(
        [Parameter(Mandatory=$true)]$Root,
        [Parameter(Mandatory=$true)][string[]]$Path
    )

    $cursor = $Root
    foreach ($segment in $Path) {
        if ($null -eq $cursor.PSObject.Properties[$segment]) {
            $cursor | Add-Member -NotePropertyName $segment -NotePropertyValue ([PSCustomObject]@{}) -Force
        }

        $next = $cursor.$segment
        if ($null -eq $next) {
            $cursor | Add-Member -NotePropertyName $segment -NotePropertyValue ([PSCustomObject]@{}) -Force
            $next = $cursor.$segment
        }

        $cursor = $next
    }

    return $cursor
}

function Set-SearchRuntimeModeInConfig {
    param(
        [Parameter(Mandatory=$true)][ValidateSet('cli', 'agent')][string]$Mode
    )

    $cfg = Get-ProjectConfigLocalWritableObject
    $telegramNode = Ensure-ConfigPath -Root $cfg -Path @('careerforge', 'telegram')
    $telegramNode | Add-Member -NotePropertyName runtimeMode -NotePropertyValue $Mode -Force

    $json = $cfg | ConvertTo-Json -Depth 30
    Set-Content -Path $projectConfigLocalPath -Value $json -Encoding UTF8
}

function Get-SearchRuntimeMode {
    $cfg = Get-ProjectConfigObject
    $mode = $null
    try {
        if ($cfg -and $cfg.careerforge -and $cfg.careerforge.telegram -and $cfg.careerforge.telegram.runtimeMode) {
            $mode = "$($cfg.careerforge.telegram.runtimeMode)".Trim().ToLowerInvariant()
        }
    } catch {}

    if (@('cli', 'agent') -contains $mode) {
        return $mode
    }

    return 'cli'
}

function Get-TelegramCommandMenuConfig {
    $defaults = [PSCustomObject]@{
        enabled = $true
        preserveExistingCommands = $true
        visibleCommands = @()
    }

    $cfg = Get-ProjectConfigObject
    if (-not $cfg -or -not $cfg.careerforge -or -not $cfg.careerforge.telegram -or -not $cfg.careerforge.telegram.commandMenu) {
        return $defaults
    }

    $menu = $cfg.careerforge.telegram.commandMenu
    $visible = @()
    if ($menu.visibleCommands) {
        $visible = @($menu.visibleCommands | ForEach-Object { "$($_)".Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    return [PSCustomObject]@{
        enabled = if ($null -ne $menu.enabled) { [bool]$menu.enabled } else { $true }
        preserveExistingCommands = if ($null -ne $menu.preserveExistingCommands) { [bool]$menu.preserveExistingCommands } else { $true }
        visibleCommands = $visible
    }
}

function Resolve-VisibleTelegramCommands {
    param(
        [Parameter(Mandatory=$true)]$CommandCatalog,
        [Parameter(Mandatory=$false)]$VisibleCommands
    )

    $requested = @()
    if ($VisibleCommands) {
        $requested = @($VisibleCommands | ForEach-Object { "$($_)".Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    if ($requested.Count -eq 0) {
        return @($CommandCatalog)
    }

    $requestedSet = @{}
    foreach ($name in $requested) {
        $requestedSet[$name] = $true
    }

    $filtered = @()
    foreach ($cmd in @($CommandCatalog)) {
        $cmdName = "$($cmd.command)"
        if ($requestedSet.ContainsKey($cmdName)) {
            $filtered += [PSCustomObject]@{
                command = "$($cmd.command)"
                description = "$($cmd.description)"
            }
        }
    }

    return @($filtered)
}

function Merge-TelegramCommands {
    param(
        $ExistingCommands,
        [Parameter(Mandatory=$true)]$DesiredCommands,
        [bool]$PreserveExisting = $true
    )

    if ($null -eq $ExistingCommands) {
        $ExistingCommands = @()
    }

    $merged = @()
    $indexByName = @{}

    if ($PreserveExisting -and $ExistingCommands) {
        foreach ($cmd in @($ExistingCommands)) {
            $name = "$($cmd.command)".Trim()
            $description = "$($cmd.description)".Trim()
            if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($description)) {
                continue
            }
            if ($indexByName.ContainsKey($name)) {
                continue
            }

            $indexByName[$name] = $merged.Count
            $merged += [PSCustomObject]@{
                command = $name
                description = $description
            }
        }
    }

    foreach ($cmd in @($DesiredCommands)) {
        $name = "$($cmd.command)".Trim()
        $description = "$($cmd.description)".Trim()
        if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($description)) {
            continue
        }

        if ($indexByName.ContainsKey($name)) {
            $idx = [int]$indexByName[$name]
            $merged[$idx] = [PSCustomObject]@{
                command = $name
                description = $description
            }
        } else {
            $indexByName[$name] = $merged.Count
            $merged += [PSCustomObject]@{
                command = $name
                description = $description
            }
        }
    }

    return @($merged)
}

function Backup-TelegramCommandsSnapshot {
    param(
        [Parameter(Mandatory=$true)][string]$ScopeName,
        $Commands
    )

    if ($null -eq $Commands) {
        $Commands = @()
    }

    if (-not (Test-Path $telegramCommandsBackupDir)) {
        New-Item -ItemType Directory -Path $telegramCommandsBackupDir -Force | Out-Null
    }

    $safeScopeName = ($ScopeName -replace '[^A-Za-z0-9_\-]', '_')
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd_HHmmss')
    $backupPath = Join-Path $telegramCommandsBackupDir ("${stamp}_${safeScopeName}.json")

    $payload = [ordered]@{
        created_at_utc = (Get-Date).ToUniversalTime().ToString('o')
        scope = $ScopeName
        commands_count = @($Commands).Count
        commands = @($Commands)
    }

    $payload | ConvertTo-Json -Depth 10 | Set-Content -Path $backupPath -Encoding UTF8
    return $backupPath
}

$botToken = Get-TelegramBotToken -WorkspaceRoot $workspaceRoot
if (-not $botToken) {
    Write-Host 'TELEGRAM_BOT_TOKEN not found in .env or environment.'
    exit 1
}

Ensure-InvalidNoticeLogFile

$allowedUpdateTypes = @('message', 'callback_query', 'message_reaction', 'my_chat_member')
$allowedUpdatesJson = $allowedUpdateTypes | ConvertTo-Json -Compress
$allowedUpdatesEscaped = [System.Uri]::EscapeDataString($allowedUpdatesJson)

try {
    $webhookInfo = Get-TelegramWebhookInfoDeterministic -BotToken $botToken
    if ($webhookInfo -and -not [string]::IsNullOrWhiteSpace("$($webhookInfo.url)")) {
        Write-Host "Webhook is currently active for this bot: $($webhookInfo.url)"
        Write-Host "Polling listener aborted to avoid conflict."
        Write-Host "Remediation: disable webhook first (deleteWebhook), then rerun this listener."
        exit 1
    }
} catch {
    Write-Host "Failed to validate webhook state before polling startup: $_"
    exit 1
}

try {
    $commandCatalog = @(
        @{ command = 'start'; description = 'Initialize chat and show current status' },
        @{ command = 'restart'; description = 'Hot-restart the agent' },
        @{ command = 'status'; description = 'Show gateway/skills/model status' },
        @{ command = 'stop'; description = 'Stop current agent run' },
        @{ command = 'paths'; description = 'Show OpenClaw config/state/workspace paths' },
        @{ command = 'search_agent'; description = 'Agent-filtered search (AI mode)' },
        @{ command = 'search_cli'; description = 'Direct CLI search + per-job notifications' },
        @{ command = 'mode_status'; description = 'Show active search runtime mode' },
        @{ command = 'mode_cli'; description = 'Set runtime mode to direct CLI automation' },
        @{ command = 'mode_agent'; description = 'Set runtime mode to agent-filtered behavior' },
        @{ command = 'search'; description = 'Alias: direct CLI search' },
        @{ command = 'search_start'; description = 'Alias: direct CLI search' },
        @{ command = 'search_timer'; description = 'Set auto search interval (e.g. 6h/2d)' },
        @{ command = 'search_stop'; description = 'Stop auto search scheduler' },
        @{ command = 'search_config'; description = 'Show current search config and scheduler' },
        @{ command = 'search_set'; description = 'Update search config key/value' },
        @{ command = 'jobs'; description = 'Show latest jobs summary' },
        @{ command = 'profile'; description = 'Show active profile information' },
        @{ command = 'help'; description = 'List available commands' },
        @{ command = 'log'; description = 'Show recent logs' },
        @{ command = 'models'; description = 'List available OpenClaw models' },
        @{ command = 'model'; description = 'Show or set active OpenClaw model' },
        @{ command = 'open_tasks'; description = 'Show all non-closed tasks' }
    )

    $menuCfg = Get-TelegramCommandMenuConfig
    if (-not [bool]$menuCfg.enabled) {
        Write-Host 'Telegram bot menu sync is disabled by project config (careerforge.telegram.commandMenu.enabled=false).'
    } else {
        $desiredCommands = Resolve-VisibleTelegramCommands -CommandCatalog $commandCatalog -VisibleCommands $menuCfg.visibleCommands
        if (@($desiredCommands).Count -eq 0) {
            throw 'Configured visibleCommands resolved to an empty command list. Refusing to clear bot menu.'
        }

        $preserveExisting = [bool]$menuCfg.preserveExistingCommands

        $defaultCommands = Get-TelegramBotCommandsDeterministic -BotToken $botToken
        $defaultBackupPath = Backup-TelegramCommandsSnapshot -ScopeName 'default_pre_sync' -Commands $defaultCommands
        $defaultMerged = Merge-TelegramCommands -ExistingCommands $defaultCommands -DesiredCommands $desiredCommands -PreserveExisting:$preserveExisting
        Set-TelegramBotCommandsDeterministic -BotToken $botToken -Commands $defaultMerged | Out-Null

        $privateScope = @{ type = 'all_private_chats' }
        $privateCommands = Get-TelegramBotCommandsDeterministic -BotToken $botToken -Scope $privateScope
        $privateBackupPath = Backup-TelegramCommandsSnapshot -ScopeName 'all_private_chats_pre_sync' -Commands $privateCommands
        $privateMerged = Merge-TelegramCommands -ExistingCommands $privateCommands -DesiredCommands $desiredCommands -PreserveExisting:$preserveExisting
        Set-TelegramBotCommandsDeterministic -BotToken $botToken -Commands $privateMerged -Scope $privateScope | Out-Null

        $chatBackupPath = ''
        try {
            $chatScope = @{ type = 'chat'; chat_id = [int64]$ChatId }
            $chatCommands = Get-TelegramBotCommandsDeterministic -BotToken $botToken -Scope $chatScope
            $chatBackupPath = Backup-TelegramCommandsSnapshot -ScopeName 'chat_pre_sync' -Commands $chatCommands
            $chatMerged = Merge-TelegramCommands -ExistingCommands $chatCommands -DesiredCommands $desiredCommands -PreserveExisting:$preserveExisting
            Set-TelegramBotCommandsDeterministic -BotToken $botToken -Commands $chatMerged -Scope $chatScope | Out-Null
        } catch {
            Write-Host "Chat-scope command sync skipped: $_"
        }

        Write-Host "Registered Telegram bot menu commands (config-driven). preserveExisting=$preserveExisting defaultBackup='$defaultBackupPath' privateBackup='$privateBackupPath' chatBackup='$chatBackupPath'"
    }
} catch {
    Write-Host "Failed to register Telegram bot menu commands: $_"
}

Initialize-OffsetFromLatestUpdates -BotToken $botToken -SkipBacklog $SkipBacklogOnStart -AllowedUpdates $allowedUpdateTypes

$startupLog = [ordered]@{
    event = 'listener_start'
    mode = 'polling'
    chat_id = "$ChatId"
    once = [bool]$Once
    skip_backlog_on_start = [bool]$SkipBacklogOnStart
    poll_interval_seconds = $PollIntervalSeconds
    allowed_updates = $allowedUpdateTypes
    started_at_utc = (Get-Date).ToUniversalTime().ToString('o')
} | ConvertTo-Json -Compress
Write-Host $startupLog

while ($true) {
    $offset = Get-Offset
    $uri = "https://api.telegram.org/bot$botToken/getUpdates?timeout=20&offset=$offset&allowed_updates=$allowedUpdatesEscaped"

    try {
        $updatesResp = Invoke-RestMethod -Uri $uri -Method Get -ErrorAction Stop
    } catch {
        Write-Host "getUpdates failed: $_"
        if ($Once) { break }
        Start-Sleep -Seconds $PollIntervalSeconds
        continue
    }

    if ($updatesResp.ok -and $updatesResp.result) {
        $sortedUpdates = @($updatesResp.result | Sort-Object { $_.update_id })
        foreach ($u in $sortedUpdates) {
            $nextOffset = [int64]$u.update_id + 1
            Save-Offset -Offset $nextOffset

            if ($u.message_reaction) {
                $chat = "$($u.message_reaction.chat.id)"
                if ($chat -ne "$ChatId") { continue }
                if (-not (Test-IsUpdateRecent -UnixDate $u.message_reaction.date -WindowMinutes $RecentReactionWindowMinutes)) {
                    Write-Host "Ignored stale reaction update_id=$($u.update_id) message_id=$($u.message_reaction.message_id)."
                    continue
                }

                $messageId = "$($u.message_reaction.message_id)"
                $emojiSet = Get-ReactionEmojiSet -ReactionArray $u.message_reaction.new_reaction
                $jobId = Get-JobIdByTelegramMessageId -ChatId "$ChatId" -MessageId $messageId
                $mapRow = Get-MessageMapRow -ChatId "$ChatId" -MessageId $messageId

                if (-not (Test-IsMappedMessageRecent -MapRow $mapRow -WindowMinutes $RecentMappedMessageWindowMinutes)) {
                    Write-Host "Ignored reaction on old mapped message_id=$messageId (outside recent mapped-message window)."
                    continue
                }

                # Keep quiet on unmapped/legacy messages to avoid user spam.
                if (-not $jobId) {
                    Write-Host "Ignored reaction on unmapped message_id=$messageId."
                    continue
                }

                $row = Get-JobTrackerRow -JobId $jobId
                if (-not $row) {
                    Write-Host "Ignored reaction for unknown tracker job_id=$jobId."
                    continue
                }

                $currentStatus = "$($row.status)"

                if ($emojiSet -contains $thumbsUpEmoji) {
                    if ($currentStatus -eq 'Sent' -or $currentStatus -eq 'CV_Revision_Requested') {
                        Write-Host "Thumbs-up reaction mapped to job_id=$jobId (message_id=$messageId)."
                        Start-CvGenerationForJob -JobId $jobId -BotToken $botToken -ChatId $ChatId -SuppressInvalidStatusMessage
                    } elseif ($currentStatus -eq 'CV_Generating') {
                        $shouldRetryStaleGeneration = $false
                        $updatedAtText = "$($row.updated_at)"
                        try {
                            $updatedAt = [datetime]::Parse($updatedAtText)
                            $ageMinutes = (New-TimeSpan -Start $updatedAt -End (Get-Date)).TotalMinutes
                            if ($ageMinutes -ge $cvGeneratingRetryAfterMinutes) {
                                $shouldRetryStaleGeneration = $true
                            }
                        } catch {}

                        if ($shouldRetryStaleGeneration) {
                            Write-Host "Detected stale CV_Generating state for job_id=$jobId (>=${cvGeneratingRetryAfterMinutes}m). Re-queueing worker."
                            try {
                                Set-JobStatus -TrackerPath $trackerPath -JobId $jobId -NewStatus 'CV_Revision_Requested' -Reason 'Auto-retry after stale CV_Generating timeout' -FieldUpdates @{ last_error = 'Auto-retry triggered after stale CV_Generating state' }
                            } catch {
                                Write-Host "Failed to mark stale generation recovery for job_id=${jobId}: $_"
                            }
                            Start-CvGenerationForJob -JobId $jobId -BotToken $botToken -ChatId $ChatId -SuppressInvalidStatusMessage
                        } else {
                            Write-Host "Thumbs-up not valid for job_id=$jobId in status=$currentStatus (still within retry window)."
                        }
                    } else {
                        Write-Host "Thumbs-up not valid for job_id=$jobId in status=$currentStatus."
                        $noticeType = 'invalid_thumbs_up'
                        if (Has-InvalidNoticeBeenSent -JobId $jobId -NoticeType $noticeType) {
                            Write-Host "Skipped duplicate invalid notice for job_id=$jobId type=$noticeType."
                            continue
                        }
                        if (
                            (Should-SendInvalidReactionNotice -JobId $jobId -Status $currentStatus -EmojiKey 'thumbs_up' -CooldownSeconds $invalidReactionCooldownSeconds)
                        ) {
                            try {
                                Send-InvalidReactionGuidance -JobId $jobId -CurrentStatus $currentStatus -EmojiKey 'thumbs_up' -BotToken $botToken -ChatId $ChatId
                                Register-InvalidNoticeSent -JobId $jobId -NoticeType $noticeType
                            } catch {}
                        }
                    }
                } elseif (($emojiSet -contains $rocketEmoji) -or ($emojiSet -contains $heartEmoji) -or ($emojiSet -contains $fireEmoji)) {
                    $approvalEmojiKey = if ($emojiSet -contains $heartEmoji) { 'heart' } elseif ($emojiSet -contains $fireEmoji) { 'fire' } else { 'rocket' }
                    if ($currentStatus -eq 'CV_Ready_For_Review' -or $currentStatus -eq 'Approved_For_Apply') {
                        try {
                            $ok = Send-ManualApplyPackageForJob -JobId $jobId -BotToken $botToken -ChatId $ChatId
                            if (-not $ok) {
                                Write-Host "Approval-reaction flow failed for job_id=$jobId."
                            }
                        } catch {
                            Write-Host "Approval-reaction flow error for job_id=${jobId}: $_"
                        }
                    } else {
                        $noticeType = 'invalid_approval_reaction'
                        if (Has-InvalidNoticeBeenSent -JobId $jobId -NoticeType $noticeType) {
                            Write-Host "Skipped duplicate invalid notice for job_id=$jobId type=$noticeType."
                            continue
                        }
                        if (
                            (Should-SendInvalidReactionNotice -JobId $jobId -Status $currentStatus -EmojiKey $approvalEmojiKey -CooldownSeconds $invalidReactionCooldownSeconds)
                        ) {
                            try {
                                Send-InvalidReactionGuidance -JobId $jobId -CurrentStatus $currentStatus -EmojiKey $approvalEmojiKey -BotToken $botToken -ChatId $ChatId
                                Register-InvalidNoticeSent -JobId $jobId -NoticeType $noticeType
                            } catch {}
                        }
                    }
                }
            }

            if ($u.callback_query) {
                $callbackId = "$($u.callback_query.id)"
                $callbackData = "$($u.callback_query.data)"
                $callbackChat = ''
                if ($u.callback_query.message -and $u.callback_query.message.chat -and $u.callback_query.message.chat.id) {
                    $callbackChat = "$($u.callback_query.message.chat.id)"
                }

                try {
                    Send-TelegramAnswerCallbackDeterministic -BotToken $botToken -CallbackQueryId $callbackId | Out-Null
                } catch {
                    Write-Host "Failed to answer callback_query id=${callbackId}: $_"
                }

                if ($callbackChat -and $callbackChat -ne "$ChatId") {
                    continue
                }

                if ($callbackData -eq 'cf_model_status') {
                    try {
                        $statusMsg = Get-ModelStatusMessage -ChatId "$ChatId"
                        Send-TelegramTextDeterministic -BotToken $botToken -ChatId $ChatId -Text $statusMsg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
                    } catch {
                        Write-Host "Failed to send callback model status: $_"
                    }
                    continue
                }

                if ($callbackData -eq 'cf_search_config_refresh') {
                    try {
                        $statusMsg = Get-SearchConfigStatusMessage
                        $kb = Get-SearchConfigEditKeyboardMarkup
                        Send-TelegramTextWithReplyMarkupDeterministic -BotToken $botToken -ChatId $ChatId -Text $statusMsg -ReplyMarkup $kb -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
                    } catch {
                        Write-Host "Failed to send search config refresh: $_"
                    }
                    continue
                }

                if ($callbackData -eq 'cf_search_set_menu') {
                    try {
                        $usage = "&#8505;&#65039; Choose a field to edit. Then choose replace/add/remove and send the value as your next message."
                        $kb = Get-SearchConfigEditKeyboardMarkup
                        Send-TelegramTextWithReplyMarkupDeterministic -BotToken $botToken -ChatId $ChatId -Text $usage -ReplyMarkup $kb -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
                    } catch {
                        Write-Host "Failed to send search set menu: $_"
                    }
                    continue
                }

                if ($callbackData -eq 'cf_search_edit_cancel') {
                    try {
                        Clear-SearchPendingEditForChat -ChatId "$ChatId"
                        $msg = '&#9989; Pending search edit was cancelled.'
                        Send-TelegramTextDeterministic -BotToken $botToken -ChatId $ChatId -Text $msg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
                    } catch {
                        Write-Host "Failed to cancel pending search edit: $_"
                    }
                    continue
                }

                if ($callbackData -like 'cf_search_key|*') {
                    try {
                        $parts = "$callbackData" -split '\|', 2
                        $key = if ($parts.Count -ge 2) { "$($parts[1])" } else { '' }
                        if ([string]::IsNullOrWhiteSpace($key)) {
                            throw 'Missing key in callback data.'
                        }

                        $allowed = Get-SearchEditableKeys
                        if ($allowed -notcontains $key) {
                            throw "Unsupported editable key: $key"
                        }

                        Set-SearchPendingEditForChat -ChatId "$ChatId" -Key $key -Mode 'replace'
                        $cfg = Get-SearchConfigObject
                        $currentValue = Get-SearchConfigKeyCurrentValueText -Config $cfg -Key $key
                        $currentValueEsc = [System.Security.SecurityElement]::Escape($currentValue)
                        $keyEsc = [System.Security.SecurityElement]::Escape($key)
                        $help = Get-SearchSetHelpMessage -Key $key
                        $msg = "&#128221; <b>Editing field:</b> <code>$keyEsc</code>`nCurrent value: <code>$currentValueEsc</code>`n`n$help"
                        $kb = Get-SearchEditModeKeyboardMarkup -Key $key
                        Send-TelegramTextWithReplyMarkupDeterministic -BotToken $botToken -ChatId $ChatId -Text $msg -ReplyMarkup $kb -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
                    } catch {
                        Write-Host "Failed to process search key callback: $_"
                        try {
                            $errMsg = "&#9888;&#65039; Could not prepare search field edit flow. Try <code>/search_set &lt;key&gt; &lt;value&gt;</code>."
                            Send-TelegramTextDeterministic -BotToken $botToken -ChatId $ChatId -Text $errMsg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
                        } catch {}
                    }
                    continue
                }

                if ($callbackData -like 'cf_search_mode|*') {
                    try {
                        $parts = "$callbackData" -split '\|', 3
                        if ($parts.Count -lt 3) {
                            throw "Invalid callback data: $callbackData"
                        }

                        $key = "$($parts[1])".Trim()
                        $mode = "$($parts[2])".Trim().ToLowerInvariant()
                        $allowed = Get-SearchEditableKeys
                        if ($allowed -notcontains $key) {
                            throw "Unsupported editable key: $key"
                        }

                        if (@('replace', 'add', 'remove') -notcontains $mode) {
                            throw "Unsupported edit mode: $mode"
                        }

                        if (($mode -ne 'replace') -and -not (Test-IsSearchArrayKey -Key $key)) {
                            throw "Mode '$mode' is only available for list fields."
                        }

                        Set-SearchPendingEditForChat -ChatId "$ChatId" -Key $key -Mode $mode
                        $modeEsc = [System.Security.SecurityElement]::Escape($mode)
                        $keyEsc = [System.Security.SecurityElement]::Escape($key)
                        $hint = if ($mode -eq 'replace') { 'Send next message with the new value.' } else { 'Send next message with comma-separated values.' }
                        $msg = "&#9989; Edit mode set: <code>$modeEsc</code> for <code>$keyEsc</code>.`n$hint"
                        Send-TelegramTextDeterministic -BotToken $botToken -ChatId $ChatId -Text $msg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
                    } catch {
                        Write-Host "Failed to process search mode callback: $_"
                        try {
                            $errMsg = "&#9888;&#65039; Could not set edit mode. Please choose the field again from <code>/search_set</code>."
                            Send-TelegramTextDeterministic -BotToken $botToken -ChatId $ChatId -Text $errMsg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
                        } catch {}
                    }
                    continue
                }

                if ($callbackData -like 'cf_model_set|*') {
                    $parts = "$callbackData" -split '\|', 2
                    $requestedModel = if ($parts.Count -ge 2) { "$($parts[1])" } else { '' }
                    try {
                        $resolved = Resolve-ModelInput -RawInput $requestedModel
                        if (-not $resolved) {
                            throw "Unsupported model callback data: $callbackData"
                        }

                        Set-ActiveModelForChat -ChatId "$ChatId" -ModelId $resolved
                        $label = Get-ModelLabelById -ModelId $resolved
                        $labelEsc = [System.Security.SecurityElement]::Escape($label)
                        $idEsc = [System.Security.SecurityElement]::Escape($resolved)
                        $confirm = "&#9989; Active model updated to <b>$labelEsc</b>`n<code>$idEsc</code>"
                        Send-TelegramTextDeterministic -BotToken $botToken -ChatId $ChatId -Text $confirm -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
                    } catch {
                        Write-Host "Failed to process model selection callback: $_"
                        try {
                            $errMsg = "&#9888;&#65039; Could not update model from selection. Please try <code>/models</code> again."
                            Send-TelegramTextDeterministic -BotToken $botToken -ChatId $ChatId -Text $errMsg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
                        } catch {}
                    }
                    continue
                }

                Write-Host "Received callback_query id=$callbackId data='$callbackData'"
                continue
            }

            if ($u.message) {
                $chat = "$($u.message.chat.id)"
                if ($chat -ne "$ChatId") { continue }
                if (-not (Test-IsUpdateRecent -UnixDate $u.message.date -WindowMinutes $RecentReactionWindowMinutes)) {
                    Write-Host "Ignored stale message update_id=$($u.update_id)."
                    continue
                }

                if ($u.message.text) {
                    $text = "$($u.message.text)".Trim()

                    $pending = Get-SearchPendingEditForChat -ChatId "$ChatId"
                    if ($pending -and -not [string]::IsNullOrWhiteSpace("$text") -and -not $text.StartsWith('/')) {
                        try {
                            $pendingKey = "$($pending.key)".Trim()
                            $pendingMode = "$($pending.mode)".Trim().ToLowerInvariant()
                            Apply-SearchConfigEdit -Key $pendingKey -Mode $pendingMode -RawValue $text | Out-Null

                            $cfgAfter = Get-SearchConfigObject
                            $current = Get-SearchConfigKeyCurrentValueText -Config $cfgAfter -Key $pendingKey
                            $keyEsc = [System.Security.SecurityElement]::Escape($pendingKey)
                            $modeEsc = [System.Security.SecurityElement]::Escape($pendingMode)
                            $currentEsc = [System.Security.SecurityElement]::Escape($current)

                            $msg = "&#9989; Updated <code>$keyEsc</code> using mode <code>$modeEsc</code>.`nCurrent value: <code>$currentEsc</code>"
                            Send-TelegramTextDeterministic -BotToken $botToken -ChatId $ChatId -Text $msg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
                        } catch {
                            Write-Host "Failed to apply pending search config edit: $_"
                            try {
                                $err = [System.Security.SecurityElement]::Escape("$($_.Exception.Message)")
                                $msg = "&#9888;&#65039; Pending edit failed: <code>$err</code>"
                                Send-TelegramTextDeterministic -BotToken $botToken -ChatId $ChatId -Text $msg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
                            } catch {}
                        }
                        continue
                    }

                    if ($text -eq '/mode_status' -or $text -like '/mode_status@*') {
                        try {
                            $mode = Get-SearchRuntimeMode
                            $modeEsc = [System.Security.SecurityElement]::Escape($mode)
                            $msg = "&#9881;&#65039; <b>Search runtime mode</b>: <code>$modeEsc</code>`nUse <code>/mode_cli</code> or <code>/mode_agent</code> to switch."
                            Send-TelegramTextDeterministic -BotToken $botToken -ChatId $ChatId -Text $msg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
                        } catch {
                            Write-Host "Failed to handle /mode_status command: $_"
                        }
                        continue
                    }

                    if ($text -eq '/mode_cli' -or $text -like '/mode_cli@*') {
                        try {
                            Set-SearchRuntimeModeInConfig -Mode 'cli'
                            $msg = '&#9989; Runtime mode switched to <b>cli</b>. Aliases <code>/search</code> and <code>/search_start</code> now run direct CLI automation.'
                            Send-TelegramTextDeterministic -BotToken $botToken -ChatId $ChatId -Text $msg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
                        } catch {
                            Write-Host "Failed to handle /mode_cli command: $_"
                        }
                        continue
                    }

                    if ($text -eq '/mode_agent' -or $text -like '/mode_agent@*') {
                        try {
                            Set-SearchRuntimeModeInConfig -Mode 'agent'
                            $msg = '&#9989; Runtime mode switched to <b>agent</b>. Aliases <code>/search</code> and <code>/search_start</code> now point to agent-guided behavior.'
                            Send-TelegramTextDeterministic -BotToken $botToken -ChatId $ChatId -Text $msg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
                        } catch {
                            Write-Host "Failed to handle /mode_agent command: $_"
                        }
                        continue
                    }

                    if ($text -eq '/search_agent' -or $text -like '/search_agent@*') {
                        try {
                            $msg = "&#129302; <b>Agent-filtered mode</b>`nThis mode is handled by your OpenClaw agent runtime and may return AI summaries.`nUse <code>/search_cli</code> for direct CLI automation with per-job notifications."
                            Send-TelegramTextDeterministic -BotToken $botToken -ChatId $ChatId -Text $msg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
                        } catch {
                            Write-Host "Failed to handle /search_agent command: $_"
                        }
                        continue
                    }

                    if ($text -eq '/search_cli' -or $text -like '/search_cli@*') {
                        try {
                            $result = Invoke-SearchPipeline -Trigger 'manual_cli_command' -BotToken $botToken -ChatId $ChatId
                            $safe = [System.Security.SecurityElement]::Escape($result.message)
                            $prefix = if ($result.ok) { '&#9989;' } else { '&#9888;&#65039;' }
                            $msg = "$prefix <b>CLI search run result</b>`n<code>$safe</code>"
                            Send-TelegramTextDeterministic -BotToken $botToken -ChatId $ChatId -Text $msg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
                        } catch {
                            Write-Host "Failed to handle /search_cli command: $_"
                        }
                        continue
                    }

                    if ($text -eq '/search' -or $text -like '/search@*' -or $text -eq '/search_start' -or $text -like '/search_start@*') {
                        $mode = Get-SearchRuntimeMode
                        if ($mode -eq 'agent') {
                            try {
                                $msg = "&#129302; <b>Agent mode is active</b>.`nUse <code>/search_agent</code> for agent-filtered behavior, or switch mode with <code>/mode_cli</code> to run direct CLI automation from aliases."
                                Send-TelegramTextDeterministic -BotToken $botToken -ChatId $ChatId -Text $msg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
                            } catch {
                                Write-Host "Failed to handle /search alias in agent mode: $_"
                            }
                            continue
                        }

                        try {
                            $result = Invoke-SearchPipeline -Trigger 'manual_cli_alias' -BotToken $botToken -ChatId $ChatId
                            $safe = [System.Security.SecurityElement]::Escape($result.message)
                            $prefix = if ($result.ok) { '&#9989;' } else { '&#9888;&#65039;' }
                            $msg = "$prefix <b>CLI search run result</b>`n<code>$safe</code>"
                            Send-TelegramTextDeterministic -BotToken $botToken -ChatId $ChatId -Text $msg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
                        } catch {
                            Write-Host "Failed to handle /search alias command: $_"
                        }
                        continue
                    }

                    if ($text -eq '/search_stop' -or $text -like '/search_stop@*') {
                        try {
                            $state = Get-SearchSchedulerState
                            $state.enabled = $false
                            $state.next_run_utc = $null
                            Save-SearchSchedulerState -State $state
                            $msg = '&#9209; Auto job-search scheduler stopped.'
                            Send-TelegramTextDeterministic -BotToken $botToken -ChatId $ChatId -Text $msg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
                        } catch {
                            Write-Host "Failed to handle /search_stop command: $_"
                        }
                        continue
                    }

                    if ($text -eq '/search_config' -or $text -like '/search_config@*') {
                        try {
                            $msg = Get-SearchConfigStatusMessage
                            $kb = Get-SearchConfigEditKeyboardMarkup
                            Send-TelegramTextWithReplyMarkupDeterministic -BotToken $botToken -ChatId $ChatId -Text $msg -ReplyMarkup $kb -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
                        } catch {
                            Write-Host "Failed to handle /search_config command: $_"
                        }
                        continue
                    }

                    if ($text -eq '/search_timer' -or $text -like '/search_timer@*' -or $text -like '/search_timer *' -or $text -like '/search_timer@* *') {
                        try {
                            $commandText = $text
                            if ($commandText -like '/search_timer@* *') {
                                $commandText = ($commandText -replace '^/search_timer@[^\s]+\s+', '/search_timer ')
                            } elseif ($commandText -like '/search_timer@*') {
                                $commandText = '/search_timer'
                            }

                            $arg = ''
                            if ($commandText -match '^/search_timer\s+(.+)$') {
                                $arg = "$($matches[1])".Trim()
                            }

                            if ([string]::IsNullOrWhiteSpace($arg)) {
                                $state = Get-SearchSchedulerState
                                $enabled = if ([bool]$state.enabled) { 'enabled' } else { 'disabled' }
                                $nextRun = if ($state.next_run_utc) { "$($state.next_run_utc)" } else { 'n/a' }
                                $msg = "&#9201; <b>Auto search scheduler</b>`nstatus: <b>$enabled</b>`ninterval_seconds: <code>$($state.interval_seconds)</code>`nnext_run_utc: <code>$([System.Security.SecurityElement]::Escape($nextRun))</code>`nUsage: <code>/search_timer 6h</code> or <code>/search_timer 2d</code>"
                                Send-TelegramTextDeterministic -BotToken $botToken -ChatId $ChatId -Text $msg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
                                continue
                            }

                            $intervalSeconds = Parse-SearchTimerIntervalSeconds -InputText $arg
                            $state = Get-SearchSchedulerState
                            $state.enabled = $true
                            $state.interval_seconds = $intervalSeconds
                            $state.next_run_utc = (Get-Date).ToUniversalTime().AddSeconds($intervalSeconds).ToString('o')
                            $state.last_error = ''
                            Save-SearchSchedulerState -State $state

                            $msg = "&#9989; Auto search timer set to <code>$arg</code> (<code>$intervalSeconds</code> seconds). Next run at <code>$([System.Security.SecurityElement]::Escape($state.next_run_utc))</code>."
                            Send-TelegramTextDeterministic -BotToken $botToken -ChatId $ChatId -Text $msg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
                        } catch {
                            Write-Host "Failed to handle /search_timer command: $_"
                            try {
                                $msg = "&#9888;&#65039; Failed to set timer. Use <code>/search_timer 6h</code> or <code>/search_timer 2d</code>."
                                Send-TelegramTextDeterministic -BotToken $botToken -ChatId $ChatId -Text $msg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
                            } catch {}
                        }
                        continue
                    }

                    if ($text -eq '/search_set' -or $text -like '/search_set@*' -or $text -like '/search_set *' -or $text -like '/search_set@* *') {
                        try {
                            $commandText = $text
                            if ($commandText -like '/search_set@* *') {
                                $commandText = ($commandText -replace '^/search_set@[^\s]+\s+', '/search_set ')
                            } elseif ($commandText -like '/search_set@*') {
                                $commandText = '/search_set'
                            }

                            if ($commandText -notmatch '^/search_set\s+(?<key>\S+)\s+(?<value>.+)$') {
                                $usage = "&#8505;&#65039; Choose a field to edit. Then choose replace/add/remove and send value as next message, or use direct syntax.`n<code>/search_set &lt;key&gt; &lt;value&gt;</code>"
                                $kb = Get-SearchConfigEditKeyboardMarkup
                                Send-TelegramTextWithReplyMarkupDeterministic -BotToken $botToken -ChatId $ChatId -Text $usage -ReplyMarkup $kb -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
                                continue
                            }

                            $key = "$($matches['key'])".Trim()
                            $value = "$($matches['value'])".Trim()
                            Set-SearchConfigValue -Key $key -RawValue $value | Out-Null

                            $msg = "&#9989; Updated <code>$([System.Security.SecurityElement]::Escape($key))</code> to <code>$([System.Security.SecurityElement]::Escape($value))</code>."
                            Send-TelegramTextDeterministic -BotToken $botToken -ChatId $ChatId -Text $msg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
                        } catch {
                            Write-Host "Failed to handle /search_set command: $_"
                            try {
                                $safeErr = [System.Security.SecurityElement]::Escape("$($_.Exception.Message)")
                                $msg = "&#9888;&#65039; Failed to update config: <code>$safeErr</code>"
                                Send-TelegramTextDeterministic -BotToken $botToken -ChatId $ChatId -Text $msg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
                            } catch {}
                        }
                        continue
                    }

                    if ($text -eq '/open_tasks' -or $text -like '/open_tasks@*') {
                        try {
                            $msg = Get-OpenTaskStatusesMessage -TrackerPath $trackerPath
                            Send-TelegramTextDeterministic -BotToken $botToken -ChatId $ChatId -Text $msg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
                        } catch {
                            Write-Host "Failed to send /open_tasks response: $_"
                        }
                        continue
                    }

                    if ($text -eq '/jobs' -or $text -like '/jobs@*') {
                        try {
                            $msg = Get-CompactJobsMessage -TrackerPath $trackerPath -MaxRows 15
                            Send-TelegramTextDeterministic -BotToken $botToken -ChatId $ChatId -Text $msg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
                        } catch {
                            Write-Host "Failed to send /jobs response: $_"
                        }
                        continue
                    }

                    if ($text -eq '/log' -or $text -like '/log@*') {
                        try {
                            $msg = Get-RecentSystemLogsMessage -TailLines 20
                            Send-TelegramTextDeterministic -BotToken $botToken -ChatId $ChatId -Text $msg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
                        } catch {
                            Write-Host "Failed to send /log response: $_"
                        }
                        continue
                    }

                    if ($text -eq '/paths' -or $text -like '/paths@*') {
                        try {
                            $msg = Get-OpenClawPathsMessage
                            Send-TelegramTextDeterministic -BotToken $botToken -ChatId $ChatId -Text $msg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
                        } catch {
                            Write-Host "Failed to send /paths response: $_"
                        }
                        continue
                    }

                    if ($text -eq '/models' -or $text -like '/models@*') {
                        try {
                            $activeId = Get-ActiveModelForChat -ChatId "$ChatId"
                            $activeLabel = Get-ModelLabelById -ModelId $activeId
                            $activeLabelEsc = [System.Security.SecurityElement]::Escape($activeLabel)
                            $activeIdEsc = [System.Security.SecurityElement]::Escape($activeId)
                            $msg = "&#129504; <b>Select active model</b>`nCurrent: <b>$activeLabelEsc</b> (<code>$activeIdEsc</code>)"
                            $kb = Get-ModelsKeyboardMarkup -ChatId "$ChatId"
                            Send-TelegramTextWithReplyMarkupDeterministic -BotToken $botToken -ChatId $ChatId -Text $msg -ReplyMarkup $kb -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
                        } catch {
                            Write-Host "Failed to send /models response: $_"
                        }
                        continue
                    }

                    if ($text -eq '/model' -or $text -like '/model@*' -or $text -like '/model *' -or $text -like '/model@* *') {
                        try {
                            $commandText = $text
                            if ($commandText -like '/model@* *') {
                                $commandText = ($commandText -replace '^/model@[^\s]+\s+', '/model ')
                            } elseif ($commandText -like '/model@*') {
                                $commandText = '/model'
                            }

                            $arg = ''
                            if ($commandText -match '^/model\s+(.+)$') {
                                $arg = "$($matches[1])".Trim()
                            }

                            if ([string]::IsNullOrWhiteSpace($arg) -or $arg.ToLowerInvariant() -eq 'status') {
                                $statusMsg = Get-ModelStatusMessage -ChatId "$ChatId"
                                Send-TelegramTextDeterministic -BotToken $botToken -ChatId $ChatId -Text $statusMsg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
                                continue
                            }

                            $resolvedModel = Resolve-ModelInput -RawInput $arg
                            if (-not $resolvedModel) {
                                $hint = "&#9888;&#65039; Unknown model: <code>$([System.Security.SecurityElement]::Escape($arg))</code>`nUse <code>/models</code> to choose, or <code>/model status</code>."
                                Send-TelegramTextDeterministic -BotToken $botToken -ChatId $ChatId -Text $hint -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
                                continue
                            }

                            Set-ActiveModelForChat -ChatId "$ChatId" -ModelId $resolvedModel
                            $label = Get-ModelLabelById -ModelId $resolvedModel
                            $labelEsc = [System.Security.SecurityElement]::Escape($label)
                            $idEsc = [System.Security.SecurityElement]::Escape($resolvedModel)
                            $msg = "&#9989; Active model set to <b>$labelEsc</b>`n<code>$idEsc</code>"
                            Send-TelegramTextDeterministic -BotToken $botToken -ChatId $ChatId -Text $msg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
                        } catch {
                            Write-Host "Failed to handle /model command: $_"
                        }
                        continue
                    }
                }

                # Fallback: user replies with thumbs-up to a specific job message
                if ($u.message.text -and "$($u.message.text)".Trim() -eq $thumbsUpEmoji -and $u.message.reply_to_message) {
                    $replyMessageId = "$($u.message.reply_to_message.message_id)"
                    $replyMapRow = Get-MessageMapRow -ChatId "$ChatId" -MessageId $replyMessageId
                    if (-not (Test-IsMappedMessageRecent -MapRow $replyMapRow -WindowMinutes $RecentMappedMessageWindowMinutes)) {
                        Write-Host "Ignored reply reaction on old mapped message_id=$replyMessageId (outside recent mapped-message window)."
                        continue
                    }
                    $jobId = Get-JobIdByTelegramMessageId -ChatId "$ChatId" -MessageId $replyMessageId
                    if ($jobId) {
                        Write-Host "Reply thumbs-up mapped to job_id=$jobId (reply_message_id=$replyMessageId)."
                        Start-CvGenerationForJob -JobId $jobId -BotToken $botToken -ChatId $ChatId
                    }
                }
            }
        }
    }

    if ($Once) {
        break
    }

    try {
        Try-RunScheduledSearch -BotToken $botToken -ChatId $ChatId
    } catch {
        Write-Host "Scheduled search execution error: $_"
    }

    Start-Sleep -Seconds $PollIntervalSeconds
}

Write-Host 'Telegram reaction listener finished.'
