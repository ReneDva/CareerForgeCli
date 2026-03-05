$tracker = 'tests/fixtures/jobs/state_machine_tracker.csv'
if (Test-Path $tracker) { Remove-Item $tracker -Force }

. "$PSScriptRoot/../../../scripts/job_state_machine.ps1"

Initialize-JobTracker -TrackerPath $tracker

$job = [PSCustomObject]@{
  id = 'state-test-1'
  title = 'Junior Backend Developer'
  company = 'TestCo'
  location = 'Tel Aviv, Israel'
  job_url = 'https://example.com/jobs/state-test-1'
}

$added = Add-FoundJobIfMissing -TrackerPath $tracker -Job $job -Source 'test'
if (-not $added) { throw 'Expected new job to be added as Found' }

Set-JobStatus -TrackerPath $tracker -JobId 'state-test-1' -NewStatus 'Sent' -Reason 'notification sent'
Set-JobStatus -TrackerPath $tracker -JobId 'state-test-1' -NewStatus 'CV_Generating'
Set-JobStatus -TrackerPath $tracker -JobId 'state-test-1' -NewStatus 'CV_Ready_For_Review'
Set-JobStatus -TrackerPath $tracker -JobId 'state-test-1' -NewStatus 'Approved_For_Apply'
Set-JobStatus -TrackerPath $tracker -JobId 'state-test-1' -NewStatus 'Applied'

$guardWorked = $false
$job2 = [PSCustomObject]@{
  id = 'state-test-2'
  title = 'Junior ML Engineer'
  company = 'TestCo2'
  location = 'Ramat Gan, Israel'
  job_url = 'https://example.com/jobs/state-test-2'
}
Add-FoundJobIfMissing -TrackerPath $tracker -Job $job2 -Source 'test' | Out-Null
Set-JobStatus -TrackerPath $tracker -JobId 'state-test-2' -NewStatus 'Sent'

try {
  Set-JobStatus -TrackerPath $tracker -JobId 'state-test-2' -NewStatus 'Applied'
} catch {
  $guardWorked = $true
}

if (-not $guardWorked) { throw 'Expected guard to block Applied without Approved_For_Apply' }

$rows = Import-Csv $tracker
$row1 = $rows | Where-Object { $_.job_id -eq 'state-test-1' }
$row2 = $rows | Where-Object { $_.job_id -eq 'state-test-2' }

if ($row1.status -ne 'Applied') { throw "Expected state-test-1 to be Applied, got '$($row1.status)'" }
if ($row2.status -ne 'Sent') { throw "Expected state-test-2 to remain Sent, got '$($row2.status)'" }

Write-Host 'STATE_MACHINE_TEST:OK'
