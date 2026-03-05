param(
    [string]$ChatId = '5225138885',
    [int]$Count = 3
)

. "$PSScriptRoot\telegram_interface.ps1"
. "$PSScriptRoot\job_state_machine.ps1"

$workspaceRoot = Join-Path $PSScriptRoot '..'
$trackerPath = Join-Path $workspaceRoot 'job_tracker.csv'
Initialize-JobTracker -TrackerPath $trackerPath

$botToken = Get-TelegramBotToken -WorkspaceRoot (Join-Path $PSScriptRoot '..')
if (-not $botToken) {
    Write-Host "TELEGRAM_BOT_TOKEN not found in .env or environment"
    exit 1
}

$runSuffix = Get-Date -Format 'yyyyMMddHHmmss'
$sampleJobs = @(
    [PSCustomObject]@{ id = "test-001-$runSuffix"; company = 'Alpha Labs'; title = 'Junior Backend Developer'; location = 'Tel Aviv, Israel'; job_url = 'https://example.com/jobs/test-001'; date_posted = '2026-03-05T09:00:00Z' },
    [PSCustomObject]@{ id = "test-002-$runSuffix"; company = 'Beta Systems'; title = 'Junior AI Engineer'; location = 'Ramat Gan, Israel'; job_url = 'https://example.com/jobs/test-002'; date_posted = '2026-03-05T08:30:00Z' },
    [PSCustomObject]@{ id = "test-003-$runSuffix"; company = 'Gamma Tech'; title = 'Junior Fullstack Developer'; location = 'Petah Tikva, Israel'; job_url = 'https://example.com/jobs/test-003'; date_posted = '2026-03-05T08:00:00Z' }
)

$jobs = Sort-JobsForDeterministicDispatch -Jobs $sampleJobs
$total = [Math]::Min($Count, $jobs.Count)

for ($i = 0; $i -lt $total; $i++) {
    $job = $jobs[$i]
    $msg = Format-TelegramJobMessage -Job $job -SequenceNumber ($i + 1) -TotalCount $total
    $msg = "[TEST MESSAGE]`n$msg"

    try {
        $null = Add-FoundJobIfMissing -TrackerPath $trackerPath -Job $job -Source 'telegram_test_sender'

        $sendResp = Send-TelegramTextDeterministic -BotToken $botToken -ChatId $ChatId -Text $msg -MaxRetries 3 -RetryDelaySeconds 2 -ParseMode 'HTML'
        $messageId = if ($sendResp.result.message_id) { "$($sendResp.result.message_id)" } else { '' }

        Set-JobStatus -TrackerPath $trackerPath -JobId "$($job.id)" -NewStatus 'Sent' -Reason 'Test message sent to Telegram' -FieldUpdates @{ telegram_message_id = $messageId }
        if (-not [string]::IsNullOrWhiteSpace($messageId)) {
            Register-TelegramMessageMap -JobId "$($job.id)" -ChatId "$ChatId" -MessageId $messageId
        }

        Write-DispatchLog -JobId "$($job.id)" -Status 'TEST_SENT' -Reason 'manual_test_message'
        Write-Host "Sent test message $($i + 1)/$total for $($job.id)"
        Start-Sleep -Seconds 2
    } catch {
        Write-DispatchLog -JobId "$($job.id)" -Status 'TEST_FAILED' -Reason 'manual_test_message_failed'
        Write-Host "Failed sending test message for $($job.id): $_"
    }
}
