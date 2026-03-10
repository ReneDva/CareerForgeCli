param(
    [string]$KeepJobId = 'corephotonics-jse-temp'
)

$ErrorActionPreference = 'Stop'

$workspaceRoot = Join-Path $PSScriptRoot '..'
$trackerPath = Join-Path $workspaceRoot 'job_tracker.csv'
$generatedCvsPath = Join-Path $workspaceRoot 'Generated_CVs'
$tempPath = Join-Path $workspaceRoot 'temp'
$stopScript = Join-Path $PSScriptRoot 'stop_telegram_listener_background.ps1'

if (Test-Path $stopScript) {
    Write-Host 'Stopping Telegram listener before cleanup...' -ForegroundColor Yellow
    & $stopScript | Out-Null
}

if (-not (Test-Path $trackerPath)) {
    throw "Tracker file not found: $trackerPath"
}

$rows = Import-Csv $trackerPath
$keepRows = @($rows | Where-Object { "$($_.job_id)" -eq $KeepJobId })

if ($keepRows.Count -eq 0) {
    throw "Requested keep job_id '$KeepJobId' was not found in tracker. Aborting to avoid accidental full wipe."
}

$removedRows = @($rows | Where-Object { "$($_.job_id)" -ne $KeepJobId })
$removedIds = @($removedRows | ForEach-Object { "$($_.job_id)" })

$keepRows | Export-Csv -Path $trackerPath -NoTypeInformation -Encoding UTF8
Write-Host "Tracker reset complete. Kept rows: $($keepRows.Count). Removed rows: $($removedRows.Count)." -ForegroundColor Green

function Remove-JobDirsByName {
    param(
        [Parameter(Mandatory=$true)][string]$BaseDir,
        [string[]]$NamesToRemove
    )

    if (-not (Test-Path $BaseDir)) {
        return 0
    }

    $count = 0
    foreach ($name in @($NamesToRemove)) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $target = Join-Path $BaseDir $name
        if (Test-Path $target) {
            Remove-Item -Path $target -Recurse -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path $target)) {
                $count += 1
            }
        }
    }

    return $count
}

$removedCvById = Remove-JobDirsByName -BaseDir $generatedCvsPath -NamesToRemove $removedIds
$removedTempById = Remove-JobDirsByName -BaseDir $tempPath -NamesToRemove $removedIds

# Extra sweep for telegram test artifacts by naming convention
$extraCvRemoved = 0
if (Test-Path $generatedCvsPath) {
    $extraCvDirs = Get-ChildItem -Path $generatedCvsPath -Directory | Where-Object { $_.Name -like 'test-*' }
    foreach ($d in $extraCvDirs) {
        Remove-Item -Path $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path $d.FullName)) { $extraCvRemoved += 1 }
    }
}

$extraTempRemoved = 0
if (Test-Path $tempPath) {
    $extraTempDirs = Get-ChildItem -Path $tempPath -Directory | Where-Object { $_.Name -like 'test-*' }
    foreach ($d in $extraTempDirs) {
        Remove-Item -Path $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path $d.FullName)) { $extraTempRemoved += 1 }
    }
}

Write-Host "Cleanup summary:" -ForegroundColor Cyan
Write-Host " - Removed tracker rows: $($removedRows.Count)"
Write-Host " - Removed Generated_CVs directories by removed IDs: $removedCvById"
Write-Host " - Removed temp directories by removed IDs: $removedTempById"
Write-Host " - Removed extra Generated_CVs test-* directories: $extraCvRemoved"
Write-Host " - Removed extra temp test-* directories: $extraTempRemoved"
Write-Host " - Preserved tracker row: $KeepJobId"
