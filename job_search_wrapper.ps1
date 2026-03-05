param(
    [string]$InputFileOverride
)

$configFile = "search_config.json"
$config = Get-Content $configFile -Raw -Encoding UTF8 | ConvertFrom-Json

$queries = $config.queries
$locations = $config.locations
$pythonPath = $config.pythonPath
$scriptPath = $config.scriptPath
$hoursOld = [int]$config.hoursOld
$resultsPerQuery = [int]$config.resultsPerQuery
$outputFile = "jobs_found.json"
$tempFile = "jobs_temp.json"

# Optional strict filtering knobs from config
$excludeTitleKeywords = if ($config.excludeTitleKeywords) { @($config.excludeTitleKeywords) } else { @("Senior", "Lead", "Staff", "Principal", "Manager", "Expert") }
$allowedLocationKeywords = if ($config.allowedLocationKeywords) { @($config.allowedLocationKeywords) } else { @() }
$minDisqualifyingYears = if ($config.minDisqualifyingYears) { [int]$config.minDisqualifyingYears } else { 3 }
$allowUnknownLocation = if ($null -ne $config.allowUnknownLocation) { [bool]$config.allowUnknownLocation } else { $false }
$maxAgeHours = if ($config.maxAgeHours) { [int]$config.maxAgeHours } else { $hoursOld }

$finalJobs = New-Object System.Collections.Generic.List[object]

function Get-JobIdentifier {
    param([Parameter(Mandatory=$true)]$Job)

    if ($Job.id) { return "id:$($Job.id)" }
    if ($Job.job_url) { return "url:$($Job.job_url)" }
    return "title:$($Job.title)|company:$($Job.company)"
}

function Get-PostedDate {
    param([Parameter(Mandatory=$true)]$Job)

    $raw = $Job.date_posted
    if ($null -eq $raw -or "$raw".Trim() -eq "") {
        return $null
    }

    try {
        if ($raw -is [int] -or $raw -is [long] -or $raw -is [double] -or $raw -match '^\d+$') {
            $num = [double]$raw
            if ($num -ge 1000000000000) {
                return [System.DateTimeOffset]::FromUnixTimeMilliseconds([long]$num).DateTime
            }
            if ($num -ge 1000000000) {
                return [System.DateTimeOffset]::FromUnixTimeSeconds([long]$num).DateTime
            }
        }

        return [datetime]::Parse($raw.ToString())
    } catch {
        return $null
    }
}

function Test-LocationAllowed {
    param(
        [Parameter(Mandatory=$true)]$Job,
        [string[]]$AllowedKeywords,
        [bool]$AllowUnknown
    )

    if (-not $AllowedKeywords -or $AllowedKeywords.Count -eq 0) {
        return $true
    }

    $locationText = ""
    if ($Job.location) { $locationText = "$($Job.location)" }

    if ([string]::IsNullOrWhiteSpace($locationText)) {
        return $AllowUnknown
    }

    foreach ($keyword in $AllowedKeywords) {
        if (-not [string]::IsNullOrWhiteSpace($keyword) -and $locationText -match [regex]::Escape($keyword)) {
            return $true
        }
    }

    return $false
}

function Test-ExperienceAllowed {
    param(
        [Parameter(Mandatory=$true)]$Job,
        [int]$MinYears
    )

    if (-not $Job.description) {
        return $true
    }

    $desc = "$($Job.description)"

    $patterns = @(
        '\b(?<years>\d{1,2})\s*\+\s*years?\b',
        '\b(?:at\s+least|minimum|min\.?|>=)\s*(?<years>\d{1,2})\s*years?\b',
        '\b(?<years>\d{1,2})\s*(?:-|to)\s*(?<years2>\d{1,2})\s*years?\b',
        '\b(?<years>\d{1,2})\s*years?\s+of\s+experience\b',
        '\brequires?\s+(?<years>\d{1,2})\s*years?\b'
    )

    foreach ($pattern in $patterns) {
        $matches = [regex]::Matches($desc, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        foreach ($m in $matches) {
            $years = $null

            if ($m.Groups['years'].Success) {
                $years = [int]$m.Groups['years'].Value
            }
            if ($m.Groups['years2'].Success) {
                $years2 = [int]$m.Groups['years2'].Value
                if ($years2 -gt $years) { $years = $years2 }
            }

            if ($null -ne $years -and $years -ge $MinYears) {
                return $false
            }
        }
    }

    return $true
}

function Test-RecencyAllowed {
    param(
        [Parameter(Mandatory=$true)]$Job,
        [int]$MaxHours
    )

    $postedDate = Get-PostedDate -Job $Job
    if ($null -eq $postedDate) {
        # Keep unknown posting dates by design (LinkedIn often omits structured date fields)
        return $true
    }

    $threshold = (Get-Date).AddHours(-1 * $MaxHours)
    return ($postedDate -ge $threshold)
}

function Test-TitleAllowed {
    param(
        [Parameter(Mandatory=$true)]$Job,
        [string[]]$ExcludeKeywords
    )

    if (-not $Job.title) { return $true }
    $title = "$($Job.title)"

    foreach ($keyword in $ExcludeKeywords) {
        if (-not [string]::IsNullOrWhiteSpace($keyword) -and $title -match [regex]::Escape($keyword)) {
            return $false
        }
    }

    return $true
}

function Process-Jobs {
    param(
        [Parameter(Mandatory=$true)]$Jobs,
        [Parameter(Mandatory=$true)][string]$SourceTag
    )

    foreach ($job in $Jobs) {
        $identifier = Get-JobIdentifier -Job $job

        if (-not (Test-TitleAllowed -Job $job -ExcludeKeywords $excludeTitleKeywords)) {
            Write-Host "Discarding [$identifier] due to title seniority filter."
            continue
        }

        if (-not (Test-LocationAllowed -Job $job -AllowedKeywords $allowedLocationKeywords -AllowUnknown $allowUnknownLocation)) {
            Write-Host "Discarding [$identifier] due to location filter. Location='$($job.location)'"
            continue
        }

        if (-not (Test-RecencyAllowed -Job $job -MaxHours $maxAgeHours)) {
            Write-Host "Discarding [$identifier] due to recency filter (older than $maxAgeHours hours)."
            continue
        }

        if (-not (Test-ExperienceAllowed -Job $job -MinYears $minDisqualifyingYears)) {
            Write-Host "Discarding [$identifier] due to experience requirement ($minDisqualifyingYears+ years)."
            continue
        }

        $finalJobs.Add($job)
    }
}

# Clean previous output
if (Test-Path $outputFile) { Remove-Item $outputFile -ErrorAction SilentlyContinue }

if ($InputFileOverride) {
    if (-not (Test-Path $InputFileOverride)) {
        Write-Host "Input override file not found: $InputFileOverride"
        exit 1
    }

    try {
        $jobsFromFile = Get-Content $InputFileOverride -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($jobsFromFile) {
            Process-Jobs -Jobs $jobsFromFile -SourceTag "override"
        }
    } catch {
        Write-Host "Error parsing override input file: $_"
        exit 1
    }
}
else {
    foreach ($loc in $locations) {
        foreach ($q in $queries) {
            Write-Host "Searching for '$q' in '$loc'..."

            $env:PYTHONIOENCODING = "utf-8"
            & $pythonPath $scriptPath --query "$q" --location "$loc" --hours-old $hoursOld --results $resultsPerQuery --out $tempFile

            if (Test-Path $tempFile) {
                try {
                    $jobs = Get-Content $tempFile -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($jobs) {
                        Process-Jobs -Jobs $jobs -SourceTag "$q|$loc"
                    }
                } catch {
                    Write-Host "Error parsing JSON from scrape output: $_"
                }

                Remove-Item $tempFile -ErrorAction SilentlyContinue
            }
        }
    }
}

# Deduplicate by preferred stable key (id -> job_url -> title+company)
$seen = @{}
$uniqueJobs = New-Object System.Collections.Generic.List[object]

foreach ($job in $finalJobs) {
    $key = Get-JobIdentifier -Job $job
    if (-not $seen.ContainsKey($key)) {
        $seen[$key] = $true
        $uniqueJobs.Add($job)
    }
}

if ($uniqueJobs.Count -gt 0) {
    $uniqueJobs | ConvertTo-Json -Depth 8 | Set-Content $outputFile -Encoding UTF8
    Write-Host "Found $($uniqueJobs.Count) unique filtered jobs."
}
else {
    Write-Host "No jobs found after filtering."
    Set-Content $outputFile "[]"
}
