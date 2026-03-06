param(
    [int]$MessageCount = 3,
    [string]$ChatId = '5225138885',
    [int]$ListenerWarmupSeconds = 5,
    [int]$ObservationSeconds = 20,
    [switch]$SkipBuild,
    [switch]$SkipSendMessages,
    [switch]$SkipAutoCvTrigger,
    [string]$ModelId = 'google/gemini-2.5-pro'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$workspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$reportsDir = Join-Path $workspaceRoot 'tests/reports'
if (-not (Test-Path $reportsDir)) {
    New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null
}

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$reportBase = "phaseA_smoke_$timestamp"
$reportJsonPath = Join-Path $reportsDir "$reportBase.json"
$reportMdPath = Join-Path $reportsDir "$reportBase.md"
$listenerStdoutPath = Join-Path $reportsDir "$reportBase.listener.out.log"
$listenerStderrPath = Join-Path $reportsDir "$reportBase.listener.err.log"
$sendLogPath = Join-Path $reportsDir "$reportBase.send.log"
$workerLogPath = Join-Path $reportsDir "$reportBase.worker.log"

$listenerScript = Join-Path $workspaceRoot 'scripts/telegram_reaction_listener.ps1'
$sendScript = Join-Path $workspaceRoot 'scripts/telegram_send_test_messages.ps1'
$workerScript = Join-Path $workspaceRoot 'scripts/telegram_cv_generation_worker.ps1'
$trackerPath = Join-Path $workspaceRoot 'job_tracker.csv'
$dispatchLogPath = Join-Path $workspaceRoot 'memory/telegram_dispatch.log'
$messageMapPath = Join-Path $workspaceRoot 'memory/telegram_message_map.csv'
$invalidNoticeLogPath = Join-Path $workspaceRoot 'memory/telegram_invalid_notice_log.csv'
$offsetPath = Join-Path $workspaceRoot 'memory/telegram_update_offset.txt'
$profilePath = Join-Path $workspaceRoot 'profile.md'
$cliPath = Join-Path $workspaceRoot 'dist/cli.js'
$dotenvPath = Join-Path $workspaceRoot '.env'

$steps = New-Object System.Collections.Generic.List[object]
$runStart = Get-Date

. (Join-Path $workspaceRoot 'scripts/job_state_machine.ps1')
. (Join-Path $workspaceRoot 'scripts/telegram_interface.ps1')
Initialize-JobTracker -TrackerPath $trackerPath

function Add-Step {
    param(
        [string]$Name,
        [string]$Status,
        [string]$Details
    )

    $steps.Add([PSCustomObject]@{
        name = $Name
        status = $Status
        details = $Details
        timestamp = (Get-Date).ToString('o')
    }) | Out-Null
}

function Test-CommandExists {
    param([string]$Name)
    try { return $null -ne (Get-Command $Name -ErrorAction Stop) } catch { return $false }
}

function Get-PreferredPsHost {
    foreach ($candidate in @('powershell.exe', 'pwsh.exe', 'pwsh')) {
        try {
            $cmd = Get-Command $candidate -ErrorAction Stop
            if ($cmd -and $cmd.Source) { return "$($cmd.Source)" }
        } catch {}
    }
    throw 'No PowerShell host found (powershell.exe/pwsh.exe/pwsh).'
}

function Get-DotEnvValue {
    param(
        [string]$EnvPath,
        [string]$Key
    )

    if (-not (Test-Path $EnvPath)) { return '' }

    $pattern = "^\s*" + [regex]::Escape($Key) + "\s*=\s*(.*)\s*$"
    foreach ($line in Get-Content -Path $EnvPath -Encoding UTF8) {
        if ($line -match $pattern) {
            $val = "$($matches[1])".Trim()
            if (($val.StartsWith('"') -and $val.EndsWith('"')) -or ($val.StartsWith("'") -and $val.EndsWith("'"))) {
                $val = $val.Substring(1, $val.Length - 2)
            }
            return $val
        }
    }

    return ''
}

function Get-RecentRows {
    param(
        [Parameter(Mandatory=$true)]$Rows,
        [Parameter(Mandatory=$true)][datetime]$Since
    )

    return @($Rows | Where-Object {
        try {
            $created = [datetime]::Parse("$($_.created_at)")
            return $created -ge $Since
        } catch {
            return $false
        }
    })
}

function Get-FileTailSafe {
    param(
        [string]$Path,
        [int]$LineCount = 50
    )

    if (-not (Test-Path $Path)) { return @("<missing>") }
    try {
        return @(Get-Content -Path $Path -Tail $LineCount -Encoding UTF8)
    } catch {
        return @("<read_error> $($_.Exception.Message)")
    }
}

function Stop-ProcessSafe {
    param([System.Diagnostics.Process]$Proc)

    if ($null -eq $Proc) { return }
    try {
        if (-not $Proc.HasExited) {
            Stop-Process -Id $Proc.Id -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

Write-Host "== Phase A Smoke Test Runner (Automatic) ==" -ForegroundColor Cyan
Write-Host "Workspace: $workspaceRoot"
Write-Host "Reports:   $reportsDir"
Write-Host ''

$psHost = $null
$listenerProc = $null
$workerProcessIdsBefore = @()
$logBundle = $null

try {
    $psHost = Get-PreferredPsHost
    Add-Step -Name 'ps_host_detect' -Status 'pass' -Details "Using PowerShell host: $psHost"

    $nodeExists = Test-CommandExists -Name 'node'
    $npmExists = Test-CommandExists -Name 'npm'
    $profileExists = Test-Path $profilePath
    $cliExists = Test-Path $cliPath

    $geminiKey = [Environment]::GetEnvironmentVariable('GEMINI_API_KEY')
    if ([string]::IsNullOrWhiteSpace("$geminiKey")) {
        $geminiKey = Get-DotEnvValue -EnvPath $dotenvPath -Key 'GEMINI_API_KEY'
    }

    $telegramToken = [Environment]::GetEnvironmentVariable('TELEGRAM_BOT_TOKEN')
    if ([string]::IsNullOrWhiteSpace("$telegramToken")) {
        $telegramToken = Get-DotEnvValue -EnvPath $dotenvPath -Key 'TELEGRAM_BOT_TOKEN'
    }

    $preflightFailures = @()
    if (-not $nodeExists) { $preflightFailures += 'node not found in PATH' }
    if (-not $npmExists) { $preflightFailures += 'npm not found in PATH' }
    if (-not $profileExists) { $preflightFailures += 'profile.md missing' }
    if (-not $cliExists) { $preflightFailures += 'dist/cli.js missing (run build)' }
    if ([string]::IsNullOrWhiteSpace("$geminiKey")) { $preflightFailures += 'GEMINI_API_KEY missing (env/.env)' }
    if ([string]::IsNullOrWhiteSpace("$telegramToken")) { $preflightFailures += 'TELEGRAM_BOT_TOKEN missing (env/.env)' }

    if ($preflightFailures.Count -gt 0) {
        Add-Step -Name 'preflight_checks' -Status 'fail' -Details ($preflightFailures -join '; ')
        throw "Preflight failed: $($preflightFailures -join '; ')"
    }

    Add-Step -Name 'preflight_checks' -Status 'pass' -Details 'All required prerequisites were found.'

    if (-not $SkipBuild) {
        Push-Location $workspaceRoot
        try {
            npm run build | Out-Host
            Add-Step -Name 'build' -Status 'pass' -Details 'npm run build completed.'
        } finally {
            Pop-Location
        }
    } else {
        Add-Step -Name 'build' -Status 'skip' -Details 'Skipped by flag.'
    }

    try {
        $workerProcessIdsBefore = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { "$($_.CommandLine)" -match 'telegram_cv_generation_worker\.ps1' } | ForEach-Object { [int]$_.ProcessId })
    } catch {
        $workerProcessIdsBefore = @()
    }

    if (Test-Path $listenerScript) {
        $listenerArgs = @('-NoProfile', '-File', $listenerScript, '-PollIntervalSeconds', '2')
        $listenerProc = Start-Process -FilePath $psHost -ArgumentList $listenerArgs -PassThru -WindowStyle Hidden -RedirectStandardOutput $listenerStdoutPath -RedirectStandardError $listenerStderrPath
        Add-Step -Name 'listener_start' -Status 'pass' -Details "Started listener process id=$($listenerProc.Id)"
        Start-Sleep -Seconds $ListenerWarmupSeconds
    } else {
        Add-Step -Name 'listener_start' -Status 'fail' -Details "Missing listener script: $listenerScript"
    }

    if (-not $SkipSendMessages -and (Test-Path $sendScript)) {
        & $sendScript -ChatId $ChatId -Count $MessageCount 2>&1 | Tee-Object -FilePath $sendLogPath | Out-Host
        Add-Step -Name 'send_test_messages' -Status 'pass' -Details "Sent $MessageCount messages to chat $ChatId"
    } else {
        Add-Step -Name 'send_test_messages' -Status 'skip' -Details 'Skipped by flag or missing script.'
    }

    if (-not $SkipAutoCvTrigger -and (Test-Path $workerScript)) {
        $rows = Get-TrackerRows -TrackerPath $trackerPath
        $recentRows = Get-RecentRows -Rows $rows -Since $runStart
        $target = @($recentRows | Where-Object { "$($_.source)" -eq 'telegram_test_sender' -and "$($_.status)" -eq 'Sent' } | Sort-Object { $_.created_at } -Descending | Select-Object -First 1)

        if ($target.Count -gt 0) {
            $jobId = "$($target[0].job_id)"
            try {
                Set-JobStatus -TrackerPath $trackerPath -JobId $jobId -NewStatus 'CV_Generating' -Reason 'Automated smoke test trigger'
            } catch {
                # no-op if already transitioned by real reaction
            }

            $workerArgs = @('-NoProfile', '-File', $workerScript, '-JobId', $jobId, '-BotToken', $telegramToken, '-ChatId', $ChatId, '-ModelId', $ModelId)
            & $psHost @workerArgs 2>&1 | Tee-Object -FilePath $workerLogPath | Out-Host

            $exitCode = $LASTEXITCODE
            if ($exitCode -eq 0) {
                Add-Step -Name 'auto_cv_trigger' -Status 'pass' -Details "Worker completed for job_id=$jobId"
            } else {
                Add-Step -Name 'auto_cv_trigger' -Status 'fail' -Details "Worker failed for job_id=$jobId (exit=$exitCode)"
            }
        } else {
            Add-Step -Name 'auto_cv_trigger' -Status 'fail' -Details 'No recent Sent test job found to trigger worker.'
        }
    } else {
        Add-Step -Name 'auto_cv_trigger' -Status 'skip' -Details 'Skipped by flag or missing worker script.'
    }

    Start-Sleep -Seconds $ObservationSeconds

    $rowsAfter = Get-TrackerRows -TrackerPath $trackerPath
    $recentAfter = Get-RecentRows -Rows $rowsAfter -Since $runStart
    $summary = @(
        "recent_rows=$($recentAfter.Count)",
        "sent=$(@($recentAfter | Where-Object { \"$($_.status)\" -eq 'Sent' }).Count)",
        "generating=$(@($recentAfter | Where-Object { \"$($_.status)\" -eq 'CV_Generating' }).Count)",
        "ready=$(@($recentAfter | Where-Object { \"$($_.status)\" -eq 'CV_Ready_For_Review' }).Count)",
        "failed=$(@($recentAfter | Where-Object { \"$($_.status)\" -eq 'Apply_Failed' }).Count)"
    ) -join '; '
    Add-Step -Name 'status_snapshot' -Status 'info' -Details $summary

} catch {
    Add-Step -Name 'runner_exception' -Status 'fail' -Details $_.Exception.Message
} finally {
    # Pull logs BEFORE shutdown
    $logBundle = [PSCustomObject]@{
        listener_stdout_tail = (Get-FileTailSafe -Path $listenerStdoutPath -LineCount 80)
        listener_stderr_tail = (Get-FileTailSafe -Path $listenerStderrPath -LineCount 80)
        dispatch_tail = (Get-FileTailSafe -Path $dispatchLogPath -LineCount 80)
        message_map_tail = (Get-FileTailSafe -Path $messageMapPath -LineCount 80)
        invalid_notice_tail = (Get-FileTailSafe -Path $invalidNoticeLogPath -LineCount 80)
        offset_file = (Get-FileTailSafe -Path $offsetPath -LineCount 5)
        worker_log_tail = (Get-FileTailSafe -Path $workerLogPath -LineCount 80)
        send_log_tail = (Get-FileTailSafe -Path $sendLogPath -LineCount 80)
    }

    Add-Step -Name 'log_collection' -Status 'pass' -Details 'Collected listener/dispatch/message-map/worker logs before shutdown.'

    # Shutdown listener
    if ($listenerProc) {
        Stop-ProcessSafe -Proc $listenerProc
        Add-Step -Name 'listener_shutdown' -Status 'pass' -Details "Stopped listener process id=$($listenerProc.Id)"
    } else {
        Add-Step -Name 'listener_shutdown' -Status 'skip' -Details 'Listener process was not started.'
    }

    # Shutdown worker processes created during this run
    try {
        $workerProcessIdsAfter = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { "$($_.CommandLine)" -match 'telegram_cv_generation_worker\.ps1' } | ForEach-Object { [int]$_.ProcessId })
        $newWorkerProcessIds = @($workerProcessIdsAfter | Where-Object { $workerProcessIdsBefore -notcontains $_ })
        $newWorkerProcessIds | ForEach-Object {
            try { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue } catch {}
        }

        if ($newWorkerProcessIds.Count -gt 0) {
            Add-Step -Name 'worker_shutdown' -Status 'pass' -Details ("Stopped worker process IDs: " + ($newWorkerProcessIds -join ', '))
        } else {
            Add-Step -Name 'worker_shutdown' -Status 'skip' -Details 'No new worker processes detected for shutdown.'
        }
    } catch {
        Add-Step -Name 'worker_shutdown' -Status 'fail' -Details $_.Exception.Message
    }

    $report = [PSCustomObject]@{
        run_id = $reportBase
        created_at = (Get-Date).ToString('o')
        workspace = $workspaceRoot
        parameters = [PSCustomObject]@{
            MessageCount = $MessageCount
            ChatId = $ChatId
            ListenerWarmupSeconds = $ListenerWarmupSeconds
            ObservationSeconds = $ObservationSeconds
            SkipBuild = [bool]$SkipBuild
            SkipSendMessages = [bool]$SkipSendMessages
            SkipAutoCvTrigger = [bool]$SkipAutoCvTrigger
            ModelId = $ModelId
        }
        steps = $steps
        logs = $logBundle
    }

    $report | ConvertTo-Json -Depth 10 | Set-Content -Path $reportJsonPath -Encoding UTF8

    $md = @()
    $md += "# Phase A Smoke Test Report (Automatic)"
    $md += ""
    $md += "- Run ID: $reportBase"
    $md += "- Created: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
    $md += "- Workspace: $workspaceRoot"
    $md += ""
    $md += "## Step Results"
    $md += ""
    foreach ($s in $steps) {
        $md += "### $($s.name)"
        $md += "- Status: $($s.status)"
        $md += "- Details: $($s.details)"
        $md += ""
    }
    $md += "## Log Files"
    $md += "- Listener stdout: $listenerStdoutPath"
    $md += "- Listener stderr: $listenerStderrPath"
    $md += "- Sender log: $sendLogPath"
    $md += "- Worker log: $workerLogPath"

    $md -join "`n" | Set-Content -Path $reportMdPath -Encoding UTF8

    Write-Host ''
    Write-Host 'Smoke test completed (automatic).' -ForegroundColor Green
    Write-Host "JSON report: $reportJsonPath"
    Write-Host "MD report:   $reportMdPath"
}
