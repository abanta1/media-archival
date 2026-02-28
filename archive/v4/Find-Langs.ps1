# Path to your ffprobe tool
$FFprobePath = "G:\ffprobe.exe"

# Get all m4v files recursively
$files = Get-ChildItem -Path "." -Filter *.mkv.old -Recurse
$report = @()

Write-Host "Analyzing $($files.Count) files... This may take a few minutes." -ForegroundColor Cyan

foreach ($file in $files) {
    # 1. Run ffprobe to get JSON metadata
    $json = & $FFprobePath -v quiet -print_format json -show_streams -select_streams a "$($file.FullName)" | ConvertFrom-Json
    
    if (-not $json.streams) {
        $report += [PSCustomObject]@{
            FileName = $file.Name
            Index    = "N/A"
            TrackNum = "N/A"
            Format   = "NO AUDIO"
            Lang     = "N/A"
            Channels = "N/A"
        }
        continue
    }

    # 2. Iterate through audio streams and add to report
    foreach ($i in 0..($json.streams.Count - 1)) {
        $s = $json.streams[$i]
        $fmt = if ($s.profile) { $s.profile.ToLower() } else { $s.codec_name.ToLower() }
        $lang = if ($s.tags.language) { $s.tags.language.ToLower() } else { "und" }
        $cleanChannels = ($s.channels -replace '[^0-9.]', '') -as [double]

        $report += [PSCustomObject]@{
            FileName = $file.Name
            Index    = $i
            TrackNum = $i + 1
            Format   = $fmt
            Lang     = $lang
            Channels = $cleanChannels
        }
    }
}

# 3. Output the Final Table
$report | Format-Table -AutoSize
