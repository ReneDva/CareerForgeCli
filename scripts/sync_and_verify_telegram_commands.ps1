param(
    [string]$ChatId = '5225138885',
    [switch]$SkipListenerRun
)

$ErrorActionPreference = 'Stop'

$workspaceRoot = Join-Path $PSScriptRoot '..'
$listenerPath = Join-Path $PSScriptRoot 'telegram_reaction_listener.ps1'
$interfacePath = Join-Path $PSScriptRoot 'telegram_interface.ps1'
$backupDir = Join-Path $workspaceRoot 'memory/telegram_command_backups'

if (-not (Test-Path $listenerPath)) {
    throw "Listener script not found: $listenerPath"
}
if (-not (Test-Path $interfacePath)) {
    throw "Telegram interface script not found: $interfacePath"
}

. $interfacePath

$token = Get-TelegramBotToken -WorkspaceRoot $workspaceRoot
if ([string]::IsNullOrWhiteSpace($token)) {
    throw 'TELEGRAM_BOT_TOKEN not found in .env or environment.'
}

if (-not $SkipListenerRun) {
    Write-Host 'Running listener once to sync command menus...' -ForegroundColor Cyan
    try {
        & $listenerPath -Once -SkipBacklogOnStart:$true -ChatId $ChatId
    } catch {
        Write-Host "Listener run failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Get-ScopeCommands {
    param(
        [string]$ScopeName,
        [hashtable]$Scope
    )

    try {
        if ($Scope) {
            $cmds = Get-TelegramBotCommandsDeterministic -BotToken $token -Scope $Scope
        } else {
            $cmds = Get-TelegramBotCommandsDeterministic -BotToken $token
        }

        return [PSCustomObject]@{
            scope = $ScopeName
            ok = $true
            commands = @($cmds | ForEach-Object { "$($_.command)" })
            error = ''
        }
    } catch {
        return [PSCustomObject]@{
            scope = $ScopeName
            ok = $false
            commands = @()
            error = "$($_.Exception.Message)"
        }
    }
}

$defaultResult = Get-ScopeCommands -ScopeName 'default' -Scope $null
$privateResult = Get-ScopeCommands -ScopeName 'all_private_chats' -Scope @{ type = 'all_private_chats' }
$chatResult = Get-ScopeCommands -ScopeName 'chat' -Scope @{ type = 'chat'; chat_id = [int64]$ChatId }

$results = @($defaultResult, $privateResult, $chatResult)

Write-Host ''
Write-Host '=== Telegram command scope results ===' -ForegroundColor Cyan
foreach ($r in $results) {
    if (-not $r.ok) {
        Write-Host ("[{0}] ERROR: {1}" -f $r.scope, $r.error) -ForegroundColor Red
        continue
    }

    $hasCli = $r.commands -contains 'search_cli'
    $hasAgent = $r.commands -contains 'search_agent'
    Write-Host ("[{0}] count={1} search_cli={2} search_agent={3}" -f $r.scope, $r.commands.Count, $hasCli, $hasAgent) -ForegroundColor Green
    Write-Host ("  commands: {0}" -f (($r.commands) -join ', '))
}

Write-Host ''
Write-Host '=== Recent command backups ===' -ForegroundColor Cyan
if (Test-Path $backupDir) {
    Get-ChildItem $backupDir -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 10 Name, LastWriteTime |
        Format-Table -AutoSize
} else {
    Write-Host "Backup directory does not exist yet: $backupDir" -ForegroundColor Yellow
}

$privateHasCli = $privateResult.ok -and ($privateResult.commands -contains 'search_cli')
$privateHasAgent = $privateResult.ok -and ($privateResult.commands -contains 'search_agent')

Write-Host ''
if ($privateHasCli -and $privateHasAgent) {
    Write-Host 'PASS: all_private_chats scope includes both search_cli and search_agent.' -ForegroundColor Green
    exit 0
}

Write-Host 'FAIL: all_private_chats scope is missing search_cli and/or search_agent.' -ForegroundColor Red
exit 2
