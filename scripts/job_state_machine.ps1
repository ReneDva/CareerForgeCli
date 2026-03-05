# Job State Machine utilities for CareerForge

$JobStatusTransitions = @{
    Found                = @('Sent', 'Apply_Failed', 'Rejected_By_User')
    Sent                 = @('CV_Generating', 'Rejected_By_User')
    CV_Generating        = @('CV_Ready_For_Review', 'Apply_Failed')
    CV_Ready_For_Review  = @('CV_Revision_Requested', 'Approved_For_Apply', 'Rejected_By_User')
    CV_Revision_Requested= @('CV_Generating', 'Rejected_By_User')
    Approved_For_Apply   = @('Applied', 'Apply_Failed')
    Applied              = @()
    Apply_Failed         = @('CV_Generating', 'Approved_For_Apply', 'Rejected_By_User')
    Rejected_By_User     = @('CV_Generating')
}

$JobTrackerHeaders = @(
    'job_id',
    'source',
    'title',
    'company',
    'location',
    'job_url',
    'telegram_message_id',
    'status',
    'status_reason',
    'created_at',
    'updated_at',
    'latest_cv_path',
    'submitted_cv_path',
    'apply_attempts',
    'last_error'
)

function Get-NowIso {
    return (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
}

function New-TrackerRow {
    param(
        [Parameter(Mandatory=$true)]$Job,
        [Parameter(Mandatory=$true)][string]$Source,
        [string]$InitialStatus = 'Found'
    )

    $now = Get-NowIso
    return [PSCustomObject]@{
        job_id            = if ($Job.id) { "$($Job.id)" } else { '' }
        source            = $Source
        title             = if ($Job.title) { "$($Job.title)" } else { '' }
        company           = if ($Job.company) { "$($Job.company)" } else { '' }
        location          = if ($Job.location) { "$($Job.location)" } else { '' }
        job_url           = if ($Job.job_url) { "$($Job.job_url)" } else { '' }
        telegram_message_id = ''
        status            = $InitialStatus
        status_reason     = ''
        created_at        = $now
        updated_at        = $now
        latest_cv_path    = ''
        submitted_cv_path = ''
        apply_attempts    = '0'
        last_error        = ''
    }
}

function Initialize-JobTracker {
    param([Parameter(Mandatory=$true)][string]$TrackerPath)

    if (-not (Test-Path $TrackerPath)) {
        $headerLine = '"' + ($JobTrackerHeaders -join '","') + '"'
        Set-Content -Path $TrackerPath -Value $headerLine -Encoding UTF8
        return
    }

    $existingRows = Import-Csv $TrackerPath
    if ($existingRows.Count -eq 0) {
        return
    }

    $needsMigration = $false
    $propertyNames = @($existingRows[0].PSObject.Properties.Name)

    if ($propertyNames -contains '') {
        $needsMigration = $true
    }

    foreach ($h in $JobTrackerHeaders) {
        if (-not ($propertyNames -contains $h)) {
            $needsMigration = $true
            break
        }
    }

    if (-not $needsMigration) {
        return
    }

    Write-Host "Migrating tracker schema to state-machine format..."

    $migrated = foreach ($row in $existingRows) {
        $now = Get-NowIso
        [PSCustomObject]@{
            job_id            = if ($row.job_id) { "$($row.job_id)" } else { '' }
            source            = if ($row.source) { "$($row.source)" } else { 'legacy' }
            title             = if ($row.title) { "$($row.title)" } else { '' }
            company           = if ($row.company) { "$($row.company)" } else { '' }
            location          = if ($row.location) { "$($row.location)" } else { '' }
            job_url           = if ($row.job_url) { "$($row.job_url)" } else { '' }
            telegram_message_id = if ($row.telegram_message_id) { "$($row.telegram_message_id)" } else { '' }
            status            = if ($row.status) { "$($row.status)" } else { 'Sent' }
            status_reason     = if ($row.status_reason) { "$($row.status_reason)" } else { '' }
            created_at        = if ($row.date_found) { "$($row.date_found)" } elseif ($row.created_at) { "$($row.created_at)" } else { $now }
            updated_at        = if ($row.updated_at) { "$($row.updated_at)" } else { $now }
            latest_cv_path    = if ($row.cv_file_path) { "$($row.cv_file_path)" } elseif ($row.latest_cv_path) { "$($row.latest_cv_path)" } else { '' }
            submitted_cv_path = if ($row.submitted_cv_path) { "$($row.submitted_cv_path)" } else { '' }
            apply_attempts    = if ($row.apply_attempts) { "$($row.apply_attempts)" } else { '0' }
            last_error        = if ($row.last_error) { "$($row.last_error)" } else { '' }
        }
    }

    $migrated | Export-Csv -Path $TrackerPath -NoTypeInformation -Encoding UTF8
}

function Get-TrackerRows {
    param([Parameter(Mandatory=$true)][string]$TrackerPath)

    Initialize-JobTracker -TrackerPath $TrackerPath
    $imported = Import-Csv $TrackerPath
    if ($null -eq $imported) {
        return ,@()
    }
    $rows = @($imported)
    return ,$rows
}

function Save-TrackerRows {
    param(
        [Parameter(Mandatory=$true)][string]$TrackerPath,
        [Parameter(Mandatory=$true)]$Rows
    )

    if ($null -eq $Rows -or $Rows.Count -eq 0) {
        $headerLine = '"' + ($JobTrackerHeaders -join '","') + '"'
        Set-Content -Path $TrackerPath -Value $headerLine -Encoding UTF8
        return
    }

    $Rows | Select-Object $JobTrackerHeaders | Export-Csv -Path $TrackerPath -NoTypeInformation -Encoding UTF8
}

function Assert-ValidTransition {
    param(
        [string]$CurrentStatus,
        [Parameter(Mandatory=$true)][string]$NewStatus
    )

    if ([string]::IsNullOrWhiteSpace($CurrentStatus)) {
        return
    }

    if (-not $JobStatusTransitions.ContainsKey($CurrentStatus)) {
        throw "Unknown current status '$CurrentStatus'."
    }

    $allowed = @($JobStatusTransitions[$CurrentStatus])
    if ($allowed -notcontains $NewStatus) {
        throw "Invalid status transition: '$CurrentStatus' -> '$NewStatus'. Allowed: $($allowed -join ', ')"
    }
}

function Find-JobRowIndex {
    param(
        $Rows,
        [Parameter(Mandatory=$true)][string]$JobId
    )

    if ($null -eq $Rows -or $Rows.Count -eq 0) {
        return -1
    }

    for ($i = 0; $i -lt $Rows.Count; $i++) {
        if ("$($Rows[$i].job_id)" -eq "$JobId") {
            return $i
        }
    }
    return -1
}

function Add-FoundJobIfMissing {
    param(
        [Parameter(Mandatory=$true)][string]$TrackerPath,
        [Parameter(Mandatory=$true)]$Job,
        [string]$Source = 'job_search_wrapper'
    )

    $rows = Get-TrackerRows -TrackerPath $TrackerPath
    $jobId = if ($Job.id) { "$($Job.id)" } else { '' }

    if ([string]::IsNullOrWhiteSpace($jobId)) {
        throw 'Job is missing required id field; cannot track state transitions.'
    }

    $idx = Find-JobRowIndex -Rows $rows -JobId $jobId
    if ($idx -ge 0) {
        return $false
    }

    $newRow = New-TrackerRow -Job $Job -Source $Source -InitialStatus 'Found'
    $rows += $newRow
    Save-TrackerRows -TrackerPath $TrackerPath -Rows $rows
    return $true
}

function Set-JobStatus {
    param(
        [Parameter(Mandatory=$true)][string]$TrackerPath,
        [Parameter(Mandatory=$true)][string]$JobId,
        [Parameter(Mandatory=$true)][string]$NewStatus,
        [string]$Reason,
        [hashtable]$FieldUpdates
    )

    $rows = Get-TrackerRows -TrackerPath $TrackerPath
    $idx = Find-JobRowIndex -Rows $rows -JobId $JobId

    if ($idx -lt 0) {
        throw "Cannot set status for unknown job_id '$JobId'."
    }

    $row = $rows[$idx]
    $currentStatus = "$($row.status)"

    if ($currentStatus -eq 'Approved_For_Apply' -and $NewStatus -eq 'Applied') {
        # explicitly allowed; handled by transition table and business rule reminder
    }

    if ($currentStatus -ne $NewStatus) {
        Assert-ValidTransition -CurrentStatus $currentStatus -NewStatus $NewStatus
    }

    # hard business guard: never allow Applied unless already approved
    if ($NewStatus -eq 'Applied' -and $currentStatus -ne 'Approved_For_Apply') {
        throw "Guard violation: cannot move to Applied from '$currentStatus'. Must be Approved_For_Apply first."
    }

    $row.status = $NewStatus
    if ($PSBoundParameters.ContainsKey('Reason')) {
        $row.status_reason = if ($null -eq $Reason) { '' } else { "$Reason" }
    }

    $row.updated_at = Get-NowIso

    if ($FieldUpdates) {
        foreach ($k in $FieldUpdates.Keys) {
            if ($row.PSObject.Properties.Name -contains $k) {
                $row.$k = if ($null -eq $FieldUpdates[$k]) { '' } else { "$($FieldUpdates[$k])" }
            }
        }
    }

    $rows[$idx] = $row
    Save-TrackerRows -TrackerPath $TrackerPath -Rows $rows
}
