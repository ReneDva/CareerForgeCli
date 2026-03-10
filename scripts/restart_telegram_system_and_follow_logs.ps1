param(
    [string]$ChatId = '5225138885',
    [int]$PollIntervalSeconds = 3,
    [int]$StopVerificationTimeoutSeconds = 20,
    [int]$StartVerificationTimeoutSeconds = 25,
    [int]$TailRefreshSeconds = 1
)

$ErrorActionPreference = 'Stop'

$workspaceRoot = Join-Path $PSScriptRoot '..'
$stopScript = Join-Path $PSScriptRoot 'stop_telegram_listener_background.ps1'
$startScript = Join-Path $PSScriptRoot 'start_telegram_listener_background.ps1'

$listenerLogPath = Join-Path $workspaceRoot 'memory/telegram_listener_background.log'
$listenerErrLogPath = Join-Path $workspaceRoot 'memory/telegram_listener_background.err.log'
$dispatchLogPath = Join-Path $workspaceRoot 'memory/telegram_dispatch.log'

function Get-TelegramSystemProcesses {
    $patterns = @(
        'telegram_reaction_listener\.ps1',
        'telegram_cv_generation_worker\.ps1'
    )

    $all = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine }
    $matches = foreach ($p in $all) {
        foreach ($pat in $patterns) {
            if ($p.CommandLine -match $pat) {
                [PSCustomObject]@{
                    ProcessId = $p.ProcessId
                    Name = $p.Name
                    CommandLine = $p.CommandLine
                    Pattern = $pat
                }
                break
            }
        }
    }

    return @($matches)
}

function Wait-ForNoTelegramSystemProcesses {
    param([int]$TimeoutSeconds)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $left = Get-TelegramSystemProcesses
        if (-not $left -or $left.Count -eq 0) {
            return $true
        }
        Start-Sleep -Milliseconds 500
    }

    return $false
}

function Wait-ForListenerRunning {
    param([int]$TimeoutSeconds)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $running = Get-CimInstance Win32_Process |
            Where-Object { $_.CommandLine -and $_.CommandLine -match 'telegram_reaction_listener\.ps1' }

        if ($running -and @($running).Count -gt 0) {
            return @($running)
        }

        Start-Sleep -Milliseconds 500
    }

    return @()
}

function Ensure-FileExists {
    param([string]$Path)

    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if (-not (Test-Path $Path)) {
        New-Item -ItemType File -Path $Path -Force | Out-Null
    }
}

function Read-NewLogLines {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ref]$LastByteOffset,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not (Test-Path $Path)) {
        return
    }

    $info = Get-Item $Path -ErrorAction SilentlyContinue
    if (-not $info) {
        return
    }

    if ($info.Length -lt $LastByteOffset.Value) {
        $LastByteOffset.Value = 0L
    }

    if ($info.Length -eq $LastByteOffset.Value) {
        return
    }

    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $fs.Seek($LastByteOffset.Value, [System.IO.SeekOrigin]::Begin) | Out-Null
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        $newText = $sr.ReadToEnd()
        $LastByteOffset.Value = $fs.Position

        if (-not [string]::IsNullOrWhiteSpace($newText)) {
            $lines = $newText -split "`r?`n"
            foreach ($line in $lines) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                Write-Host "[$Label] $line"
            }
        }
    } finally {
        $fs.Dispose()
    }
}

if (-not (Test-Path $stopScript)) {
    throw "Missing stop script: $stopScript"
}
if (-not (Test-Path $startScript)) {
    throw "Missing start script: $startScript"
}

Write-Host '=== CareerForge Telegram System Restart ===' -ForegroundColor Cyan
Write-Host 'Step 1/4: Stopping existing Telegram-related processes...' -ForegroundColor Yellow

& $stopScript

$stopped = Wait-ForNoTelegramSystemProcesses -TimeoutSeconds $StopVerificationTimeoutSeconds
if (-not $stopped) {
    $leftovers = Get-TelegramSystemProcesses
    Write-Host '❌ Stop verification failed. Remaining processes:' -ForegroundColor Red
    $leftovers | Format-Table -AutoSize
    exit 2
}

Write-Host '✅ Stop verification passed: no Telegram listener/worker processes remain.' -ForegroundColor Green
Write-Host 'Step 2/4: Starting listener...' -ForegroundColor Yellow

& $startScript -ChatId $ChatId -PollIntervalSeconds $PollIntervalSeconds

$running = Wait-ForListenerRunning -TimeoutSeconds $StartVerificationTimeoutSeconds
if (-not $running -or $running.Count -eq 0) {
    Write-Host '❌ Start verification failed: listener process not detected.' -ForegroundColor Red
    if (Test-Path $listenerLogPath) {
        Write-Host '--- listener stdout (tail) ---' -ForegroundColor DarkYellow
        Get-Content -Path $listenerLogPath -Tail 50
    }
    if (Test-Path $listenerErrLogPath) {
        Write-Host '--- listener stderr (tail) ---' -ForegroundColor DarkYellow
        Get-Content -Path $listenerErrLogPath -Tail 50
    }
    exit 3
}

Write-Host "✅ Start verification passed. Listener PID(s): $((@($running) | ForEach-Object { $_.ProcessId }) -join ', ')" -ForegroundColor Green
Write-Host 'Step 3/4: Preparing continuous log stream...' -ForegroundColor Yellow

Ensure-FileExists -Path $listenerLogPath
Ensure-FileExists -Path $listenerErrLogPath
Ensure-FileExists -Path $dispatchLogPath

$offsetOut = [int64](Get-Item $listenerLogPath).Length
$offsetErr = [int64](Get-Item $listenerErrLogPath).Length
$offsetDispatch = [int64](Get-Item $dispatchLogPath).Length

Write-Host 'Step 4/4: Streaming logs (Ctrl+C to stop)...' -ForegroundColor Yellow
Write-Host "Watching:" -ForegroundColor Cyan
Write-Host " - OUT : $listenerLogPath" -ForegroundColor Gray
Write-Host " - ERR : $listenerErrLogPath" -ForegroundColor Gray
Write-Host " - DISP: $dispatchLogPath" -ForegroundColor Gray

try {
    while ($true) {
        Read-NewLogLines -Path $listenerLogPath -LastByteOffset ([ref]$offsetOut) -Label 'LISTENER'
        Read-NewLogLines -Path $listenerErrLogPath -LastByteOffset ([ref]$offsetErr) -Label 'LISTENER_ERR'
        Read-NewLogLines -Path $dispatchLogPath -LastByteOffset ([ref]$offsetDispatch) -Label 'DISPATCH'
        Start-Sleep -Seconds $TailRefreshSeconds
    }
} catch {
    Write-Host "Log streaming stopped: $($_.Exception.Message)" -ForegroundColor DarkYellow
}
