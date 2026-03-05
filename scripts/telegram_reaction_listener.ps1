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
$invalidReactionCooldownSeconds = 120
$script:InvalidReactionNoticeCache = @{}

Initialize-JobTracker -TrackerPath $trackerPath

$thumbsUpEmoji = [char]::ConvertFromUtf32(0x1F44D)
$rocketEmoji = [char]::ConvertFromUtf32(0x1F680)

function Get-Offset {
    if (Test-Path $offsetPath) {
        $v = Get-Content $offsetPath -Raw -Encoding UTF8
        if ($v -match '^\d+$') { return [int64]$v }
    }
    return 0
}

function Save-Offset {
    param([int64]$Offset)
    Set-Content -Path $offsetPath -Value "$Offset" -Encoding UTF8
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
        [Parameter(Mandatory=$true)]$MapRow,
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
        [bool]$SkipBacklog = $true
    )

    if (-not $SkipBacklog) {
        return
    }

    try {
        $allowedUpdates = [System.Uri]::EscapeDataString('["message","message_reaction"]')
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

    try {
        Set-JobStatus -TrackerPath $trackerPath -JobId $JobId -NewStatus 'CV_Generating' -Reason 'Triggered by Telegram thumbs-up reaction'
    } catch {
        Write-Host "Failed state transition to CV_Generating for '$JobId': $_"
        try {
            $msg = "&#9888;&#65039; Could not start CV generation for <b>$JobId</b>: state transition failed."
            Send-TelegramTextDeterministic -BotToken $BotToken -ChatId $ChatId -Text $msg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
        } catch {}
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

    $desc = if ($job.description) { "$($job.description)" } else { "Role: $($job.title)`nCompany: $($job.company)`nLocation: $($job.location)`nLink: $($job.job_url)" }
    $jobDescPath = Join-Path $workspaceRoot 'current_job_desc.txt'
    Set-Content -Path $jobDescPath -Value $desc -Encoding UTF8

    $cvPath = Get-NextCvPath -JobId $JobId

    try {
        Push-Location $workspaceRoot
        & node dist/cli.js generate --profile profile.md --job current_job_desc.txt --out "$cvPath" --theme modern
        $exitCode = $LASTEXITCODE
        Pop-Location

        if ($exitCode -ne 0 -or -not (Test-Path $cvPath)) {
            throw "CV generation command failed (exit=$exitCode)."
        }

        $caption = "CV draft generated for Job ID: $JobId`nPlease review manually.`nReact with $rocketEmoji only after approval."
        Send-TelegramDocumentDeterministic -BotToken $BotToken -ChatId $ChatId -FilePath $cvPath -Caption $caption -MaxRetries 3 -RetryDelaySeconds 2 | Out-Null

        Set-JobStatus -TrackerPath $trackerPath -JobId $JobId -NewStatus 'CV_Ready_For_Review' -Reason 'Draft CV sent to Telegram for manual review' -FieldUpdates @{ latest_cv_path = $cvPath; last_error = '' }
        Write-DispatchLog -JobId $JobId -Status 'CV_Ready_For_Review' -Reason 'cv_sent_for_manual_review'
        return $true
    } catch {
        try {
            Set-JobStatus -TrackerPath $trackerPath -JobId $JobId -NewStatus 'Apply_Failed' -Reason 'CV generation/send failed' -FieldUpdates @{ last_error = "$_" }
        } catch {}
        Write-DispatchLog -JobId $JobId -Status 'Apply_Failed' -Reason 'cv_generation_or_send_failed'
        Write-Host "CV generation flow failed for '$JobId': $_"
        return $false
    } finally {
        if (Test-Path $jobDescPath) {
            Remove-Item $jobDescPath -ErrorAction SilentlyContinue
        }
    }
}

function Get-JobTrackerRow {
    param([Parameter(Mandatory=$true)][string]$JobId)

    $rows = Get-TrackerRows -TrackerPath $trackerPath
    return $rows | Where-Object { "$($_.job_id)" -eq "$JobId" } | Select-Object -First 1
}

function Get-AllowedEmojiForStatus {
    param([Parameter(Mandatory=$true)][string]$Status)

    switch ($Status) {
        'Sent' { return @('thumbs_up') }
        'CV_Revision_Requested' { return @('thumbs_up') }
        'CV_Ready_For_Review' { return @('rocket') }
        'Approved_For_Apply' { return @('rocket') }
        default { return @() }
    }
}

function Convert-EmojiKeyToHtml {
    param([Parameter(Mandatory=$true)][string]$EmojiKey)

    switch ($EmojiKey) {
        'thumbs_up' { return '&#128077;' }
        'rocket' { return '&#128640;' }
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
        'CV_Ready_For_Review' { 'Review the draft, then use &#128640; to continue apply flow.' }
        'CV_Revision_Requested' { 'Use &#128077; to generate the revised CV draft.' }
        'Approved_For_Apply' { 'Use &#128640; to continue apply flow.' }
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

function Get-OpenClawPathsMessage {
    $home = [Environment]::GetFolderPath('UserProfile')
    $defaultRoot = Join-Path $home '.openclaw'

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

$botToken = Get-TelegramBotToken -WorkspaceRoot $workspaceRoot
if (-not $botToken) {
    Write-Host 'TELEGRAM_BOT_TOKEN not found in .env or environment.'
    exit 1
}

Ensure-InvalidNoticeLogFile

try {
    $requiredMenuCommands = @(
        @{ command = 'start'; description = 'Initialize chat and show current status' },
        @{ command = 'restart'; description = 'Hot-restart the agent' },
        @{ command = 'status'; description = 'Show gateway/skills/model status' },
        @{ command = 'stop'; description = 'Stop current agent run' },
        @{ command = 'paths'; description = 'Show OpenClaw config/state/workspace paths' },
        @{ command = 'search'; description = 'Run jobs search flow' },
        @{ command = 'jobs'; description = 'Show latest jobs summary' },
        @{ command = 'profile'; description = 'Show active profile information' },
        @{ command = 'help'; description = 'List available commands' },
        @{ command = 'log'; description = 'Show recent logs' },
        @{ command = 'models'; description = 'List available OpenClaw models' },
        @{ command = 'model'; description = 'Show or set active OpenClaw model' },
        @{ command = 'open_tasks'; description = 'Show all non-closed tasks' }
    )

    function Merge-OpenTasksCommand {
        param(
            [Parameter(Mandatory=$true)]$ExistingCommands
        )

        $merged = @()
        if ($ExistingCommands) {
            $merged += @($ExistingCommands)
        }

        foreach ($required in $requiredMenuCommands) {
            $cmdName = "$($required.command)"
            $exists = @($merged | Where-Object { "$($_.command)" -eq $cmdName }).Count -gt 0
            if (-not $exists) {
                $merged += [PSCustomObject]@{
                    command = "$($required.command)"
                    description = "$($required.description)"
                }
            }
        }

        return @($merged)
    }

    $defaultCommands = Get-TelegramBotCommandsDeterministic -BotToken $botToken
    $defaultMerged = Merge-OpenTasksCommand -ExistingCommands $defaultCommands
    Set-TelegramBotCommandsDeterministic -BotToken $botToken -Commands $defaultMerged | Out-Null

    $privateScope = @{ type = 'all_private_chats' }
    $privateCommands = Get-TelegramBotCommandsDeterministic -BotToken $botToken -Scope $privateScope
    $privateMerged = Merge-OpenTasksCommand -ExistingCommands $privateCommands
    Set-TelegramBotCommandsDeterministic -BotToken $botToken -Commands $privateMerged -Scope $privateScope | Out-Null

    Write-Host 'Registered Telegram bot menu commands with merge strategy (default/private scopes)'
} catch {
    Write-Host "Failed to register Telegram bot menu commands: $_"
}

Initialize-OffsetFromLatestUpdates -BotToken $botToken -SkipBacklog $SkipBacklogOnStart

Write-Host "Starting Telegram reaction listener (chat_id=$ChatId, once=$Once, skipBacklogOnStart=$SkipBacklogOnStart)"

while ($true) {
    $offset = Get-Offset
    $allowedUpdates = [System.Uri]::EscapeDataString('["message","message_reaction"]')
    $uri = "https://api.telegram.org/bot$botToken/getUpdates?timeout=20&offset=$offset&allowed_updates=$allowedUpdates"

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
                } elseif ($emojiSet -contains $rocketEmoji) {
                    # Apply-by-reaction flow is not fully implemented yet; provide status-aware guidance only.
                    $noticeType = 'invalid_rocket'
                    if (Has-InvalidNoticeBeenSent -JobId $jobId -NoticeType $noticeType) {
                        Write-Host "Skipped duplicate invalid notice for job_id=$jobId type=$noticeType."
                        continue
                    }
                    if (
                        (Should-SendInvalidReactionNotice -JobId $jobId -Status $currentStatus -EmojiKey 'rocket' -CooldownSeconds $invalidReactionCooldownSeconds)
                    ) {
                        try {
                            Send-InvalidReactionGuidance -JobId $jobId -CurrentStatus $currentStatus -EmojiKey 'rocket' -BotToken $botToken -ChatId $ChatId
                            Register-InvalidNoticeSent -JobId $jobId -NoticeType $noticeType
                        } catch {}
                    }
                }
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
                    if ($text -eq '/open_tasks' -or $text -like '/open_tasks@*') {
                        try {
                            $msg = Get-OpenTaskStatusesMessage -TrackerPath $trackerPath
                            Send-TelegramTextDeterministic -BotToken $botToken -ChatId $ChatId -Text $msg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
                        } catch {
                            Write-Host "Failed to send /open_tasks response: $_"
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

    Start-Sleep -Seconds $PollIntervalSeconds
}

Write-Host 'Telegram reaction listener finished.'
