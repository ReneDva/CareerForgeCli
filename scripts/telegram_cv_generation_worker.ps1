param(
    [Parameter(Mandatory=$true)][string]$JobId,
    [Parameter(Mandatory=$true)][string]$BotToken,
    [Parameter(Mandatory=$true)][string]$ChatId,
    [string]$ModelId = '',
    [string]$JobTitle = '',
    [string]$JobCompany = '',
    [string]$JobLocation = '',
    [string]$JobUrl = ''
)

. "$PSScriptRoot\job_state_machine.ps1"
. "$PSScriptRoot\telegram_interface.ps1"

$workspaceRoot = Join-Path $PSScriptRoot '..'
$trackerPath = Join-Path $workspaceRoot 'job_tracker.csv'
$jobsFoundPath = Join-Path $workspaceRoot 'jobs_found.json'
$jobsRawPath = Join-Path $workspaceRoot 'jobs.json'
$profilePath = Join-Path $workspaceRoot 'profile.md'
$cliPath = Join-Path $workspaceRoot 'dist/cli.js'
$rocketEmoji = [char]::ConvertFromUtf32(0x1F680)
$allowedModels = @(
    'google/gemini-3-pro-preview',
    'google/gemini-2.5-pro',
    'google/gemini-2.0-flash'
)

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

function Resolve-GenerationModel {
    param([string]$RequestedModelId)

    $fallback = 'google/gemini-3-pro-preview'
    if ([string]::IsNullOrWhiteSpace($RequestedModelId)) {
        return $fallback
    }

    $normalized = "$RequestedModelId".Trim().ToLowerInvariant()
    $match = @($allowedModels | Where-Object { "$_".ToLowerInvariant() -eq $normalized } | Select-Object -First 1)
    if ($match.Count -gt 0) {
        return "$($match[0])"
    }

    throw "Requested model '$RequestedModelId' is not allowed. Allowed: $($allowedModels -join ', ')"
}

function Get-DotEnvValues {
    param([Parameter(Mandatory=$true)][string]$WorkspacePath)

    $map = @{}
    $dotEnvPath = Join-Path $WorkspacePath '.env'
    if (-not (Test-Path $dotEnvPath)) {
        return $map
    }

    try {
        $lines = Get-Content $dotEnvPath -Encoding UTF8
        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $trimmed = "$line".Trim()
            if ($trimmed.StartsWith('#')) { continue }
            if ($trimmed -notmatch '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') { continue }

            $k = "$($matches[1])"
            $v = "$($matches[2])".Trim()
            if (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'"))) {
                $v = $v.Substring(1, $v.Length - 2)
            }
            $map[$k] = $v
        }
    } catch {
        # best-effort only
    }

    return $map
}

function Get-ConfigOrEnvValue {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [hashtable]$DotEnvValues
    )

    $fromEnv = [Environment]::GetEnvironmentVariable($Name)
    if (-not [string]::IsNullOrWhiteSpace("$fromEnv")) {
        return "$fromEnv"
    }

    if ($DotEnvValues -and $DotEnvValues.ContainsKey($Name) -and -not [string]::IsNullOrWhiteSpace("$($DotEnvValues[$Name])")) {
        return "$($DotEnvValues[$Name])"
    }

    return ''
}

function Assert-CvGenerationPreflight {
    param(
        [Parameter(Mandatory=$true)][string]$WorkspacePath,
        [Parameter(Mandatory=$true)][string]$ProfileFilePath,
        [Parameter(Mandatory=$true)][string]$CliFilePath,
        [Parameter(Mandatory=$true)][string]$BotTokenParam
    )

    $failures = New-Object System.Collections.Generic.List[string]

    if (-not (Test-Path $ProfileFilePath)) {
        $failures.Add("profile.md not found at '$ProfileFilePath'.")
    } else {
        try {
            Get-Content -Path $ProfileFilePath -TotalCount 1 -Encoding UTF8 | Out-Null
        } catch {
            $failures.Add("profile.md exists but is not readable: $($_.Exception.Message)")
        }
    }

    if (-not (Test-Path $CliFilePath)) {
        $failures.Add("CLI entrypoint missing at '$CliFilePath'. Run build first.")
    }

    try {
        $nodeCmd = Get-Command node -ErrorAction Stop
        if (-not $nodeCmd) {
            $failures.Add('Node.js runtime (node) is not available in PATH.')
        }
    } catch {
        $failures.Add('Node.js runtime (node) is not available in PATH.')
    }

    $dotEnvValues = Get-DotEnvValues -WorkspacePath $WorkspacePath
    $geminiApiKey = Get-ConfigOrEnvValue -Name 'GEMINI_API_KEY' -DotEnvValues $dotEnvValues
    $telegramToken = if (-not [string]::IsNullOrWhiteSpace("$BotTokenParam")) { "$BotTokenParam" } else { Get-ConfigOrEnvValue -Name 'TELEGRAM_BOT_TOKEN' -DotEnvValues $dotEnvValues }

    if ([string]::IsNullOrWhiteSpace($geminiApiKey)) {
        $failures.Add('Missing required GEMINI_API_KEY (env or .env).')
    }
    if ([string]::IsNullOrWhiteSpace($telegramToken)) {
        $failures.Add('Missing required TELEGRAM_BOT_TOKEN (param/env/.env).')
    }

    if ($failures.Count -gt 0) {
        throw "Preflight failed: $($failures -join ' | ')"
    }
}

function Ensure-TrackerRowForJob {
    param([Parameter(Mandatory=$true)][string]$TargetJobId)

    $rows = Get-TrackerRows -TrackerPath $trackerPath
    $existing = $rows | Where-Object { "$($_.job_id)" -eq "$TargetJobId" } | Select-Object -First 1
    if ($existing) {
        return $existing
    }

    $fallbackJob = Get-JobById -TargetJobId $TargetJobId
    if (-not $fallbackJob) {
        $fallbackJob = [PSCustomObject]@{
            id = $TargetJobId
            title = "$JobTitle"
            company = "$JobCompany"
            location = "$JobLocation"
            job_url = "$JobUrl"
        }
    }

    try {
        Add-FoundJobIfMissing -TrackerPath $trackerPath -Job $fallbackJob -Source 'telegram_cv_worker_recovery' | Out-Null
    } catch {}

    $rows = Get-TrackerRows -TrackerPath $trackerPath
    $recovered = $rows | Where-Object { "$($_.job_id)" -eq "$TargetJobId" } | Select-Object -First 1
    if (-not $recovered) {
        return $null
    }

    try {
        Set-JobStatus -TrackerPath $trackerPath -JobId $TargetJobId -NewStatus 'Sent' -Reason 'Recovered tracker row for async CV generation worker'
    } catch {}
    try {
        Set-JobStatus -TrackerPath $trackerPath -JobId $TargetJobId -NewStatus 'CV_Generating' -Reason 'Recovered async CV generation after tracker reset'
    } catch {}

    $rows = Get-TrackerRows -TrackerPath $trackerPath
    return $rows | Where-Object { "$($_.job_id)" -eq "$TargetJobId" } | Select-Object -First 1
}

$row = Ensure-TrackerRowForJob -TargetJobId $JobId
if (-not $row) {
    try {
        $msg = "&#9888;&#65039; Could not start CV generation for <b>$JobId</b>: job not found in tracker (or recovery failed)."
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

try {
    Assert-CvGenerationPreflight -WorkspacePath $workspaceRoot -ProfileFilePath $profilePath -CliFilePath $cliPath -BotTokenParam $BotToken
} catch {
    $preflightErr = if ($_.Exception -and $_.Exception.Message) { "$($_.Exception.Message)" } else { "$_" }
    try {
        Set-JobStatus -TrackerPath $trackerPath -JobId $JobId -NewStatus 'Apply_Failed' -Reason 'CV generation preflight failed' -FieldUpdates @{ last_error = $preflightErr }
    } catch {}
    Write-DispatchLog -JobId $JobId -Status 'Apply_Failed' -Reason 'preflight_failed'

    try {
        $safeErr = [System.Security.SecurityElement]::Escape($preflightErr)
        $msg = "&#9888;&#65039; CV generation preflight failed for <b>$JobId</b>.`nReason: <code>$safeErr</code>"
        Send-TelegramTextDeterministic -BotToken $BotToken -ChatId $ChatId -Text $msg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
    } catch {}

    exit 1
}

$desc = if ($job.description) { "$($job.description)" } else { "Role: $($job.title)`nCompany: $($job.company)`nLocation: $($job.location)`nLink: $($job.job_url)" }
$jobTempDir = Join-Path $workspaceRoot ("temp/" + $JobId)
if (-not (Test-Path $jobTempDir)) {
    New-Item -ItemType Directory -Path $jobTempDir -Force | Out-Null
}
$jobDescPath = Join-Path $jobTempDir 'job_desc.txt'
Set-Content -Path $jobDescPath -Value $desc -Encoding UTF8

$cvPath = Get-NextCvPath -TargetJobId $JobId
$generationModel = Resolve-GenerationModel -RequestedModelId $ModelId
$pushed = $false

try {
    Push-Location $workspaceRoot
    $pushed = $true
    $generateOutput = & node "$cliPath" generate --profile "$profilePath" --job "$jobDescPath" --out "$cvPath" --theme modern --model "$generationModel" 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0 -or -not (Test-Path $cvPath)) {
        $outputText = ''
        try {
            $outputText = (($generateOutput | ForEach-Object { "$_" }) -join "`n")
        } catch {
            $outputText = ''
        }

        if ([string]::IsNullOrWhiteSpace($outputText)) {
            throw "CV generation command failed (exit=$exitCode)."
        }

        throw "CV generation command failed (exit=$exitCode). Output: $outputText"
    }

    $caption = "CV draft generated for Job ID: $JobId`nPlease review manually.`nReact with 🚀 / ❤️ / 🔥 after approval."
    Send-TelegramDocumentDeterministic -BotToken $BotToken -ChatId $ChatId -FilePath $cvPath -Caption $caption -MaxRetries 3 -RetryDelaySeconds 2 | Out-Null

    Set-JobStatus -TrackerPath $trackerPath -JobId $JobId -NewStatus 'CV_Ready_For_Review' -Reason 'Draft CV sent to Telegram for manual review' -FieldUpdates @{ latest_cv_path = $cvPath; last_error = '' }
    Write-DispatchLog -JobId $JobId -Status 'CV_Ready_For_Review' -Reason 'cv_sent_for_manual_review'
} catch {
    $rawError = if ($_.Exception -and $_.Exception.Message) { "$($_.Exception.Message)" } else { "$_" }
    $normalizedError = ($rawError -replace '\s+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($normalizedError)) {
        $normalizedError = 'Unknown error.'
    }
    if ($normalizedError.Length -gt 700) {
        $normalizedError = $normalizedError.Substring(0, 700) + '...'
    }

    Write-Host "CV generation/send failed for job_id=${JobId}: $normalizedError"

    try {
        Set-JobStatus -TrackerPath $trackerPath -JobId $JobId -NewStatus 'Apply_Failed' -Reason 'CV generation/send failed' -FieldUpdates @{ last_error = $normalizedError }
    } catch {}
    Write-DispatchLog -JobId $JobId -Status 'Apply_Failed' -Reason 'cv_generation_or_send_failed'

    try {
        $safeErr = [System.Security.SecurityElement]::Escape($normalizedError)
        $msg = "&#9888;&#65039; CV generation failed for <b>$JobId</b>.`nReason: <code>$safeErr</code>"
        Send-TelegramTextDeterministic -BotToken $BotToken -ChatId $ChatId -Text $msg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML' | Out-Null
    } catch {}
} finally {
    if ($pushed) {
        Pop-Location
    }
    if (Test-Path $jobDescPath) {
        Remove-Item $jobDescPath -ErrorAction SilentlyContinue
    }
    if (Test-Path $jobTempDir) {
        try {
            Remove-Item $jobTempDir -ErrorAction SilentlyContinue
        } catch {}
    }
}
