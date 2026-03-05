# Deterministic Telegram dispatch utilities for CareerForge

function Get-TelegramBotToken {
    param([string]$WorkspaceRoot = $PSScriptRoot + '\\..')

    $dotEnvPath = Join-Path $WorkspaceRoot '.env'
    if (Test-Path $dotEnvPath) {
        $envContent = Get-Content $dotEnvPath
        $tokenLine = $envContent | Select-String '^\s*TELEGRAM_BOT_TOKEN\s*='
        if ($tokenLine) {
            return ($tokenLine.ToString() -split '=', 2)[1].Trim().Trim('"').Trim("'")
        }
    }

    return $env:TELEGRAM_BOT_TOKEN
}

function Convert-ToSortDate {
    param($Job)

    if ($null -eq $Job.date_posted -or "$($Job.date_posted)" -eq '') {
        return [datetime]'1900-01-01'
    }

    try {
        if ($Job.date_posted -match '^\d+$') {
            $n = [double]$Job.date_posted
            if ($n -ge 1000000000000) {
                return [System.DateTimeOffset]::FromUnixTimeMilliseconds([long]$n).DateTime
            }
            if ($n -ge 1000000000) {
                return [System.DateTimeOffset]::FromUnixTimeSeconds([long]$n).DateTime
            }
        }
        return [datetime]::Parse("$($Job.date_posted)")
    } catch {
        return [datetime]'1900-01-01'
    }
}

function Sort-JobsForDeterministicDispatch {
    param(
        [Parameter(Mandatory=$true)]$Jobs
    )

    # Deterministic sort: newest date first -> id -> company -> title
    return @(
        $Jobs |
            Sort-Object 
                @{ Expression = { Convert-ToSortDate $_ }; Descending = $true },
                @{ Expression = { if ($_.id) { "$($_.id)" } else { '' } }; Descending = $false },
                @{ Expression = { if ($_.company) { "$($_.company)" } else { '' } }; Descending = $false },
                @{ Expression = { if ($_.title) { "$($_.title)" } else { '' } }; Descending = $false }
    )
}

function Format-TelegramJobMessage {
    param(
        [Parameter(Mandatory=$true)]$Job,
        [int]$SequenceNumber,
        [int]$TotalCount
    )

    $company = if ($Job.company) { "$($Job.company)" } else { 'Unknown' }
    $title = if ($Job.title) { "$($Job.title)" } else { 'Unknown' }
    $location = if ($Job.location) { "$($Job.location)" } else { 'Unknown' }
    $url = if ($Job.job_url) { "$($Job.job_url)" } else { 'N/A' }

    $companyEsc = [System.Security.SecurityElement]::Escape($company)
    $titleEsc = [System.Security.SecurityElement]::Escape($title)
    $locationEsc = [System.Security.SecurityElement]::Escape($location)
    $urlEsc = [System.Security.SecurityElement]::Escape($url)

    return "&#127970; <b>Company</b>: $companyEsc`n&#128188; <b>Title</b>: $titleEsc`n&#128205; <b>Location</b>: $locationEsc`n&#128279; <b>Link</b>: $urlEsc`n`n<i>React with &#128077; to generate CV | React with &#128640; to Generate &amp; Apply</i>"
}

function Ensure-MessageMapFile {
    param([string]$MapPath = 'memory/telegram_message_map.csv')

    if (-not (Test-Path $MapPath)) {
        'job_id,chat_id,message_id,created_at' | Set-Content -Path $MapPath -Encoding UTF8
    }
}

function Register-TelegramMessageMap {
    param(
        [Parameter(Mandatory=$true)][string]$JobId,
        [Parameter(Mandatory=$true)][string]$ChatId,
        [Parameter(Mandatory=$true)][string]$MessageId,
        [string]$MapPath = 'memory/telegram_message_map.csv'
    )

    Ensure-MessageMapFile -MapPath $MapPath
    $line = "$JobId,$ChatId,$MessageId,$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Add-Content -Path $MapPath -Value $line -Encoding UTF8
}

function Get-JobIdByTelegramMessageId {
    param(
        [Parameter(Mandatory=$true)][string]$ChatId,
        [Parameter(Mandatory=$true)][string]$MessageId,
        [string]$MapPath = 'memory/telegram_message_map.csv'
    )

    Ensure-MessageMapFile -MapPath $MapPath
    $rows = Import-Csv $MapPath
    $row = $rows | Where-Object { "$($_.chat_id)" -eq "$ChatId" -and "$($_.message_id)" -eq "$MessageId" } | Select-Object -First 1
    if ($row) { return "$($row.job_id)" }
    return $null
}

function Write-DispatchLog {
    param(
        [Parameter(Mandatory=$true)][string]$JobId,
        [Parameter(Mandatory=$true)][string]$Status,
        [string]$Reason,
        [string]$LogPath = 'memory/telegram_dispatch.log'
    )

    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')\t$JobId\t$Status\t$Reason"
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
}

function Send-TelegramTextDeterministic {
    param(
        [Parameter(Mandatory=$true)][string]$BotToken,
        [Parameter(Mandatory=$true)][string]$ChatId,
        [Parameter(Mandatory=$true)][string]$Text,
        [int]$MaxRetries = 3,
        [int]$RetryDelaySeconds = 2,
        [string]$ParseMode = 'HTML'
    )

    $uri = "https://api.telegram.org/bot$BotToken/sendMessage"
    $headers = @{ 'Content-Type' = 'application/json' }
    $body = @{ chat_id = $ChatId; text = $Text; parse_mode = $ParseMode } | ConvertTo-Json

    $attempt = 1
    while ($attempt -le $MaxRetries) {
        try {
            $resp = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -ErrorAction Stop
            return $resp
        } catch {
            if ($attempt -ge $MaxRetries) {
                throw
            }
            Start-Sleep -Seconds $RetryDelaySeconds
            $attempt += 1
        }
    }
}

function Send-TelegramDocumentDeterministic {
    param(
        [Parameter(Mandatory=$true)][string]$BotToken,
        [Parameter(Mandatory=$true)][string]$ChatId,
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string]$Caption,
        [int]$MaxRetries = 3,
        [int]$RetryDelaySeconds = 2
    )

    if (-not (Test-Path $FilePath)) {
        throw "File not found for Telegram document send: $FilePath"
    }

    $uri = "https://api.telegram.org/bot$BotToken/sendDocument"

    $attempt = 1
    while ($attempt -le $MaxRetries) {
        try {
            $form = @{
                chat_id = $ChatId
                caption = $Caption
                document = Get-Item $FilePath
            }
            $resp = Invoke-RestMethod -Uri $uri -Method Post -Form $form -ErrorAction Stop
            return $resp
        } catch {
            if ($attempt -ge $MaxRetries) {
                throw
            }
            Start-Sleep -Seconds $RetryDelaySeconds
            $attempt += 1
        }
    }
}

function Set-TelegramBotCommandsDeterministic {
    param(
        [Parameter(Mandatory=$true)][string]$BotToken,
        [Parameter(Mandatory=$true)]$Commands,
        [hashtable]$Scope,
        [string]$LanguageCode,
        [int]$MaxRetries = 3,
        [int]$RetryDelaySeconds = 2
    )

    $uri = "https://api.telegram.org/bot$BotToken/setMyCommands"
    $headers = @{ 'Content-Type' = 'application/json' }
    $normalizedCommands = @()
    foreach ($cmd in @($Commands)) {
        if ($null -eq $cmd) { continue }

        $commandName = "$($cmd.command)"
        $commandDescription = "$($cmd.description)"

        if ([string]::IsNullOrWhiteSpace($commandName) -or [string]::IsNullOrWhiteSpace($commandDescription)) {
            continue
        }

        $normalizedCommands += [PSCustomObject]@{
            command = $commandName
            description = $commandDescription
        }
    }

    $payload = @{ commands = @($normalizedCommands) }
    if ($PSBoundParameters.ContainsKey('Scope') -and $Scope) {
        $payload.scope = $Scope
    }
    if ($PSBoundParameters.ContainsKey('LanguageCode') -and -not [string]::IsNullOrWhiteSpace($LanguageCode)) {
        $payload.language_code = $LanguageCode
    }
    $body = $payload | ConvertTo-Json -Depth 8

    $attempt = 1
    while ($attempt -le $MaxRetries) {
        try {
            $resp = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -ErrorAction Stop
            return $resp
        } catch {
            if ($attempt -ge $MaxRetries) {
                throw
            }
            Start-Sleep -Seconds $RetryDelaySeconds
            $attempt += 1
        }
    }
}

function Get-TelegramBotCommandsDeterministic {
    param(
        [Parameter(Mandatory=$true)][string]$BotToken,
        [hashtable]$Scope,
        [string]$LanguageCode,
        [int]$MaxRetries = 3,
        [int]$RetryDelaySeconds = 2
    )

    $uri = "https://api.telegram.org/bot$BotToken/getMyCommands"
    $hasScopedArgs = ($PSBoundParameters.ContainsKey('Scope') -and $Scope) -or ($PSBoundParameters.ContainsKey('LanguageCode') -and -not [string]::IsNullOrWhiteSpace($LanguageCode))

    $attempt = 1
    while ($attempt -le $MaxRetries) {
        try {
            if ($hasScopedArgs) {
                $payload = @{}
                if ($PSBoundParameters.ContainsKey('Scope') -and $Scope) {
                    $payload.scope = $Scope
                }
                if ($PSBoundParameters.ContainsKey('LanguageCode') -and -not [string]::IsNullOrWhiteSpace($LanguageCode)) {
                    $payload.language_code = $LanguageCode
                }

                $headers = @{ 'Content-Type' = 'application/json' }
                $body = $payload | ConvertTo-Json -Depth 8
                $resp = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -ErrorAction Stop
            } else {
                $resp = Invoke-RestMethod -Uri $uri -Method Get -ErrorAction Stop
            }

            if ($resp.ok -and $resp.result) {
                return @($resp.result)
            }
            return @()
        } catch {
            if ($attempt -ge $MaxRetries) {
                throw
            }
            Start-Sleep -Seconds $RetryDelaySeconds
            $attempt += 1
        }
    }

    return @()
}
