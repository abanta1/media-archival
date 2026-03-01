
$script:SessionLog = ".\unified_log_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
Set-Content -Path $script:SessionLog -Value "" -Encoding UTF8

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [string]$Color = "White",
        [switch]$NoNewLine,
        [switch]$NoTimeStamp,
        [switch]$NoHost
    )
    $timestamp = if ($NoTimeStamp) { "" } else { "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))]" }
    $logMessage = "$timestamp $Message"

    if (-not $NoHost) {
        Write-Host $logMessage -ForegroundColor $Color -NoNewline:($NoNewLine.IsPresent)
    }
    $logMessage | Out-File -FilePath $script:SessionLog -Append -Encoding UTF8
}

function Find-Tool {
    param(
        [string]$ExeName,
        [string[]]$SearchRoots
    )

    $found = foreach ($root in $SearchRoots) {
        if (Test-Path $root) {
            Get-ChildItem -Path $root -Recurse -Filter $ExeName -ErrorAction SilentlyContinue
        }
    }

    if (-not $found) { return $null }

    return ($found | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}

function Test-Dependency {
    param([Parameter(Mandatory=$true)][array]$Deps)

    Write-Log "Checking dependencies..." -Color Cyan
    $missing = foreach ($dep in $Deps) {
        $exists = (Test-Path $dep.Path -PathType Leaf)
        if (-not $exists) { 
            Write-Log "[-] $($dep.Name) NOT FOUND at: $($dep.Path)" -Color Yellow
            $dep.Name
        } else {
            Write-Log "[+] Found $($dep.Name)" -Color Green
        }
    }
    if ($missing){
        Throw "`nMissing: $($missing -join ', ')"
    }
}

function Get-Vid {
    param([Parameter(mandatory=$true)][string]$SrcDirPath,[string]$DstDirPath,[int]$VidCountIn)

    $results = @(Get-ChildItem -Path "$SrcDirPath" -Recurse -Include *.mkv,VIDEO_TS | Where-Object {
        $folderPart    = if ($_.Name -eq 'VIDEO_TS') { $_.Parent.Name }    else { $_.Directory.Name }
        $baseNamePart  = if ($_.Name -eq 'VIDEO_TS') { $_.Parent.Name }    else { $_.BaseName }
        $outBase       = "$DstDirPath\$folderPart\$baseNamePart"
        $outVob        = "$DstDirPath\VobSub\$folderPart\$baseNamePart"
        $exists = (Test-Path "$outBase.mkv") -or (Test-Path "$outBase.m4v") -or (Test-Path "$outVob.mkv") -or (Test-Path "$outVob.m4v")
        if ($exists) { Write-Log "    Skipping `"$baseNamePart`" - already exists" -Color Red }
        -not $exists
    } | Sort-Object { $_.Name -ne 'VIDEO_TS' }, Length)
    if ($VidCountIn -gt 0){
        $results = $results | Select-Object -First $VidCountIn
    }
    Write-Log "Found $($results.Count) videos to encode"
    if ($results.Count -eq 0) { Write-Log "No videos to encode, exiting" -Color Yellow; return @() }
    return $results
}

function Get-RawMetadata {
    param(
        [string]$VideoPath,
        [string]$handBrakePath,
        [string]$ffprobePath,
        [string]$mkvmergePath,
        [string]$mediaInfoPath,
        [string]$ffmpegPath
    )
    
    # Scan Once
    
    Write-Log "  Detecting metadata with multiple tools..." -Color Yellow

    <#
    Key Offsets for tools:
                                                MediaInfo               MKV-I       MKV-J           FF              HB
                                                media.track                         tracks        streams    TitleList.AudioList / TitleList.SubtitleList
    Description                              Stream        ID            Track         ID          Index           Track
    Video                                       0           1              0           0             0               -
    Audio                                       1           2              1           1             1               1
    Audio                                       2           3              2           2             2               2
    Audio                                       3           4              3           3             3               3
    Audio                                       4           5              4           4             4               4
    Audio                                       5           6              5           5             5               5
    Subtitle                                    6           7              6           6             6               1
    Subtitle                                    7           8              7           7             7               2
    Subtitle                                    8           9              8           8             8               3
    #>

    # Apply key index as TrackKey for each tool's output to simplify cross-referencing tracks across tools

    # HandBrake metadata scan
    # if needed in future, full scan
    # $hbScan = & $handBrakePath --scan -i $VideoPath 2>&1

    $miAudioTracks = @()
    $miSubTracks = @()
    $ffAudioTracks = @()
    $ffSubTracks = @()
    $mkvJAudioTracks = @()
    $mkvIAudioTracks = @()

    if ($handBrakePath -and (Test-Path $handBrakePath -PathType Leaf)) {
        Write-Log "   Retrieving HandBrake metadata" -Color Yellow
        try {
            $hbRawJson = & $handBrakePath --scan -i $VideoPath --json 2>&1
        } catch {
            Write-Log "  WARNING: HandBrake scan failed: $_" -Color Yellow
            $hbRawJson = @()
        }
        $hbJsonMarker = 'JSON Title Set:'
        $hbJoined = $hbRawJson -join "`n"
        $parts = $hbJoined -split [regex]::Escape($hbJsonMarker), 2
    } else {
        Write-Log "   HandBrake path not set or invalid (not a file), skipping scan" -Color Yellow
        $hbRawJson = @()
        $parts = @()
    }

    if ($parts.Count -eq 2) {
        $hbJsonContent = ($parts[1] -split 'HandBrake has exited\.', 2)[0].Trim()
        try {
            $hbJson = $hbJsonContent | ConvertFrom-Json
        } catch {
            Write-Log "ERROR: Failed to parse HandBrake JSON output" -Color Red
            $hbJson = $null
        }
    } else {
        Write-Log "ERROR: HandBrake JSON marker not found in output" -Color Red
        $hbJson = $null
    }

    $hbVideoRes = [PSCustomObject]@{
        Width = $hbJson.TitleList.Geometry.Width    
        Height = $hbJson.TitleList.Geometry.Height
    }
    
    if ($hbJson -and $hbJson.TitleList) {
        $hbAudioTracks = @($hbJson.TitleList.AudioList)
        $hbSubTracks = @($hbJson.TitleList.SubtitleList)
    } else {
        $hbAudioTracks = @()
        $hbSubTracks = @()
    }

    # Assign Track Key for HB
    for ($i = 0; $i -lt $hbAudioTracks.Count; $i++) {
        $hbAudioTracks[$i] | Add-Member -MemberType NoteProperty -Name "TrackKey" -Value ($i + 1)
    }
    for ($i = 0; $i -lt $hbSubTracks.Count; $i++) {
        $hbSubTracks[$i] | Add-Member -MemberType NoteProperty -Name "TrackKey" -Value ($hbAudioTracks.Count + $i + 1)
    }

    Write-Log "   Retrieving ffmpeg metadata" -Color Yellow
    $ffPacketInfo = @()
    $ffVideoRes = $null

    if ($ffprobePath -and (Test-Path $ffprobePath -PathType Leaf)) {
        # ffprobe metadata scan
        $ffPackets = & $ffprobePath -v error -count_packets -show_entries stream=index,codec_type,nb_read_packets -of default=noprint_wrappers=1 "$VideoPath" 2>&1
        
        for ($i = 0; $i -lt $ffPackets.Count; $i += 3) {
            $indexLine = $ffPackets[$i]
            $codecLine = $ffPackets[$i + 1]
            $packetLine = $ffPackets[$i + 2]

            $index = ($indexLine -split '=')[1].Trim()
            $codec = ($codecLine -split '=')[1].Trim()
            $packets = ($packetLine -split '=')[1].Trim()
            
            $ffPacketInfo += [PSCustomObject]@{
                Index = [int]$index
                CodecType = $codec
                PacketCount = [int]$packets
                TrackKey = 0
            }
        }

        # Assign Track Key for ffprobe packet info
        for ($i = 1; $i -lt $ffPacketInfo.Count; $i++) {
            $ffPacketInfo[$i].TrackKey = ($i)
        }

        try {
            $ffJson = ((& $ffprobePath -v error -show_streams -of json "$VideoPath") -join "`n") | ConvertFrom-Json
        } catch {
            Write-Log "ERROR: Failed to parse ffprobe JSON" -Color Red
            $ffJson = $null
        }

        $ffVideoRes = [PSCustomObject]@{
            Width = ($ffJson.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1 | ForEach-Object { $_.width })
            Height = ($ffJson.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1 | ForEach-Object { $_.height })
        }
        $ffAudioTracks = @($ffJson.streams | Where-Object codec_type -eq "audio")
        $ffSubTracks = @($ffJson.streams | Where-Object { $_.codec_type -eq "subtitle" })
    } else {
        Write-Log "   WARNING: ffprobe path not set or invalid, skipping" -Color Yellow
        $ffJson = $null
    }

    # Assign Track Key for ffprobe
    for ($i = 0; $i -lt $ffAudioTracks.Count; $i++) {
        $ffAudioTracks[$i] | Add-Member -MemberType NoteProperty -Name "TrackKey" -Value ($i + 1)
    }
    for ($i = 0; $i -lt $ffSubTracks.Count; $i++) {
        $ffSubTracks[$i] | Add-Member -MemberType NoteProperty -Name "TrackKey" -Value ($ffAudioTracks.Count + $i + 1)
    }

    Write-Log "   Retrieving MKVMerge metadata" -Color Yellow
    $mkvVideoRes = $null

    if ($mkvmergePath -and (Test-Path $mkvmergePath -PathType Leaf)) {
        # mkvmerge json metadata scan
        try {
            $mkvJson = ((& $mkvmergePath -J "$VideoPath") -join "`n") | ConvertFrom-Json
        } catch {
            Write-Log "ERROR: Failed to parse mkvmerge JSON" -Color Red
            $mkvJson = $null
        }

        $mkvVideoRes = [PSCustomObject]@{
            Width = ($mkvJson.tracks | Where-Object { $_.type -eq "video" } | Select-Object -First 1 | ForEach-Object { $_.properties.pixel_dimensions }) -split 'x' | Select-Object -First 1
            Height = ($mkvJson.tracks | Where-Object { $_.type -eq "video" } | Select-Object -First 1 | ForEach-Object { $_.properties.pixel_dimensions }) -split 'x' | Select-Object -Last 1
        }
        $mkvJAudioTracks = @($mkvJson.tracks | Where-Object { $_.type -eq "audio" })
        $mkvJSubTracks = @($mkvJson.tracks | Where-Object { $_.type -eq "subtitles" })

        # Assign Track Key for MKV-J
        for ($i = 0; $i -lt $mkvJAudioTracks.Count; $i++) {
            $mkvJAudioTracks[$i] | Add-Member -MemberType NoteProperty -Name "TrackKey" -Value ($i + 1)
        }
        for ($i = 0; $i -lt $mkvJSubTracks.Count; $i++) {
            $mkvJSubTracks[$i] | Add-Member -MemberType NoteProperty -Name "TrackKey" -Value ($mkvJAudioTracks.Count + $i + 1)
        }

        # mkvmerge -i metadata scan
        $mkvI = & $mkvmergePath -i "$VideoPath" 2>&1
        $mkvIAudioTracks = @(foreach ($line in $mkvI) {
            if ($line -match '^Track ID (\d+): audio \((.+)\)$') {
                [PSCustomObject]@{
                    MKVTrackID = [int]$matches[1]
                    Type = $matches[2].ToLower()
                }
            }
        })

        $mkvISubTracks = @(foreach ($line in $mkvI) {
            if ($line -match '^Track ID (\d+): subtitles \((.+)\)$') {
                [PSCustomObject]@{
                    MKVTrackID = [int]$matches[1]
                    Type = $matches[2].ToLower()
                }
            }
        })
    } else {
        Write-Log "   WARNING: mkvmerge path not set or invalid, skipping" -Color Yellow
        $mkvJSubTracks = @()
        $mkvJAudioTracks = @()
        $mkvIAudioTracks = @()
        $mkvISubTracks = @()
    }

    # Assign Track Key for MKV-I
    for ($i = 0; $i -lt $mkvIAudioTracks.Count; $i++) {
        $mkvIAudioTracks[$i] | Add-Member -MemberType NoteProperty -Name "TrackKey" -Value ($i + 1)
    }
    for ($i = 0; $i -lt $mkvISubTracks.Count; $i++) {
        $mkvISubTracks[$i] | Add-Member -MemberType NoteProperty -Name "TrackKey" -Value ($mkvIAudioTracks.Count + $i + 1)
    }

    Write-Log "   Retrieving MediaInfo metadata" -Color Yellow
    $miVideoRes = $null

    if ($mediaInfoPath -and (Test-Path $mediaInfoPath -PathType Leaf)) {
        # MediaInfo metadata scan
        $rawMi = (& $mediainfoPath --Output=JSON "$VideoPath") -join "`n"
        try {
            $miJson = $rawMi | ConvertFrom-Json
        } catch {
            Write-Log "ERROR: Failed to parse MediaInfo JSON" -Color Red
            $miJson = $null
        }

        $miVideoRes = [PSCustomObject]@{
            Width = $miJson.media.track | Where-Object { $_.'@type' -eq "Video" } | Select-Object -First 1 | ForEach-Object { $_.Width }
            Height = $miJson.media.track | Where-Object { $_.'@type' -eq "Video" } | Select-Object -First 1 | ForEach-Object { $_.Height }
        }

        $miAudioTracks = @($miJson.media.track | Where-Object { $_.'@type' -eq "Audio" })
        $miSubTracks = @($miJson.media.track | Where-Object { $_.'@type' -eq "Text" })
    } else {
        Write-Log "   WARNING: MediaInfo path not set or invalid, skipping" -Color Yellow
    }

    # Assign Track Key for MediaInfo
    for ($i = 0; $i -lt $miAudioTracks.Count; $i++) {
        $miAudioTracks[$i] | Add-Member -MemberType NoteProperty -Name "TrackKey" -Value ($i + 1)
    }
    for ($i = 0; $i -lt $miSubTracks.Count; $i++) {
        $miSubTracks[$i] | Add-Member -MemberType NoteProperty -Name "TrackKey" -Value ($miAudioTracks.Count + $i + 1)
    }

    return [PSCustomObject]@{
        HbAudio = $hbAudioTracks
        HbSubs = $hbSubTracks
        HbVideo = $hbVideoRes
        FfAudio = $ffAudioTracks
        FfSubs = $ffSubTracks
        FfVideo = $ffVideoRes
        FfPackets = $ffPacketInfo
        MkvJAudio = $mkvJAudioTracks
        MkvJSubs = $mkvJSubTracks
        MkvJVideo = $mkvVideoRes
        MkvIAudio = $mkvIAudioTracks
        MkvISubs = $mkvISubTracks
        MiAudio = $miAudioTracks
        MiSubs = $miSubTracks
        MiVideo = $miVideoRes
    }
}

function Get-AudioLRA {
    param(
        [string]$FilePath,
        [int]$StreamIndex,
        [string]$ffmpegPath
    )

    if (-not ($ffmpegPath -and (Test-Path $ffmpegPath -PathType Leaf))) {
        Write-Log "  WARNING: ffmpeg path invalid; LRA unavailable" -Color Yellow
        return 0
    }

    $cmd = "`"$ffmpegPath`" -t 180 -i `"$FilePath`" -map 0:a:$StreamIndex -af ebur128 -f null - 2>&1"
    $out = cmd /c $cmd
    $line = ($out | Select-String "LRA:" | Select-Object -Last 1).Line

    # Extract the actual LRA number
    $m = [regex]::Match($line, 'LRA:\s*(\d+(\.\d+)?)(?=\s*LU)')
    
    if ($m.Success) {
        return [double]$m.Groups[1].Value
    }

    return 0
}

function Get-CenterRMS {
    param(
        [string]$FilePath,
        [int]$TrackKey,
        [string]$ffmpegPath
    )

    if (-not ($ffmpegPath -and (Test-Path $ffmpegPath -PathType Leaf))) {
        Write-Log "  WARNING: ffmpeg path invalid; RMS unavailable" -Color Yellow
        return 0
    }

    $cmd = "`"$ffmpegPath`" -t 180 -i `"$FilePath`" -map 0:a:$TrackKey -af ebur128 -f null - 2>&1"
    $out = cmd /c $cmd

    $m = [regex]::Match($out, 'M:\s*(?<rms>-?\d+(\.\d+)?)')
    
    if ($m.Success) {
        return [double]$m.Groups['rms'].Value
    }

    return 0
}

function Get-SpectralFlatness {
    param(
        [string]$FilePath,
        [int]$StreamIndex,
        [string]$ffmpegPath
    )

    if (-not ($ffmpegPath -and (Test-Path $ffmpegPath -PathType Leaf))) {
        Write-Log "  WARNING: ffmpeg path invalid; spectral flatness unavailable" -Color Yellow
        return 0.0
    }

    $cmd = "`"$ffmpegPath`" -t 60 -i `"$FilePath`" -map 0:a:$StreamIndex -af `"astats=metadata=1:reset=1`" -f null - 2>&1"
    $out = cmd /c $cmd

    # Collect all flatness values
    $vals = @()
    foreach ($line in ($out -split "`n")) {
        if ($line -match "Spectral_flatness:\s*(\d+\.\d+)") {
            $vals += [double]$Matches[1]
        }
    }

    if ($vals.Count -eq 0) { return 0.0 }

    # Return median (robust against outliers)
    return ($vals | Sort-Object)[[int]($vals.Count/2)]
}

function Read-Srt {
    param([string]$srtPath)

    $content = Get-Content $srtPath -Raw
    $isSDH = ('\\[.*?\\]','\\(.*?\\)','j&','>>') | ForEach-Object { $content -match $_ } | Where-Object { $_ } | Select-Object -First 1
    $isCom = ('(?i)commentary','(?i)director','(?i)producer','(?i)behind the scenes') | ForEach-Object { $content -match $_ } | Where-Object { $_ } | Select-Object -First 1
    
    return @{ IsSDH=[bool]$isSDH; IsCommentary=[bool]$isCom; IsForced=$false }
}

function Read-VobSubIdx (){
    param([string]$idxPath)

    $info = @{ Language=""; IsoCode=""; IsForced=$false; IsSDH=$false; IsCommentary=$false }
    
    if (-not (Test-Path $idxPath)) { Write-Log "  WARNING: .idx not found: $idxPath" -Color Red; return $info }
    
    foreach ($line in (Get-Content $idxPath)) {
        if ($line -match '^id:\s*([a-z]{2,3})') { $info.IsoCode = $matches[1] } else { $info.Language = $info.IsoCode }
        if ($line -match '(?i)forced\s*subs:\s*on')             { $info.IsForced = $true }
        if ($line -match '(?i)(sdh|hearing.impaired|closed.caption|cc)') { $info.IsSDH = $true }
        if ($line -match '(?i)commentary')                       { $info.IsCommentary = $true }
    }
    
    if ($idxPath -match '(?i)(sdh|cc|hearing)') { $info.IsSDH = $true }
    if ($idxPath -match '(?i)commentary')        { $info.IsCommentary = $true }
    
    return $info
}

Export-ModuleMember -Function Write-Log, Find-Tool, Test-Dependency, Get-Vid, Get-RawMetadata, Get-AudioLRA, Get-CenterRMS, Get-SpectralFlatness, Read-Srt, Read-VobSubIdx