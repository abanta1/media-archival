# ================================
# DVD Fingerprint + TMDB Lookup
# ================================

param(
    [Parameter(Mandatory=$false)]
    [string]$Drive = "D:",   # Example: "D:\VIDEO_TS"

    [Parameter(Mandatory=$false)]
    [string]$TmdbKey = $env:TMDB_API
)

if ([string]::IsNullOrEmpty($TmdbKey)) {
    $TmdbKey = Get-Secret -Name TMDB_API -AsPlainText
}

$fileInfo = Get-Item -Path $PSCommandPath
$version = ": $($fileInfo.LastWriteTime.ToShortDateString()) - $($fileInfo.LastWriteTime.ToShortTimeString())"

$driveIndex = switch ($Drive[0]) {
	'D'		{ 0 }
	'H'		{ 1 }
	'F'		{ 2 }
	default { 9999 }
}

Write-Host "Drive is $Drive, index is $driveIndex" -ForegroundColor White
$BaseOutputDir = "G:/makemkvcon"


function Get-DiscMetadata {
    param([string]$DriveLetter)

    $mkOut = & "C:\Program Files (x86)\MakeMKV\makemkvcon64.exe" -r info disc:$driveIndex

    if (-not ($mkOut -match "CINFO:")) {
        Write-Host "MakeMKV unable to detect info, returning null" -ForegroundColor Red
        return $null
    }

    # Extract Disc Name
    $discLine = $mkOut | Where-Object { $_ -match '^CINFO:2,0,"(.*)"' }
    $title = if ($discLine -match '"(.*)"') { $Matches[1] -replace "_", " " } else { "" }

    $temp = $title -replace '(?i)[-_]?(BLU[- ]?RAY|DVD|DISC\s?\d+|SPECIAL_FEATURES|#.*).*$', ''
    $temp = $temp -replace '[-_]', ' ' -replace '\s+', ' '
    $cleanTitle = $temp.Trim()

    if (-not $cleanTitle) {
        Write-Host "No title found, exiting." -ForegroundColor Yellow
        exit
    }
    Write-Host "Title is: $cleanTitle" -ForegroundColor White

    # Extract per-title resolutions
    $resLine = $mkOut | Where-Object { $_ -match '^SINFO:(\d+),0,19,0,"(.*)"' } | ForEach-Object {
        if ($_ -match 'SINFO:(\d+),0,19,0,"(.*)"') {
            $resolution = $Matches[2]
            [PSCustomObject]@{
                Index      = [int]$Matches[1]
                Resolution = $resolution
                Width      = [int]($resolution -split 'x')[0]
                Height     = [int]($resolution -split 'x')[1]
            }
        }
    } | Sort-Object Index

    # Extract all title durations
    $variance = 20 # minutes
    $allTitles = $mkOut | Where-Object { $_ -match '^TINFO:\d+,9,0,"(\d+:\d+:\d+)"' } | ForEach-Object {
        if ($_ -match 'TINFO:(\d+),9,0,"(\d+):(\d+):(\d+)"') {
            $idx = [int]$Matches[1]
            $res = ($resLine | Where-Object { $_.Index -eq $idx } | Select-Object -First 1)
            [PSCustomObject]@{
                Index      = $idx
                Minutes    = [int]$Matches[2] * 60 + [int]$Matches[3]
                Resolution = if ($res) { $res.Resolution } else { "" }
                Width      = if ($res) { $res.Width } else { 0 }
                Height     = if ($res) { $res.Height } else { 0 }
            }
        }
    } | Sort-Object Minutes -Descending

    $mainFeatures = @($allTitles | Where-Object { [math]::Abs($_.Minutes - $allTitles[0].Minutes) -le $variance })
    $extras       = @($allTitles | Where-Object { [math]::Abs($_.Minutes - $allTitles[0].Minutes) -gt $variance })

    foreach ($feature in $mainFeatures) {
        Write-Host "Feature #$($feature.Index): $($feature.Minutes) minutes @ $($feature.Resolution)" -ForegroundColor White
    }

    return @{
        Title    = $cleanTitle
        Features = $mainFeatures
        Extras   = $extras
        Height   = if ($mainFeatures.Count -gt 0) { $mainFeatures[0].Height } else { 0 }
        Width    = if ($mainFeatures.Count -gt 0) { $mainFeatures[0].Width  } else { 0 }
    }
}


function Out-WrapText {
    param(
        [Parameter(Mandatory)]
        [string]$Text,
        [int]$Width = $Host.UI.RawUI.WindowSize.Width
    )

    $words = $Text -split '\s+'
    $line  = ""
    $out   = New-Object System.Collections.Generic.List[string]

    foreach ($word in $words) {
        if (($line.Length + $word.Length + 1) -gt $Width) {
            $out.Add($line.TrimEnd())
            $line = "$word "
        } else {
            $line += "$word "
        }
    }
    if ($line.Trim().Length -gt 0) { $out.Add($line.TrimEnd()) }
    return $out -join [Environment]::NewLine
}


function Search-MovieMatch {
    param($Title, $Runtime, $ApiKey)

    if (-not $Title) { return $null }

    $encodedTitle  = [uri]::EscapeDataString($Title)
    $queryURL      = "https://api.themoviedb.org/3/search/movie?api_key=$ApiKey&query=$encodedTitle"
    Write-Host "Querying TMDB at $queryURL" -ForegroundColor DarkGray
    $queryResults  = (Invoke-RestMethod -Uri $queryURL).results

    if (-not $queryResults) { return $null }

    $topResults = $queryResults | Select-Object -First 5

    foreach ($video in $topResults) {
        $detailsURL     = "https://api.themoviedb.org/3/movie/$($video.id)?api_key=$ApiKey"
        $detailsResults = Invoke-RestMethod -Uri $detailsURL

        $diff = [math]::Abs($Runtime - $detailsResults.runtime)
        if ($diff -le 2) {
            return [PSCustomObject]@{ Video = $detailsResults; NeedsReview = $false; Method = "Runtime Match" }
        } elseif ($diff -le 10) {
            return [PSCustomObject]@{ Video = $detailsResults; NeedsReview = $true;  Method = "Runtime within 10m" }
        }
    }

    return [PSCustomObject]@{ Video = $topResults[0]; NeedsReview = $true; Method = "Popularity Fallback" }
}


function Invoke-MakeMKVRip {
    param(
        [string]$EncodingName,
        [string]$FullPath,
        [int]$TitleIndex       # -1 = rip all
    )

    $exePath   = "C:\Program Files (x86)\MakeMKV\makemkvcon64.exe"
    $titleArg  = if ($TitleIndex -ge 0) { $TitleIndex } else { "all" }
    $arguments = "-r --progress=-stdout mkv --noscan --minlength=900 disc:$driveIndex $titleArg `"$FullPath`""

    $psi                        = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $exePath
    $psi.Arguments              = $arguments
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    $process           = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $null = $process.Start()

    $pct             = 0
    $title           = "Starting..."
    $step            = ""
    $startTime       = Get-Date
    $remainingString = "estimating..."
    $lastWidth       = $Host.UI.RawUI.WindowSize.Width

    while ($true) {
        $line = $process.StandardOutput.ReadLine()
        if ($null -eq $line) { break }

        $currentWidth = $Host.UI.RawUI.WindowSize.Width
        if ($currentWidth -ne $lastWidth) {
            $lastWidth = $currentWidth
            Write-Progress -Activity "Ripping: $EncodingName" -Completed
        }

        if ($line -match '^PRGV:(\d+),(\d+),(\d+)$') {
            $cur = [int]$Matches[1]; $max = [int]$Matches[3]
            if ($max -gt 0) { $pct = [math]::Floor(($cur / $max) * 100) }
            if ($pct -gt 2) {
                $elapsed = ((Get-Date) - $startTime).TotalSeconds
                if ($elapsed -gt 0) {
                    $remainingSecs   = ($elapsed / $pct) * (100 - $pct)
                    $remainingString = "{0:hh\:mm\:ss}" -f [TimeSpan]::FromSeconds($remainingSecs)
                }
            }
            Write-Progress -Activity "Ripping: $EncodingName" `
                           -Status "$title - $pct% complete - $remainingString remaining" `
                           -CurrentOperation $step `
                           -PercentComplete $pct
        } elseif ($line -match '^PRGT:\d+,\d+,"(.*)"$') {
            $title = $Matches[1]
        } elseif ($line -match '^PRGC:\d+,\d+,"(.*)"$') {
            $step = $Matches[1]
        }
    }

    $process.WaitForExit()
    Write-Progress -Activity "Ripping: $EncodingName" -Completed
    return $process.ExitCode
}


function Move-RippedFiles {
    param(
        [string]$FullPath,
        [string]$EncodingName,
        [string]$EncodingDir
    )

    $vids = Get-ChildItem -Recurse $FullPath
    foreach ($vid in $vids) {
        if ($vid.Name -match '(.*)(_t\d{2})\.mkv$') {
            $ripExt = $Matches[2]
        } else {
            continue
        }

        Write-Host "Auto-naming and moving $($vid.Name)..." -ForegroundColor DarkGray
        $newName = "$EncodingName$ripExt.mkv"
        $newPath = Join-Path $vid.DirectoryName $newName
        $destDir = "G:\Redbox\$EncodingDir"

        Rename-Item -Path $vid.FullName -NewName $newName
        Start-Sleep -Milliseconds 500

        if (-not (Test-Path $destDir)) {
            New-Item -Path $destDir -Type Directory -Force | Out-Null
            Start-Sleep -Milliseconds 500
        }

        Move-Item -Path $newPath -Destination $destDir
        Start-Sleep -Milliseconds 500

        $destFile = Join-Path $destDir $newName
        if (Test-Path $destFile) {
            Write-Host "$newName successfully moved!" -ForegroundColor Green
            # Remove _t00 suffix for the primary title
            if ($destFile -match '_t00\.mkv$') {
                Rename-Item -Path $destFile -NewName ($newName -replace $ripExt, '')
            }
        } else {
            Write-Host "Unable to find file in $destDir" -ForegroundColor Yellow
        }
    }

    if ((Get-Item $FullPath).GetFileSystemInfos().Count -eq 0) {
        Remove-Item $FullPath -Force
    }
}


# ================================
# Execution
# ================================
$host.ui.RawUI.WindowTitle = "Get-DVDTitle $version"

while ($true) {
    try {
        # Wait for disc
        $dots = 0
        while ($true) {
            if ((Test-Path "$Drive\VIDEO_TS") -or (Test-Path "$Drive\BDMV")) { break }
            $ellipsis = "." * $dots
            $pad      = " " * (3 - $dots)
            Write-Host "`rWaiting for disc $ellipsis$pad" -NoNewLine -ForegroundColor DarkGray
            $dots = ($dots + 1) % 4
            Start-Sleep -Milliseconds 750
        }

        Write-Host "`rDisc detected, starting rip..." -ForegroundColor Cyan
        Write-Host "Reading disc metadata via MakeMKV..." -ForegroundColor Cyan
        $metadata = Get-DiscMetadata -DriveLetter $Drive

        if (-not $metadata) {
            Write-Error "Failed to read disc metadata. Verify if clean and re-insert"
            (New-Object -ComObject Shell.Application).Namespace(17).ParseName("$Drive").InvokeVerb("Eject")
            continue
        } elseif ($metadata.Title -eq $lastTitle) {
            Write-Host "Same disc as last rip ($lastTitle) - insert a new disc." -ForegroundColor Yellow
            (New-Object -ComObject Shell.Application).Namespace(17).ParseName("$Drive").InvokeVerb("Eject")
            continue
        }

        Write-Host "Detected Disc Name: " -NoNewLine -ForegroundColor White
        Write-Host "$($metadata.Title)" -ForegroundColor Cyan

        $features = $metadata.Features

        # ---- Group features into distinct cuts (within 5 min = same cut, keep longest) ----
        # Features are already sorted longest-first from Get-DiscMetadata
        $dupThreshold  = 5
        $distinctCuts  = @()
        $assigned      = @{}

        foreach ($feature in $features) {
            if ($assigned[$feature.Index]) { continue }

            # Find all features within 5 min of this one (duplicates of the same cut)
            $group = @($features | Where-Object {
                -not $assigned[$_.Index] -and [math]::Abs($_.Minutes - $feature.Minutes) -le $dupThreshold
            })

            # Keep the longest (first, since sorted descending) as the representative
            $representative = $group | Sort-Object Minutes -Descending | Select-Object -First 1
            foreach ($g in $group) { $assigned[$g.Index] = $true }

            $distinctCuts += $representative
        }

        # Sort cuts longest-first so theatrical (shorter) ends up after extended (longer)
        # Then re-sort: shortest first = theatrical first, extended second
        $distinctCuts = @($distinctCuts | Sort-Object Minutes)

        Write-Host ""
        Write-Host "Detected $($distinctCuts.Count) distinct cut(s):" -ForegroundColor Cyan
        foreach ($cut in $distinctCuts) {
            Write-Host "  Title #$($cut.Index): $($cut.Minutes) min @ $($cut.Resolution)" -ForegroundColor White
        }

        # ---- TMDB lookup per distinct cut ----
        $methodPriority = @{ "Runtime Match" = 0; "Runtime within 10m" = 1; "Popularity Fallback" = 2 }
        $matchedCuts    = @()

        foreach ($cut in $distinctCuts) {
            Write-Host ""
            Write-Host "Searching TMDB for cut #$($cut.Index) ($($cut.Minutes) min)..." -ForegroundColor DarkGray
            $match = Search-MovieMatch -Title $metadata.Title -Runtime $cut.Minutes -ApiKey $TmdbKey

            if ($match) {
                $matchedCuts += [PSCustomObject]@{ Cut = $cut; Match = $match }
                $yr = if ($match.Video.release_date -match '(\d{4})') { $Matches[1] } else { "" }
                Write-Host "  -> $($match.Video.title) ($yr) via $($match.Method)" -ForegroundColor $(if ($match.NeedsReview) { "Yellow" } else { "Green" })
            } else {
                # No match at all - still rip, flag for review
                Write-Host "  -> No TMDB match found - will rip and flag for review" -ForegroundColor Yellow
                $matchedCuts += [PSCustomObject]@{ Cut = $cut; Match = $null }
            }
        }

        # Determine which cut is theatrical vs extended:
        # The cut with the best TMDB runtime match is theatrical.
        # Any cut longer than theatrical by >5 min is Extended.
        # Sort by match quality to find theatrical anchor.
        $theatricalCut = $matchedCuts |
            Where-Object { $_.Match -ne $null } |
            Sort-Object { $methodPriority[$_.Match.Method] } |
            Select-Object -First 1

        $theatricalMinutes = if ($theatricalCut) { $theatricalCut.Cut.Minutes } else { ($matchedCuts | Sort-Object { $_.Cut.Minutes } | Select-Object -First 1).Cut.Minutes }

        # Label each cut
        foreach ($mc in $matchedCuts) {
            $mc | Add-Member -MemberType NoteProperty -Name "IsExtended" -Value ($mc.Cut.Minutes -gt ($theatricalMinutes + $dupThreshold))
        }

        if ($matchedCuts.Count -eq 0) {
            Write-Warning "No cuts to process. Skipping disc."
            (New-Object -ComObject Shell.Application).Namespace(17).ParseName("$Drive").InvokeVerb("Eject")
            Start-Sleep -Milliseconds 500
            continue
        }

        # ---- Rip each distinct cut ----
        foreach ($mc in $matchedCuts) {
            $cut   = $mc.Cut
            $match = $mc.Match

            # If no TMDB match, use disc title and flag for review
            if ($null -eq $match) {
                $cleanTitle   = $metadata.Title -replace '[:\\/*?"<>|]', ''
                $imdbId       = "unknown"
                $videoYear    = ""
                $needsReview  = $true
                $matchMethod  = "No Match"
                $overview     = ""
            } else {
                $vid          = $match.Video
                $cleanTitle   = $vid.title -replace '[:\\/*?"<>|]', ''
                $imdbId       = $vid.imdb_id
                $videoYear    = if ($vid.release_date -match '(\d{4})') { $Matches[1] } else { "" }
                $needsReview  = $match.NeedsReview
                $matchMethod  = $match.Method
                $overview     = $vid.overview
            }

            $quality = switch ([int]$cut.Height) {
                { $_ -le 576 } { "SD"    }
                720            { "720p"  }
                1080           { "1080p" }
                2160           { "4K"    }
                default        { ""      }
            }

            $extendedSuffix = if ($mc.IsExtended) { " - {edition:Extended}" } else { "" }
            $reviewSuffix   = if ($needsReview)    { " [NeedsReview]" } else { "" }

            $yearPart        = if ($videoYear) { " ($videoYear)" } else { "" }
            $qualityPart     = if ($quality)   { " - $quality" }   else { "" }
            $encodingDir     = "$cleanTitle$yearPart$extendedSuffix {imdb-$imdbId}$reviewSuffix"
            $encodingName    = "$cleanTitle$yearPart$extendedSuffix$qualityPart"

            $nRColor = if ($needsReview) { "Yellow" } else { "DarkGray" }
            Write-Host ""
            Write-Host "--- $( if ($mc.IsExtended) { 'Extended Cut' } else { 'Theatrical Cut' } ) ---" -ForegroundColor $(if ($mc.IsExtended) { "Magenta" } else { "Cyan" })
            if ($null -ne $match) {
                Write-Host "Match: $($match.Video.title)$yearPart" -ForegroundColor Green
                Write-Host "Method: " -NoNewLine -ForegroundColor DarkGray
                Write-Host $matchMethod -NoNewLine -ForegroundColor $nRColor
                Write-Host " | Needs Review: " -NoNewLine -ForegroundColor DarkGray
                Write-Host $needsReview -ForegroundColor $nRColor
                if ($overview) {
                    Write-Host "Overview:" -ForegroundColor DarkGray
                    Write-Host (Out-WrapText -Text $overview)
                }
            } else {
                Write-Host "No TMDB match - flagged for review" -ForegroundColor Yellow
            }
            Write-Host "Title #$($cut.Index) | $($cut.Minutes) min | $($cut.Resolution)" -ForegroundColor DarkGray
            Write-Host "Encoding dir:  $encodingDir" -ForegroundColor DarkGray

            $fullPath = Join-Path $BaseOutputDir $encodingDir
            if (-not (Test-Path $fullPath)) {
                New-Item -Path $fullPath -ItemType Directory -Force | Out-Null
            } elseif ((Get-Item $fullPath).GetFileSystemInfos().Count -ne 0) {
                Write-Host "Directory already exists and contains files - ensure it is empty before ripping." -ForegroundColor Yellow
                Pause
                if (-not (Test-Path $fullPath)) { New-Item -Path $fullPath -ItemType Directory -Force | Out-Null }
                Write-Host "Continuing..."
            }

            # Always rip by specific title index since we've identified distinct cuts
            Write-Host "Starting rip of title $($cut.Index)..." -ForegroundColor Cyan
            $exitCode = Invoke-MakeMKVRip -EncodingName $encodingName -FullPath $fullPath -TitleIndex $cut.Index

            if ($exitCode -eq 0) {
                Write-Host "Rip Complete: $encodingName" -ForegroundColor Green
                Move-RippedFiles -FullPath $fullPath -EncodingName $encodingName -EncodingDir $encodingDir
            } else {
                Write-Warning "MakeMKV exited with code $exitCode for title $($cut.Index)"
            }
        }

        $lastTitle = $metadata.Title
        Write-Host "All features processed. Ejecting disc..." -ForegroundColor Cyan
        (New-Object -ComObject Shell.Application).Namespace(17).ParseName("$Drive").InvokeVerb("Eject")
		Start-Sleep -Milliseconds 5000
    }
    catch {
        Write-Error "Script failed: $($_.Exception.Message)"
    }
}

$host.ui.RawUI.WindowTitle = "Windows Powershell"

<# 
		Query results

adult             : False
backdrop_path     : /RA2FjGBj1zMEEblkcXkpTthXzK.jpg
genre_ids         : {12, 14}
id                : 602411
original_language : en
original_title    : Adventures of Aladdin
overview          : With the help of a magical lamp, an impoverished young man transforms himself into a prince in order to win the heart of a beautiful princess. A live-action retelling of the 1992 Disney film of the same name.
popularity        : 0.6534
poster_path       : /w900HA8MiAEDY3IQl6mz5JY916F.jpg
release_date      : 2019-05-14
title             : Adventures of Aladdin
video             : False
vote_average      : 3.891
vote_count        : 46



		Detailed Results

adult                 : False
backdrop_path         : /RA2FjGBj1zMEEblkcXkpTthXzK.jpg
belongs_to_collection :
budget                : 250000
genres                : {@{id=12; name=Adventure}, @{id=14; name=Fantasy}}
homepage              :
id                    : 602411
imdb_id               : tt9783778
origin_country        : {US}
original_language     : en
original_title        : Adventures of Aladdin
overview              : With the help of a magical lamp, an impoverished young man transforms himself into a prince in order to win the heart of a beautiful princess. A live-action retelling of the 1992 Disney film of the same name.
popularity            : 0.6534
poster_path           : /w900HA8MiAEDY3IQl6mz5JY916F.jpg
production_companies  : {@{id=1311; logo_path=/ic2bTizdzRLDVzAvN7MXdUg3WQV.png; name=The Asylum; origin_country=US}}
production_countries  : {@{iso_3166_1=US; name=United States of America}}
release_date          : 2019-05-14
revenue               : 0
runtime               : 87
spoken_languages      : {@{english_name=English; iso_639_1=en; name=English}}
status                : Released
tagline               : A whole new world of adventure
title                 : Adventures of Aladdin
video                 : False
vote_average          : 3.891
vote_count            : 46 
#>
