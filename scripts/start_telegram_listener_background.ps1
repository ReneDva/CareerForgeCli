param(
    [string]$ChatId = '5225138885',
    [int]$PollIntervalSeconds = 3
)

$ErrorActionPreference = 'Stop'

$workspaceRoot = Join-Path $PSScriptRoot '..'
$listenerScript = Join-Path $PSScriptRoot 'telegram_reaction_listener.ps1'
$listenerLogPath = Join-Path $workspaceRoot 'memory/telegram_listener_background.log'
$listenerErrLogPath = Join-Path $workspaceRoot 'memory/telegram_listener_background.err.log'

if (-not (Test-Path $listenerScript)) {
    throw "Listener script not found: $listenerScript"
}

$existing = Get-CimInstance Win32_Process |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'telegram_reaction_listener\.ps1' }

if ($existing -and @($existing).Count -gt 0) {
    Write-Host "Listener already running. PIDs: $((@($existing) | ForEach-Object { $_.ProcessId }) -join ', ')" -ForegroundColor Yellow
    exit 0
}

$psExe = $null
$hostCandidates = @('powershell.exe', 'pwsh.exe', 'pwsh', 'powershell')
foreach ($candidate in $hostCandidates) {
    try {
        $cmd = Get-Command $candidate -ErrorAction Stop
        if ($cmd -and $cmd.Source) {
            $psExe = "$($cmd.Source)"
            break
        }
    } catch {
        # Try next candidate
    }
}

if ([string]::IsNullOrWhiteSpace($psExe)) {
    throw 'Could not find a PowerShell host executable (powershell.exe/pwsh.exe).'
}

$args = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', $listenerScript,
    '-ChatId', $ChatId,
    '-PollIntervalSeconds', $PollIntervalSeconds
)

if (-not (Test-Path (Split-Path $listenerLogPath -Parent))) {
    New-Item -ItemType Directory -Path (Split-Path $listenerLogPath -Parent) -Force | Out-Null
}

if (Test-Path $listenerLogPath) {
    Remove-Item $listenerLogPath -Force -ErrorAction SilentlyContinue
}
if (Test-Path $listenerErrLogPath) {
    Remove-Item $listenerErrLogPath -Force -ErrorAction SilentlyContinue
}

$proc = Start-Process -FilePath $psExe -ArgumentList $args -WindowStyle Hidden -PassThru -RedirectStandardOutput $listenerLogPath -RedirectStandardError $listenerErrLogPath
Write-Host "Started telegram listener in background. PID=$($proc.Id)" -ForegroundColor Green

Start-Sleep -Seconds 2
$stillRunning = $null
try {
    $stillRunning = Get-Process -Id $proc.Id -ErrorAction Stop
} catch {
    $stillRunning = $null
}

if ($null -eq $stillRunning) {
    Write-Host "Listener exited quickly. Last log lines:" -ForegroundColor Red
    if (Test-Path $listenerLogPath) {
        Get-Content -Path $listenerLogPath -Tail 30
    } else {
        Write-Host "No log file found at $listenerLogPath"
    }
    if (Test-Path $listenerErrLogPath) {
        Write-Host "Error log:" -ForegroundColor Yellow
        Get-Content -Path $listenerErrLogPath -Tail 30
    }
    exit 2
}

Write-Host "Listener is running. Log: $listenerLogPath" -ForegroundColor Cyan
