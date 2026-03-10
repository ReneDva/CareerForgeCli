param(
    [string]$ChatId = '5225138885',
    [int]$PollIntervalSeconds = 3,
    [int]$StopVerificationTimeoutSeconds = 20,
    [int]$StartVerificationTimeoutSeconds = 25,
    [int]$TailRefreshSeconds = 1
)

$target = Join-Path $PSScriptRoot 'scripts/restart_telegram_system_and_follow_logs.ps1'
if (-not (Test-Path $target)) {
    throw "Missing target script: $target"
}

& $target `
    -ChatId $ChatId `
    -PollIntervalSeconds $PollIntervalSeconds `
    -StopVerificationTimeoutSeconds $StopVerificationTimeoutSeconds `
    -StartVerificationTimeoutSeconds $StartVerificationTimeoutSeconds `
    -TailRefreshSeconds $TailRefreshSeconds
