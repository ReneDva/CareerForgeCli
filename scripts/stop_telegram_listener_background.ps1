$ErrorActionPreference = 'Stop'

$procs = Get-CimInstance Win32_Process |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'telegram_reaction_listener\.ps1' }

if (-not $procs -or @($procs).Count -eq 0) {
    Write-Host 'No telegram listener process is running.' -ForegroundColor Yellow

    $suspects = Get-CimInstance Win32_Process |
        Where-Object {
            $_.CommandLine -and (
                $_.CommandLine -match 'openclaw' -or
                $_.CommandLine -match 'dock_telegram' -or
                $_.CommandLine -match 'telegram' -or
                $_.CommandLine -match 'getUpdates'
            )
        } |
        Select-Object -First 15 ProcessId, Name, CommandLine

    if ($suspects -and @($suspects).Count -gt 0) {
        Write-Host ''
        Write-Host 'Possible active Telegram consumers (first 15):' -ForegroundColor Cyan
        $suspects | Format-Table -AutoSize
    } else {
        Write-Host 'No obvious Telegram/OpenClaw consumer processes found.' -ForegroundColor DarkYellow
    }
    exit 0
}

foreach ($p in @($procs)) {
    try {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
        Write-Host "Stopped listener PID=$($p.ProcessId)" -ForegroundColor Green
    } catch {
        Write-Host "Failed to stop PID=$($p.ProcessId): $($_.Exception.Message)" -ForegroundColor Red
    }
}
