
$configFile = "search_config.json"
$config = Get-Content $configFile -Raw -Encoding UTF8 | ConvertFrom-Json

$queries = $config.queries
$locations = $config.locations
$pythonPath = $config.pythonPath
$scriptPath = $config.scriptPath
$hoursOld = $config.hoursOld
$resultsPerQuery = $config.resultsPerQuery
$finalJobs = @()
$tempFile = "jobs_temp.json"
$outputFile = "jobs_found.json"

# Clean up
if (Test-Path $outputFile) { Remove-Item $outputFile -ErrorAction SilentlyContinue }

foreach ($loc in $locations) {
    foreach ($q in $queries) {
        Write-Host "Searching for '$q' in '$loc'..."
        # Set env for UTF-8 output
        $env:PYTHONIOENCODING = "utf-8"
        & $pythonPath $scriptPath --query "$q" --location "$loc" --hours-old $hoursOld --results $resultsPerQuery --out $tempFile
        
        if (Test-Path $tempFile) {
            try {
                $content = Get-Content $tempFile -Raw -Encoding UTF8
                $jobs = $content | ConvertFrom-Json
                if ($jobs) {
                    $excludeTitleKeywords = @("Senior", "Lead", "Staff", "Principal", "Manager", "Expert")
                    $now = Get-Date

                    foreach ($job in $jobs) {
                        # Strict Title Filter
                        $strictTitleFilter = $false
                        foreach ($keyword in $excludeTitleKeywords) {
                            if ($job.title -and ($job.title -like "*$keyword*")) {
                                $strictTitleFilter = $true
                                break
                            }
                        }

                        # Flexible Recency Filter: Discard only if explicitly older than 24 hours (not if null or recent)\n                        $discardRecency = $false\n                        if ($job.date_posted -ne $null) {\n                            # Convert Unix timestamp (milliseconds) to DateTime\n                            $postedDate = [System.DateTimeOffset]::FromUnixTimeMilliseconds($job.date_posted).DateTime\n                            $twentyFourHoursAgo = $now.AddHours(-24)\n                            if ($postedDate -lt $twentyFourHoursAgo) {\n                                $discardRecency = $true # Job is older than 24 hours, so discard\n                            }\n                        }\n\n                        # Flexible Experience Filter: Discard only if description exists AND explicitly asks for 3+ years\n                        $discardExperience = $false\n                        if ($job.description -ne $null) {\n                            # Regex to find \"X+ years of experience\" where X is 3 or more\n                            $experiencePattern = \'\\b([3-9]|\\d{2,})\\+\\s*years?\\s+of\\s+experience\\b|\\b(at\\s+least|minimum)\\s+([3-9]|\\d{2,})\\s*years?\\s+of\s+experience\\b|\\b([3-9]|\\d{2,})\\s*years?\\s+experience\\b\'\n                            if ($job.description -match $experiencePattern) {\n                                $discardExperience = $true # Job requires 3+ years, so it should be discarded\n                            }\n                        }\n\n                        # Apply all combined filters (Title, then Recency, then Experience)\n                        if (-not $strictTitleFilter -and -not $discardRecency -and -not $discardExperience) {\n                            $finalJobs += $job\n                        } else {\n                            if ($strictTitleFilter) {\n                                Write-Host \"Discarding job: \'$($job.title)\' at \'$($job.company)\' (ID: $($job.id)) due to strict title filter.\"\n                            } elseif ($discardRecency) {\n                                Write-Host \"Discarding job: \'$($job.title)\' at \'$($job.company)\' (ID: $($job.id)) due to recency filter (older than 24 hours).\"\n                            } elseif ($discardExperience) {\n                                Write-Host \"Discarding job: \'$($job.title)\' at \'$($job.company)\' (ID: $($job.id)) due to experience filter (3+ years required).\"\n                            }\n                        }
                    }
                }
            } catch {
                Write-Host "Error parsing JSON from search: $_"
            }
            Remove-Item $tempFile -ErrorAction SilentlyContinue
        }
    }
}

# Deduplicate by ID
if ($finalJobs.Count -gt 0) {
    $uniqueJobs = $finalJobs | Group-Object -Property id | ForEach-Object { $_.Group[0] }
    if ($uniqueJobs) {
        $uniqueJobs | ConvertTo-Json -Depth 5 | Set-Content $outputFile -Encoding UTF8
        Write-Host "Found $($uniqueJobs.Count) unique jobs."
    }
} else {
    Write-Host "No jobs found."
    Set-Content $outputFile "[]"
}
