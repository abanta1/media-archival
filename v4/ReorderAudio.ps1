# Define quality weights for scoring (Higher = Better)
$FormatWeights = @{
    "truehd"       = 100
    "dts-hd ma"    = 95
    "flac"         = 90
    "pcm_s16le"    = 85
    "lpcm"         = 85
    "dts-hd hra"   = 70
    "dts"          = 55
    "eac3"         = 50
    "ac3"          = 45
    "opus"         = 40
    "aac"          = 30
    "lc"           = 30
    "vorbis"       = 35
    "mp2"          = 25
    "dts express"  = 25
    "dts lbr"      = 25
    "wmapro"       = 30
    "wma"          = 20
    "mp3"          = 20
    "amr"          = 10
    "amr-wb"       = 15
}

function Write-Log($msg, $Color = "White") { Write-Host $msg -ForegroundColor $Color }

# Paths to your tools
$FFmpegPath = "G:\ffmpeg.exe"; $FFprobePath = "G:\ffprobe.exe"

$files = Get-ChildItem -Filter *.m4v
$totalFiles = $files.Count; $currentCount = 0; $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($file in $files) {
    $currentCount++; $percent = [Math]::Round(($currentCount / $totalFiles) * 100, 1)
    Write-Log "`n[$currentCount/$totalFiles] ($percent%) Analyzing: $($file.Name)" -Color Cyan
    
    $json = & $FFprobePath -v quiet -print_format json -show_streams -select_streams a "$($file.FullName)" | ConvertFrom-Json
    if (-not $json.streams) { continue }

    # 1. Parse and Score all tracks
    $allTracks = foreach ($i in 0..($json.streams.Count - 1)) {
        $s = $json.streams[$i]
        $fmt = if ($s.profile) { $s.profile.ToLower() } else { $s.codec_name.ToLower() }
        $lang = if ($s.tags.language) { $s.tags.language.ToLower() } else { "und" }
        [PSCustomObject]@{
            Index = $i; TrackNum = $i + 1; Format = $fmt; Language = $lang
            Channels = ($s.channels -replace '[^0-9.]', '') -as [double]
            Quality = if ($FormatWeights.ContainsKey($fmt)) { $FormatWeights[$fmt] } else { 0 }
        }
    }

    # 2. Containers
    $includeTracks = @(); $downmixTasks = @()
    $hasLosslessEng = $false; $hasLossySurroundEng = $false; $processedLanguages = @()

    # 3. ENGLISH Logic (Keep Lossless/Surround)
    $engTracks = $allTracks | Where-Object { $_.Language -eq "eng" -or $_.Language -eq "und" } | Sort-Object Quality -Descending
    foreach ($track in $engTracks) {
        if ($track.Quality -ge 95 -and $track.Channels -ge 5.1 -and -not $hasLosslessEng) {
            $includeTracks += $track; $hasLosslessEng = $true
            Write-Log "    Track $($track.TrackNum): $($track.Format) ($($track.Language)) - KEEP (Eng Lossless)" -Color Green
        }
        elseif ($track.Quality -ge 30 -and $track.Channels -ge 5.1 -and -not $hasLossySurroundEng) {
            if (-not $hasLosslessEng -or $track.Format -eq 'ac3') {
                $includeTracks += $track; $hasLossySurroundEng = $true
                Write-Log "    Track $($track.TrackNum): $($track.Format) ($($track.Language)) - KEEP (Eng Surround)" -Color Green
            }
        }
    }
    # Queue English Downmix
    if (($engTracks | Where-Object { $_.Channels -ge 5.1 }).Count -gt 0) {
        $bestEng = $engTracks | Sort-Object Quality -Descending | Select-Object -First 1
        $downmixTasks += [PSCustomObject]@{ SourceIdx = $bestEng.Index; Lang = $bestEng.Language; Title = "English Stereo (Downmix)" }
        $processedLanguages += "eng"; $processedLanguages += "und"
    }

    # 4. FOREIGN Logic (Stereo Only)
    $foreignLangs = $allTracks | Where-Object { $processedLanguages -notcontains $_.Language } | Select-Object -ExpandProperty Language -Unique
    foreach ($lang in $foreignLangs) {
        $langTracks = $allTracks | Where-Object { $_.Language -eq $lang } | Sort-Object Quality -Descending
        $existingStereo = $langTracks | Where-Object { $_.Channels -le 2.0 } | Select-Object -First 1
        if ($existingStereo) {
            $includeTracks += $existingStereo
            Write-Log "    Track $($existingStereo.TrackNum): $($existingStereo.Format) ($lang) - KEEP (Stereo)" -Color Yellow
        } else {
            $bestFor = $langTracks | Select-Object -First 1
            $downmixTasks += [PSCustomObject]@{ SourceIdx = $bestFor.Index; Lang = $lang; Title = "$lang Stereo (Downmix)" }
            Write-Log "    $lang : No Stereo found. Will downmix from Track $($bestFor.TrackNum)" -Color Magenta
        }
    }

    # 5. Build ENGLISH-FIRST FFmpeg Command
    $outputName = $file.FullName.Replace(".m4v", "_reordered.m4v")
    $ffmpegArgs = @("-i", "$($file.FullName)", "-map", "0:v:0")
    $currentOutIdx = 0

    # PHASE A: English Tracks
    $engToCopy = $includeTracks | Where-Object { $_.Language -eq "eng" -or $_.Language -eq "und" }
    foreach ($t in $engToCopy) {
        $ffmpegArgs += "-map"; $ffmpegArgs += "0:a:$($t.Index)"
        if ($t.Format -eq "pcm_s16le" -or $t.Format -eq "lpcm") {
            Write-Log "    Track $($t.TrackNum): pcm detected - Transcoding to AC3 5.1 for M4V Compatibility" -Color Yellow
            # Transcode PCM to AC3 to allow it into the M4V container
            $ffmpegArgs += "-c:a:$currentOutIdx"; $ffmpegArgs += "ac3"
            $ffmpegArgs += "-b:a:$currentOutIdx"; $ffmpegArgs += "640k" # High bitrate for 7.1
            if ($t.Channels -gt 6) {
                $ffmpegArgs += "-ac:a:$currentOutIdx"; $ffmpegArgs += "6"
                Write-Log "    Track $($t.TrackNum): $($t.Format) (7.1) - Downmixing to AC3 5.1 (640k)" -Color Yellow
            } else {
                Write-Log "    Track $($t.TrackNum): $($t.Format) (5.1) - Encoding to AC3 5.1 (640k)" -Color Yellow
            }
        } else {
            $ffmpegArgs += "-c:a:$currentOutIdx"; $ffmpegArgs += "copy"
        }
        $currentOutIdx++
    }
    foreach ($task in ($downmixTasks | Where-Object { $_.Lang -eq "eng" -or $_.Lang -eq "und" })) {
        $ffmpegArgs += "-map"; $ffmpegArgs += "0:a:$($task.SourceIdx)"
        $ffmpegArgs += "-c:a:$currentOutIdx"; $ffmpegArgs += "aac"; $ffmpegArgs += "-ac:a:$currentOutIdx"; $ffmpegArgs += "2"
        $ffmpegArgs += "-b:a:$currentOutIdx"; $ffmpegArgs += "192k"; $ffmpegArgs += "-metadata:s:a:$currentOutIdx"; $ffmpegArgs += "title=`"$($task.Title)`""; $currentOutIdx++
    }

    # PHASE B: Foreign Tracks
    $forToCopy = $includeTracks | Where-Object { $_.Language -ne "eng" -and $_.Language -ne "und" }
    foreach ($t in $forToCopy) {
        $ffmpegArgs += "-map"; $ffmpegArgs += "0:a:$($t.Index)"
        $ffmpegArgs += "-c:a:$currentOutIdx"; $ffmpegArgs += "copy"; $currentOutIdx++
    }
    foreach ($task in ($downmixTasks | Where-Object { $_.Lang -ne "eng" -and $_.Lang -ne "und" })) {
        $ffmpegArgs += "-map"; $ffmpegArgs += "0:a:$($task.SourceIdx)"
        $ffmpegArgs += "-c:a:$currentOutIdx"; $ffmpegArgs += "aac"; $ffmpegArgs += "-ac:a:$currentOutIdx"; $ffmpegArgs += "2"
        $ffmpegArgs += "-b:a:$currentOutIdx"; $ffmpegArgs += "192k"; $ffmpegArgs += "-metadata:s:a:$currentOutIdx"; $ffmpegArgs += "title=`"$($task.Title)`""; $currentOutIdx++
    }

    $ffmpegArgs += @("-c:v", "copy", "-map", "0:s?", "-c:s", "copy", "$outputName", "-y", "-stats")
    & $FFmpegPath $ffmpegArgs
}
