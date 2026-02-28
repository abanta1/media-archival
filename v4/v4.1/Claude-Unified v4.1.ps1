# ============================================
# Encode / SubReview / MetadataRemux - Unified Script
# ============================================
# Usage:
#   .\Claude-Unified.ps1                          # Default: encode workflow
#   .\Claude-Unified.ps1 -AnalyzeOnly             # Scan + plan, no encode
#   .\Claude-Unified.ps1 -SubReview               # VobSub manual review & remux
#   .\Claude-Unified.ps1 -SubReview -DryRun       # SubReview without writing files
#   .\Claude-Unified.ps1 -MetadataRemux           # Metadata track name fix (ffmpeg)
#   .\Claude-Unified.ps1 -MetadataRemux -DryRun   # MetadataRemux preview only
# ============================================
#
# Need to build a script to search all videos and report back all vids with subtitles that are forced/default
# Need to extract all text subs, analyze for SDH, Commentary, etc
# Need to extract spu subs to idx, analyze for SDH, Commentary, etc
#
#

param(
    [switch]$Encode,
	[switch]$AnalyzeOnly,
    [switch]$SubReview,
    [switch]$MetadataRemux,
    [switch]$DryRun,
	[Parameter(mandatory=$true)]
	[string]$SrcDir,
	[Parameter(mandatory=$true)]
	[string]$DstDir,
	[Parameter(mandatory=$true)]
	[string]$GbgDir
)

[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'

# ============================================
# Mode-specific paths  ! Edit these
# ============================================
$vobsubDir           = $SrcDir         # SubReview: input folder
$encodedBaseDir      = $DstDir         # SubReview: output root
$garbageBaseDir      = $GbgDir         # SubReview: garbage root
$classificationsFile = ".\vobsub_classifications.json"
$metaSourceDir       = $SrcDir         # MetadataRemux: input
$metaOutputDir       = $DstDir         # MetadataRemux: output

		# ============================================
		# Tier 0 - Environment / Runtime Guards
		# ============================================

function Find-Tool {
    param([string]$ExeName, [string[]]$SearchRoots)
    
    $found = foreach ($root in $SearchRoots) {
        if (Test-Path $root) {
            Get-ChildItem -Path $root -Recurse -Filter $ExeName -ErrorAction SilentlyContinue
        }
    }
    
    if (-not $found) { return $null }
    
    # If multiple found, return the newest by LastWriteTime
    return ($found | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}

$searchRoots = @("C:\AV Tools")

$ffmpegPath      = Find-Tool "ffmpeg.exe"       $searchRoots
$ffprobePath     = Find-Tool "ffprobe.exe"      $searchRoots
$mkvmergePath    = Find-Tool "mkvmerge.exe"     $searchRoots
$mkvextractPath  = Find-Tool "mkvextract.exe"   $searchRoots
$mkvpropeditPath = Find-Tool "mkvpropedit.exe"  $searchRoots
$handBrakePath   = Find-Tool "HandBrakeCLI.exe" $searchRoots
$mediaInfoPath   = Find-Tool "MediaInfo.exe"    $searchRoots

function Test-Dependency {
    param([array]$Deps)
    $missing = @()
    Write-Log "`nChecking dependencies..." -Color Cyan
    foreach ($dep in $Deps) {
        if (-not (Test-Path $dep.Path)) { $missing += "[-] $($dep.Name) NOT FOUND at: $($dep.Path)" }
        else { Write-Log "[+] Found $($dep.Name)" -Color Green }
    }
    if ($missing.Count -gt 0) {
        Write-Log "`nERROR: Missing Dependencies!" -Color Red
        $missing | ForEach-Object { Write-Log $_ -Color Yellow }
        exit
    }
    Write-Log "All dependencies verified.`n" -Color Cyan
}

		# ============================================
		# Tier 1 - Core Utilities
		# ============================================
		
$logFile = ".\unified_log_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
Set-Content -Path $logFile -Value "" -Encoding UTF8

function Write-Log {
    param([string]$Message, [string]$Color = "White", [switch]$NoNewLine, [switch]$NoTimeStamp, [switch]$NoHost)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
	$timestamp = "[$($timestamp)] "
	if ($NoTimeStamp) { $timestamp = $null }
    $logMessage = "$timestamp $Message"
    if (-not $NoHost){
        if ($NoNewLine) { Write-Host $logMessage -ForegroundColor $Color -NoNewLine }
        else            { Write-Host $logMessage -ForegroundColor $Color }
    }
    $logMessage | Out-File -FilePath $logFile -Append -Encoding UTF8
}

$langDisplayMap = @{
    "eng" = "English"; "fra" = "Français"; "spa" = "Español"
    "ita" = "Italiano"; "rus" = "Русский"; "deu" = "Deutsch"
}

function Convert-IsoCode ([string]$isoText) {
    switch ($isoText.ToLower()) {
        "en"  { "eng"; break }
        "eng" { "eng"; break }
        "fr"  { "fra"; break }
        "fre" { "fra"; break }
        "fra" { "fra"; break }
        "es"  { "spa"; break }
        "spa" { "spa"; break }
        "it"  { "ita"; break }
        "ita" { "ita"; break }
        "de"  { "deu"; break }
        "deu" { "deu"; break }
        "ru"  { "rus"; break }
        "rus" { "rus"; break }
        "ja"  { "jpn"; break }
        "ko"  { "kor"; break }
        "zh"  { "chi"; break }
        "pt"  { "por"; break }
        default { if ($isoText.Length -eq 3) { $isoText } else { "und" } }
    }
}

function Convert-IsoToLanguage ([string]$isoCode) {
    switch ($isoCode.ToLower()) {
        "eng"   { "English" }
        "fra"   { "French" }
        "spa"   { "Spanish" }
        "ita"   { "Italian" }
        "deu"   { "German" }
        "rus"   { "Russian" }
        "jpn"   { "Japanese" }
        "kor"   { "Korean" } 
        "chi"   { "Chinese" } 
        "por"   { "Portuguese" }
        default { "Unknown" }
    }
}

function Parse-Srt {
    param([string]$srtPath)
    $content = Get-Content $srtPath -Raw
    $isSDH = ('\\[.*?\\]','\\(.*?\\)','j&','>>') | ForEach-Object { $content -match $_ } | Where-Object { $_ } | Select-Object -First 1
    $isCom = ('(?i)commentary','(?i)director','(?i)producer','(?i)behind the scenes') | ForEach-Object { $content -match $_ } | Where-Object { $_ } | Select-Object -First 1
    return @{ IsSDH=[bool]$isSDH; IsCommentary=[bool]$isCom; IsForced=$false }
}

function Parse-VobSubIdx {
    param([string]$idxPath)
    $info = @{ Language=""; IsoCode=""; IsForced=$false; IsSDH=$false; IsCommentary=$false }
    if (-not (Test-Path $idxPath)) { Write-Log "  WARNING: .idx not found: $idxPath" -Color Red; return $info }
    foreach ($line in (Get-Content $idxPath)) {
        if ($line -match '^id:\s*([a-z]{2,3})') { $info.IsoCode = Convert-IsoCode $matches[1]; $info.Language = $info.IsoCode }
        if ($line -match '(?i)forced\s*subs:\s*on')             { $info.IsForced = $true }
        if ($line -match '(?i)(sdh|hearing.impaired|closed.caption|cc)') { $info.IsSDH = $true }
        if ($line -match '(?i)commentary')                       { $info.IsCommentary = $true }
    }
    if ($idxPath -match '(?i)(sdh|cc|hearing)') { $info.IsSDH = $true }
    if ($idxPath -match '(?i)commentary')        { $info.IsCommentary = $true }
    return $info
}

function Get-SubtitleHash {
    param([string]$basePath)
    foreach ($ext in @(".srt",".sup",".ass")) {
        $f = "$basePath$ext"
        if (Test-Path $f) {
            $bytes = [Text.Encoding]::UTF8.GetBytes((Get-Content $f -Raw -Encoding UTF8))
            return (Get-FileHash -InputStream ([IO.MemoryStream]::new($bytes))).Hash
        }
    }
    $idx = "$basePath.idx"; $sub = "$basePath.sub"
    if ((Test-Path $idx) -and (Test-Path $sub)) {
        return (Get-FileHash -InputStream ([IO.MemoryStream]::new([IO.File]::ReadAllBytes($sub)))).Hash
    }
    Write-Log "  WARNING: Could not hash subtitle at $basePath" -Color Red
    return ""
}

function Get-CenterRMS {
    param([string]$FilePath, [int]$TrackKey)

    $cmd = "`"$ffmpegPath`" -t 180 -i `"$FilePath`" -map 0:a:$TrackKey -af ebur128 -f null - 2>&1"
    $out = cmd /c $cmd

    $m = [regex]::Match($out, 'M:\s*(?<rms>-?\d+(\.\d+)?)')
    if ($m.Success) {
        return [double]$m.Groups['rms'].Value
    }

    return 0
}

function Get-AudioLRA {
    param([string]$FilePath, [int]$StreamIndex)

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
function Get-SpectralFlatness {
    param(
        [string]$FilePath,
        [int]$StreamIndex
    )

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

function Get-ADAnalysis {
    param(
        [array]$AudioTracks,
        [string]$FilePath
    )

    Write-Log " Detecting AD Track (unified)..." -Color Yellow

    # Candidates: English, non-commentary
    $eng = $AudioTracks | Where-Object { $_.IsEnglish.Value -and -not $_.IsCommentary.Value }
    
    if ($eng.Count -ne 2) {
        Write-Log "  INFO: Need exactly 2 English non-commentary tracks, found $($eng.Count) - skipping AD detection" -Color White -NoHost
        return $null
    }

    # --- FEATURE EXTRACTION --------------------------------------------------

    $f1_metaAD = if ($eng[0].IsAD.Value) { 1 } else { 0 }
    $f2_metaAD = if ($eng[1].IsAD.Value) { 1 } else { 0 }
    
    $f1_metaCom = if ($eng[0].IsCommentary.Value) { 1 } else { 0 }
    $f2_metaCom = if ($eng[1].IsCommentary.Value) { 1 } else { 0 }

    # Center RMS (5.1+)
    Write-Log "  Center channel RMS..." -Color Yellow
    if ($eng[0].Channels.Value -ge 5.1 -and $eng[1].Channels.Value -ge 5.1) {
        $r1 = Get-CenterRMS -FilePath $FilePath -TrackKey ($eng[0].TrackKey - 1)
        $r2 = Get-CenterRMS -FilePath $FilePath -TrackKey ($eng[1].TrackKey - 1)
        $maxR = [math]::Max($r1, $r2)
        $f1_rms = ($maxR - $r1) / 10
        $f2_rms = ($maxR - $r2) / 10
    } else {
        $f1_rms = 0; $f2_rms = 0
    }

    # LRA
    Write-Log "  Loudness Range (LRA)..." -Color Yellow
    $l1 = Get-AudioLRA -FilePath $FilePath -StreamIndex ($eng[0].TrackKey - 1)
    $l2 = Get-AudioLRA -FilePath $FilePath -StreamIndex ($eng[1].TrackKey - 1)
    $maxL = [math]::Max($l1, $l2)
    $f1_lra = ($maxL - $l1)
    $f2_lra = ($maxL - $l2)

    # Spectral flatness (stereo fallback)
    if ($eng[0].Channels.Value -le 2.0 -and $eng[1].Channels.Value -le 2.0) {
        $sf1 = Get-SpectralFlatness -FilePath $FilePath -StreamIndex ($eng[0].TrackNum - 1)
        $sf2 = Get-SpectralFlatness -FilePath $FilePath -StreamIndex ($eng[1].TrackNum - 1)
        $maxSF = [math]::Max($sf1, $sf2)
        $f1_sf = ($maxSF - $sf1) * 10
        $f2_sf = ($maxSF - $sf2) * 10
    } else {
        $f1_sf = 0; $f2_sf = 0
    }

    # Base from Detect-ADTrack
    $score1 = 10*$f1_metaAD - 4*$f1_metaCom + 7*$f1_rms + 5*$f1_lra + 4*$f1_sf
    $score2 = 10*$f2_metaAD - 4*$f2_metaCom + 7*$f2_rms + 5*$f2_lra + 4*$f2_sf

    $lraDelta = [math]::Abs($l1 - $l2)
    if ($lraDelta -gt 1.0) {
        if ($l1 -lt $l2) { $score1 += 7; } 
        else { $score2 += 7; } 
    }

    $delta = [math]::Abs($score1 - $score2)
    
    if ($delta -lt 3) {
        return $null
    }

    $winnerTrack = if ($score1 -gt $score2) { $eng[0] } else { $eng[1] }
    $confidence = if ($delta -ge 12) { 'High' } elseif ($delta -ge 6) { 'Medium' } else { 'Low' }

    [PSCustomObject]@{
        ADTrackNum = $winnerTrack.TrackKey
        Confidence = $confidence
        ScoreDelta = $delta
        Tracks     = @(
            [PSCustomObject]@{
                TrackKey = $eng[0].TrackKey
                Score   = $score1
                LRA     = $l1
                CenterRMS = $f1_rms
                MetaAD    = $f1_metaAD
                MetaCom   = $f1_metaCom
                Spectral  = $f1_sf
            },
            [PSCustomObject]@{
                TrackKey = $eng[1].TrackKey
                Score   = $score2
                LRA     = $l2
                CenterRMS = $f2_rms
                MetaAD    = $f2_metaAD
                MetaCom   = $f2_metaCom
                Spectral  = $f2_sf
            }
        )
    }
}

function Get-Metadata {
    param([string]$VideoPath)
    
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


    Write-Log "   Retreiving HandBrake metadata" -Color Yellow
    $hbRawJson = & $handBrakePath --scan -i $VideoPath --json 2>&1
    $hbJsonMarker = 'JSON Title Set:'
    $hbJoined = $hbRawJson -join "`n"
    $parts = $hbJoined -split [regex]::Escape($hbJsonMarker), 2

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
    $hbAudioTracks = @($hbJson.TitleList.AudioList)
    $hbSubTracks = @($hbJson.TitleList.SubtitleList)

    # Assign Track Key for HB
    for ($i = 0; $i -lt $hbAudioTracks.Count; $i++) {
        $hbAudioTracks[$i] | Add-Member -MemberType NoteProperty -Name "TrackKey" -Value ($i + 1)
    }
    for ($i = 0; $i -lt $hbSubTracks.Count; $i++) {
        $hbSubTracks[$i] | Add-Member -MemberType NoteProperty -Name "TrackKey" -Value ($hbAudioTracks.Count + $i + 1)
    }

    Write-Log "   Retreiving ffmpeg metadata" -Color Yellow
    # ffprobe metadata scan
    # $ff = & $ffprobePath -v error -show_streams "$VideoPath"
    $ffPackets = & $ffprobePath -v error -count_packets -show_entries stream=index,codec_type,nb_read_packets -of default=noprint_wrappers=1 "$VideoPath" 2>&1
    $ffPacketInfo = @()
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

    $ffJson = ((& $ffprobePath -v error -show_streams -of json "$VideoPath") -join "`n") | ConvertFrom-Json

    $ffVideoRes = [PSCustomObject]@{
        Width = ($ffJson.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1 | ForEach-Object { $_.width })
        Height = ($ffJson.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1 | ForEach-Object { $_.height })
    }
    $ffAudioTracks = @($ffJson.streams | Where-Object codec_type -eq "audio")

    $ffSubTracks = @($ffJson.streams | Where-Object { $_.codec_type -eq "subtitle" })

    # Assign Track Key for ffprobe
    for ($i = 0; $i -lt $ffAudioTracks.Count; $i++) {
        $ffAudioTracks[$i] | Add-Member -MemberType NoteProperty -Name "TrackKey" -Value ($i + 1)
    }
    for ($i = 0; $i -lt $ffSubTracks.Count; $i++) {
        $ffSubTracks[$i] | Add-Member -MemberType NoteProperty -Name "TrackKey" -Value ($ffAudioTracks.Count + $i + 1)
    }

    Write-Log "   Retreiving MKVMerge metadata" -Color Yellow
    # mkvmerge json metadata scan
    $mkvJson = ((& $mkvmergePath -J "$VideoPath") -join "`n") | ConvertFrom-Json

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

    # Assign Track Key for MKV-I
    for ($i = 0; $i -lt $mkvIAudioTracks.Count; $i++) {
        $mkvIAudioTracks[$i] | Add-Member -MemberType NoteProperty -Name "TrackKey" -Value ($i + 1)
    }
    for ($i = 0; $i -lt $mkvISubTracks.Count; $i++) {
        $mkvISubTracks[$i] | Add-Member -MemberType NoteProperty -Name "TrackKey" -Value ($mkvIAudioTracks.Count + $i + 1)
    }

    
    Write-Log "   Retreiving MediaInfo metadata" -Color Yellow
    # MediaInfo metadata scan
    $rawMi = (& $mediainfoPath --Output=JSON "$VideoPath") -join "`n"
    $miJson = $rawMi | ConvertFrom-Json

    $miVideoRes = [PSCustomObject]@{
        Width = $miJson.media.track | Where-Object { $_.'@type' -eq "Video" } | Select-Object -First 1 | ForEach-Object { $_.Width }
        Height = $miJson.media.track | Where-Object { $_.'@type' -eq "Video" } | Select-Object -First 1 | ForEach-Object { $_.Height }
    }

    $miAudioTracks = @($miJson.media.track | Where-Object { $_.'@type' -eq "Audio" })
    $miSubTracks = @($miJson.media.track | Where-Object { $_.'@type' -eq "Text" })

    # Assign Track Key for MediaInfo
    for ($i = 0; $i -lt $miAudioTracks.Count; $i++) {
        $miAudioTracks[$i] | Add-Member -MemberType NoteProperty -Name "TrackKey" -Value ($i + 1)
    }
    for ($i = 0; $i -lt $miSubTracks.Count; $i++) {
        $miSubTracks[$i] | Add-Member -MemberType NoteProperty -Name "TrackKey" -Value ($miAudioTracks.Count + $i + 1)
    }

    #
    # Functions for processing
    #
    function Get-QualityScore {
        param([string]$codec)
        if (-not $codec -or $null -eq $codec -or $codec -eq 0 -or $codec -eq "") { return 0 }
        
        $quality = switch -Regex ($format) {
                 '(?i)TrueHD|FLAC|LPCM|pcm_s16le|pcm_s24le'      { 100 }
                 '(?i)DTS-HD MA|DTS-MA|Master Audio'              { 95  }
                 '(?i)DTS-HD(?!\s*MA)'                           { 65  }
                 '(?i)DTS|dca'                                   { 60  }
                 '(?i)E-AC-3|EAC3|E-AC3|Dolby Digital Plus'      { 55  }
                 '(?i)AC3|Dolby Digital'                         { 50  }
                 '(?i)AAC'                                       { 30  }
                 '(?i)MP3'                                       { 20  }
                default                                          { 0   }
            }

        return $quality
    }

    function Convert-AudioCodecName {
        param([string]$codec)
        if (-not $codec -or $null -eq $codec -or $codec -eq 0 -or $codec -eq "") { return "unknown" }
        
        $newCodec = switch -Regex ($codec.ToLower()) {
            '(?i)mp3'                   {  "mp3" }
            '(?i)aac'                   {  "aac" }
            '(?i)ac3|ac-3|a_ac3'        {  "ac3" }
            '(?i)eac3'                  {  "eac3" }
            '(?i)truehd|true-hd'        {  "truehd" }
            '(?i)flac'                  {  "flac" }
            '(?i)lpcm'                  {  "lpcm" }
            '(?i)pcm_s16le'             {  "pcm_s16le" }
            '(?i)pcm_s24le'             {  "pcm_s24le" }
            default                     {  $codec.ToLower() }
        }

        return $newCodec
    }

    function Convert-SubCodecType {
        param([string]$codec)
        if (-not $codec -or $null -eq $codec -or $codec -eq 0 -or $codec -eq "") { return "unknown" }
        
        $newCodec = switch -Regex ($codec.ToLower()) {
            '(?i)vobsub'                {  "bitmap"; break }
            '(?i)pgs'                   {  "bitmap"; break }
            '(?i)hdmv_pgs_subtitle'     {  "bitmap"; break }
            '(?i)bitmap'                {  "bitmap"; break }
            '(?i)dvd_subtitle'          {  "bitmap"; break }

            '(?i)subrip|srt'            {  "text"; break }
            '(?i)ass'                   {  "text"; break }
            '(?i)ssa'                   {  "text"; break }
            '(?i)text'                  {  "text"; break }
            '(?i)utf'                   {  "text"; break }
            default                     {  "unknown" }
        }

        return $newCodec
    }

    function Convert-ChannelCount {
        param([double]$channels)
        $newChannel = switch ($channels) {
            {$_ -ge 7.1}  { "7.1"; break }
            {$_ -ge 5.1}  { "5.1"; break }
            {$_ -ge 2.0}  { "2.0"; break }
            {$_ -ge 1.0}  { "1.0"; break }
            default        { "0" }
        }

        return $newChannel
    }

    # Hybrid Scoring helper
    function Resolve-Field {
        param([string]$FieldName, [hashtable]$Values, [hashtable]$Weights)

        $clean = $Values.GetEnumerator() | Where-Object { $null -ne $_.Value -and "" -ne $_.Value -and !($_.Value -eq 0 -and $_.Value -isnot [bool]) }

        if ($clean.Count -eq 0) {
            return [PSCustomObject]@{
                Value = $null
                Confidence = "Low"
                Reason = "No tool provided $FieldName"
                Sources = $Values
            }
        }

        # All identical ?
        $unique = @($clean.Value | Select-Object -Unique)
        if ($unique.Count -eq 1) {
            return [PSCustomObject]@{
                Value      = $unique[0]
                Confidence = "High"
                Reason     = "All tools agree on $FieldName"
                Sources    = $Values
            }
        }

        # Two identical?
        $groups = $clean | Group-Object Value
        if ($groups.Count -eq 2 -and ($groups | Where-Object Count -eq 2)) {
            $val = ($groups | Where-Object Count -eq 2).Name
            return [PSCustomObject]@{
                Value      = $val
                Confidence = "Medium"
                Reason     = "Two tools agree on $FieldName"
                Sources    = $Values
            }
        }

        # Disagreement ! choose highest-weight tool
        $best = $clean | Sort-Object { $Weights[$_.Key] } -Descending | Select-Object -First 1

        return [PSCustomObject]@{
            Value      = $best.Value
            Confidence = "Low"
            Reason     = "Tools disagree; using highest-weight source ($($best.Key))"
            Sources    = $Values
        }
    }


    #
    # Audio processing
    #
    Write-Log "  Processing audio metadata..." -Color Green
    $hbAudioMetadata = @()
    if ($hbAudioTracks) {
        foreach ($track in $hbAudioTracks) {
            $trackLang = if (-not $track.Langauge) {
                if ($track.LangaugeCode) {
                    if ($track.LangaugeCode.Trim() -match '^[a-z]{2,3}$') {
                        $l = Convert-IsoCode $track.LangaugeCode.Trim().ToLower()
                        $tIsoCode = $l
                        Convert-IsoToLanguage $l
                    } else { "Unknown" }
                } else { "Unknown"}
            } else { $track.Language }

            $format = ($track.Description -replace '^[^(]+\(', '' -replace '\)$', '')
            $tCodec = Convert-AudioCodecName -codec $format
            $quality = Get-QualityScore -codec $tCodec
            $tIsoCode = Convert-IsoCode $track.LanguageCode

            $hbAudioMetadata += [PSCustomObject]@{
                IsAD = if ($null -ne $track.Attributes.VisualImpaired) { [bool]$track.Attributes.VisualImpaired } else { $false }
                Bitrate = $track.Bitrate
                Channels = Convert-ChannelCount $track.ChannelCount
                Codec = $track.CodecName
                IsCommentary = ($track.Attributes.Commentary) -or ($track.Name -match '(?i)commentary|director|producer|behind the scenes')
                IsEnglish = ($trackLang -eq "English") -or ($tIsoCode -eq "eng")
                IsDefault = if ($null -ne $track.Attributes.Default) { [bool]$track.Attributes.Default } else { $false }
                Description = $track.Description
                IsForced = if ($null -ne $track.Attributes.Forced) { [bool]$track.Attributes.Forced } else { $false }
                IsoCode = $tIsoCode
                Language = $trackLang
                Name = $track.Name
                Original = $track
                Quality = $quality
                TrackKey = $track.TrackKey
            }
        }
    }

    $ffAudioMetadata = @()
    foreach ($track in $ffAudioTracks) {
        $trackLang = if ($track.tags.language) {
            if ($track.tags.language.trim() -match '^[a-z]{2,3}$') {
                $l = Convert-IsoCode $track.tags.language.ToLower()
                $tIsoCode = $l
                Convert-IsoToLanguage $l
            } else { "Unknown" }
        } else { "Unknown" }

        $tCodec = Convert-AudioCodecName -codec $track.codec_name
        $quality = Get-QualityScore -codec $tCodec
        $tChannel = switch ($track.channels) {
                { $_ -ge 7.1 } { "7.1" }
                { $_ -ge 5.1 } { "5.1" }
                { $_ -ge 2.0 } { "2.0" }
                { $_ -ge 1.0 } { "1.0" }
                default        { "$($_) ch" }
            }
        $tBitRate = [math]::Round($track.bit_rate / 1000)


        $ffAudioMetadata += [PSCustomObject]@{
            IsAD = if ($null -ne $track.disposition.visual_impaired) { [bool]$track.disposition.visual_impaired } else { $false }
            BitRate = if ($track.bit_rate) { [int]$track.bit_rate } else { 0 }
            Channels = Convert-ChannelCount $track.Channels
            Codec = $tCodec
            IsCommentary = ($track.disposition.comment) -or ($track.tags.title -match '(?i)commentary|director|producer|behind the scenes')
            IsDefault = if ($null -ne $track.disposition.default) { [bool]$track.disposition.default } else { $false }
            Description = "$trackLang `($($track.codec_name.ToUpper()), $tChannel ch, $tBitRate kbps`)"
            IsEnglish = ($trackLang -eq "English") -or ($tIsoCode -eq "eng")
            IsForced = if ($null -ne $track.disposition.forced) { [bool]$track.disposition.forced } else { $false }
            IsoCode = Convert-IsoCode $track.tags.language
            Language = $trackLang
            Name = $track.tags.title
            Original = $track
            Quality = $null
            TrackKey = $track.TrackKey
            }
    }
    

    $mkvIAudioMetadata = @()
    foreach ($track in $mkvIAudioTracks) {
        $mkvIAudioMetadata += [PSCustomObject]@{
            TrackKey = $track.TrackKey
            Type = $track.Type
        }
    }

    $mkvJAudioMetadata = @()
    foreach ($track in $mkvJAudioTracks) {
        $trackLang = if ($track.properties.language) {
            if ($track.properties.language.trim() -match '^[a-z]{2,3}$') {
                $l = Convert-IsoCode $track.properties.language.ToLower()
                $tIsoCode = $l
                Convert-IsoToLanguage $l
            } else { "Unknown" }
        } else { "Unknown" }

        $tCodec = Convert-AudioCodecName -codec $track.codec
        $quality = Get-QualityScore -codec $tCodec
        $tChannel = switch ($track.channels) {
                { $_ -ge 7.1 } { "7.1" }
                { $_ -ge 5.1 } { "5.1" }
                { $_ -ge 2.0 } { "2.0" }
                { $_ -ge 1.0 } { "1.0" }
                default        { "$($_) ch" }
            }
            $tBitRate = [math]::Round($track.bit_rate / 1000)

        $mkvJAudioMetadata += [PSCustomObject]@{
            IsAD = $false # MKV-J doesn't provide AD info
            BitRate = $track.properties.tag_bps
            Channels = Convert-ChannelCount $track.properties.audio_channels
            Codec = $tCodec
            IsCommentary = ($track.properties.track_name -match '(?i)commentary|director|producer|behind the scenes')
            IsDefault = if ($null -ne $track.properties.default_track) { [bool]$track.properties.default_track } else { $false }
            Description = "$trackLang `($($track.codec.ToUpper()), $tChannel ch, $tBitRate kbps`)"
            IsEnglish = ($trackLang -eq "English") -or ($tIsoCode -eq "eng")
            IsForced = if ($null -ne $track.properties.forced_track) { [bool]$track.properties.forced_track } else { $false }
            IsoCode = Convert-IsoCode $track.properties.language
            Language = $trackLang
            Name = $track.properties.track_name
            Original = $track
            Quality = $quality
            TrackKey = $track.TrackKey
        }
    }

    $miAudioMetadata = @()
    foreach ($track in $miAudioTracks) {
        $trackLang = if ($track.Language) {
            if ($track.Language.trim() -match '^[a-z]{2,3}$') {
                $l = Convert-IsoCode $track.Language.ToLower()
                $tIsoCode = $l
                Convert-IsoToLanguage $l
            } else { "Unknown" }
        } else { "Unknown" }

        $tCodec = Convert-AudioCodecName -codec $track.Format
        $quality = Get-QualityScore -codec $tCodec
        $tChannel = switch ($track.channels) {
                { $_ -ge 7.1 } { "7.1" }
                { $_ -ge 5.1 } { "5.1" }
                { $_ -ge 2.0 } { "2.0" }
                { $_ -ge 1.0 } { "1.0" }
                default        { "$($_) ch" }
            }
            $tBitRate = [math]::Round($track.bit_rate / 1000)

        $miAudioMetadata += [PSCustomObject]@{
            IsAD = $false # MediaInfo doesn't provide AD info
            Bitrate = if ($track.BitRate) { [int]$track.BitRate } else { 0 }
            Channels = Convert-ChannelCount $track.Channels
            Codec = $tCodec
            IsCommentary = ($track.Title -match '(?i)commentary|director|producer|behind the scenes')
            IsDefault = if ($null -ne $track.Default) { [bool]$track.Default } else { $false }
            Description = "$trackLang `($($track.Format.ToUpper()), $tChannel ch, $tBitRate kbps`)"
            IsEnglish = ($trackLang -eq "English") -or ($tIsoCode -eq "eng")
            IsForced = if ($null -ne $track.Forced) { [bool]$track.Forced } else { $false }
            IsoCode = Convert-IsoCode $track.Language.ToLower()
            Language = $trackLang
            Name = $track.Title
            Original = $track
            Quality = $quality
            TrackKey = $track.TrackKey
        }
    }

    # Merge ffprobe, mkvmerge, MediaInfo with HandBrake data and apply hybrid scoring to resolve conflicts

    $weights = @{
        HandBrake = 1
        MediaInfo = 3
        MKVMerge = 4
        FFProbe = 5
    }

    $vidTracks = @()
    foreach ($track in $hbVideoRes) {
        $height = Resolve-Field "Video Height" @{
            HandBrake = $track.Height
            MediaInfo = $miVideoRes.Height
            MKVMerge = $mkvVideoRes.Height
            FFProbe = $ffVideoRes.Height
         } $weights

         $width = Resolve-Field "Video Width" @{
            HandBrake = $track.Width
            MediaInfo = $miVideoRes.Width
            MKVMerge = $mkvVideoRes.Width
            FFProbe = $ffVideoRes.Width
         } $weights

         $vidTracks += [PSCustomObject]@{
            Width = $width
            Height = $height
        }
    }

    $unifiedVideo = $vidTracks

    $tracks = @()
    $index = 0

    foreach ($track in $ffAudioTracks) {

        $key = $track.TrackKey

        $miam = $miAudioMetadata | Where-Object { $_.TrackKey -eq $key } | Select-Object -First 1
        #$mkviam = $mkvIAudioMetadata | Where-Object { $_.TrackKey -eq $key } | Select-Object -First 1
        $mkvjam = $mkvJAudioMetadata | Where-Object { $_.TrackKey -eq $key } | Select-Object -First 1
        $hbam  = $hbAudioMetadata  | Where-Object { $_.TrackKey -eq $key } | Select-Object -First 1
        $ffam  = $ffAudioMetadata  | Where-Object { $_.TrackKey -eq $key } | Select-Object -First 1

        $ad = Resolve-Field "AD" @{
            HandBrake = if ($null -ne $hbam.IsAD) { [bool]$hbam.IsAD } else { $false }
            MediaInfo = if ($null -ne $miam.IsAD) { [bool]$miam.IsAD } else { $false }
            MKVMerge = if ($null -ne $mkvjam.IsAD) { [bool]$mkvjam.IsAD } else { $false }
            FFProbe = if ($null -ne $ffam.IsAD) { [bool]$ffam.IsAD } else { $false }
        } $weights

        $bitrate = Resolve-Field "Bitrate" @{
            HandBrake = $hbam.BitRate
            MediaInfo = $miam.BitRate
            MKVMerge = $mkvjam.BitRate
            FFProbe = $ffam.BitRate
        } $weights

        $channels = Resolve-Field "Channels" @{ # 6 (5.1)
            HandBrake = $hbam.Channels
            MediaInfo = $miam.Channels
            MKVMerge = $mkvjam.Channels
            FFProbe = $ffam.Channels
        } $weights

        $codec = Resolve-Field "Codec" @{
            HandBrake = $hbam.Codec
            MediaInfo = $miam.Codec
            MKVMerge = $mkvjam.Codec
            FFProbe = $ffam.Codec
        } $weights

        $commentary = Resolve-Field "Commentary" @{
            HandBrake = if ($null -ne $hbam.IsCommentary) { [bool]$hbam.IsCommentary } else { $false }
            MediaInfo = if ($null -ne $miam.IsCommentary) { [bool]$miam.IsCommentary } else { $false }
            MKVMerge = if ($null -ne $mkvjam.IsCommentary) { [bool]$mkvjam.IsCommentary } else { $false }
            FFProbe = if ($null -ne $ffam.IsCommentary) { [bool]$ffam.IsCommentary } else { $false }
        } $weights

        $default = Resolve-Field "Default" @{
            HandBrake = if ($null -ne $hbam.IsDefault) { [bool]$hbam.IsDefault } else { $false }
            MediaInfo = if ($null -ne $miam.IsDefault) { [bool]$miam.IsDefault } else { $false }
            MKVMerge = if ($null -ne $mkvjam.IsDefault) { [bool]$mkvjam.IsDefault } else { $false }
            FFProbe = if ($null -ne $ffam.IsDefault) { [bool]$ffam.IsDefault } else { $false }
        } $weights

        $description = Resolve-Field "Description" @{
            HandBrake = $hbam.Description
            MediaInfo = $miam.Description
            MKVMerge = $mkvjam.Description
            FFProbe = $ffam.Description
        } $weights

        $english = Resolve-Field "English" @{
            HandBrake = if ($null -ne $hbam.IsEnglish) { [bool]$hbam.IsEnglish } else { $false }
            MediaInfo = if ($null -ne $miam.IsEnglish) { [bool]$miam.IsEnglish } else { $false }
            MKVMerge = if ($null -ne $mkvjam.IsEnglish) { [bool]$mkvjam.IsEnglish } else { $false }
            FFProbe = if ($null -ne $ffam.IsEnglish) { [bool]$ffam.IsEnglish } else { $false }
        } $weights
        
        $forced = Resolve-Field "Forced" @{
            HandBrake = if ($null -ne $hbam.IsForced) { [bool]$hbam.IsForced } else { $false }
            MediaInfo = if ($null -ne $miam.IsForced) { [bool]$miam.IsForced } else { $false }
            MKVMerge = if ($null -ne $mkvjam.IsForced) { [bool]$mkvjam.IsForced } else { $false }
            FFProbe = if ($null -ne $ffam.IsForced) { [bool]$ffam.IsForced } else { $false }
        } $weights

        $iso = Resolve-Field "IsoCode" @{
            HandBrake = $hbam.IsoCode
            MediaInfo = $miam.IsoCode
            MKVMerge = $mkvjam.IsoCode
            FFProbe = $ffam.IsoCode
        } $weights

        $lang = Resolve-Field "Language" @{
            HandBrake = $hbam.Language
            MediaInfo = $miam.Language
            MKVMerge = $mkvjam.Language
            FFProbe = $ffam.Language
        } $weights

        $name = Resolve-Field "Name" @{
            HandBrake = $hbam.Name
            MediaInfo = $miam.Name
            MKVMerge = $mkvjam.Name
            FFProbe = $ffam.tags.title
        } $weights

        $quality = Resolve-Field "Quality" @{
            HandBrake = $hbam.Quality
            MediaInfo = $miam.Quality
            MKVMerge = $mkvjam.Quality
            FFProbe = $ffam.Quality
        } $weights

        $tracks += [PSCustomObject]@{
            IsAD         = $ad.Value
            Bitrate      = $bitrate.Value
            Channels     = $channels.Value
            Codec        = $codec.Value
            IsCommentary = $commentary.Value
            IsDefault    = $default.Value
            Description  = $description.Value
            IsEnglish    = $english.Value
            IsForced     = $forced.Value
            IsoCode      = $iso.Value
            Language     = $lang.Value
            Name         = $name.Value
            Original     = $track
            Quality      = $quality.Value
            TrackKey     = $key
        }
    }

    # Audio return 
    $unifiedAudio = [PSCustomObject]@{
        Tracks = $tracks
        HasAtmos = ($tracks | Where-Object { $_.Codec -match 'truehd|eac3' -and $_.Original -match 'Atmos' }).Count -gt 0
        HasLossless = ($tracks | Where-Object { $_.Codec -match 'truehd|flac|lpcm|pcm_s16le|pcm_s24le|dts-hd' }).Count -gt 0
    }
    
    
    #
    #
    #   # SUBTITLE TRACKS
    #
    #
    
    Write-Log "  Processing subtitle metadata..." -Color Green

    # HandBrake
    $hbSubMetadata = @()
    foreach ($track in $hbSubTracks) {
        $tsType = Convert-SubCodecType $track.Format
        if ($tsType -eq "bitmap") {
            $tIsText = $false
        } elseif ($tsType -eq "text") {
            $tIsText = $true
        } else {
            Write-Warning "Unknown subtitle codec '$($track.Format)' in HandBrake track $($track.TrackKey)"
            $tIsText = $null
        }

        $hbSubMetadata += [PSCustomObject]@{
            TrackKey = $track.TrackKey -split " " | Select-Object -First 1
            Language = $track.Language
            IsoCode = Convert-IsoCode $track.LanguageCode
            CodecID = $track.SourceName.ToLower()
            Forced = $track.Attributes.Forced
            Default = $track.Attributes.Default
            IsSDH = $false # HandBrake doesn't provide SDH info
            FrameCount = 0 # HandBrake doesn't provide frame count info
            IsText = $tIsText
            IsBitmap = -not $tIsText
        }
    }
    
    # FFProbe
    $ffSubMetadata = @()
    foreach ($track in $ffSubTracks) {
        $iso = Convert-IsoCode $track.tags.language.ToLower()
        $tlang = if ($iso) {
            Convert-IsoToLanguage (Convert-IsoCode $track.tags.language.ToLower())
        } else { "Unknown" }

        $tsType = Convert-SubCodecType $track.codec_name
        if ($tsType -eq "bitmap") {
            $tIsText = $false
        } elseif ($tsType -eq "text") {
            $tIsText = $true
        } else {
            Write-Warning "Unknown subtitle codec '$($track.codec_name)' in FFProbe track $($track.TrackKey)"
            $tIsText = $null
        }

        $ffSubMetadata += [PSCustomObject]@{
            TrackKey = $track.TrackKey
            Language = $tlang
            IsoCode = Convert-IsoCode $track.tags.language.ToLower()
            CodecID = $track.codec_name
            Forced = $track.disposition.forced
            Default = $track.disposition.default
            IsSDH = $track.disposition.hearing_impaired
            FrameCount = ($ffPacketInfo | Where-Object { $_.TrackKey -eq $track.TrackKey }).PacketCount
            IsText = $tIsText
            IsBitmap = -not $tIsText
        }
    }

    # MKVMerge -J
    $mkvJSubMetadata = @()
    foreach ($track in $mkvJSubTracks) {
            $iso = Convert-IsoCode $track.properties.language
            $tlang = Convert-IsoToLanguage $iso.ToLower()

            $fc = 0
            if ($track.properties.tag_number_of_frames) {
                $fc = [int]$track.properties.tag_number_of_frames
            } elseif ($track.properties.number_of_frames) {
                $fc = [int]$track.properties.number_of_frames
            } elseif ($track.properties.num_index_entries) {
                $fc = [int]$track.properties.num_index_entries
            }

            $tsType = Convert-SubCodecType $track.codec
            if ($tsType -eq "bitmap") {
                $tIsText = $false
            } elseif ($tsType -eq "text") {
                $tIsText = $true
            } else {
                Write-Warning "Unknown subtitle codec '$($track.codec)' in HandBrake track $($track.TrackKey)"
                $tIsText = $null
            }

            $mkvJSubMetadata += [PSCustomObject]@{
                TrackKey = $track.TrackKey
                IsoCode = $iso
                Language = $tlang
                CodecID = $track.codec_id
                Forced = $track.properties.forced -eq '1'
                Default = $track.properties.default -eq '1' 
                FrameCount = $fc
                IsSDH = $false # MKV-J doesn't provide SDH info
                IsText = $tIsText
                IsBitmap = -not $tIsText
            }
    }

    # MKVMerge -i
    $mkvISubs = @()
    #$subIdx = 0
    foreach ($track in $mkvISubTracks) {
        $tsType = Convert-SubCodecType $track.Type
        if ($tsType -eq "bitmap") {
            $tIsText = $false
        } elseif ($tsType -eq "text") {
            $tIsText = $true
        } else {
            Write-Warning "Unknown subtitle codec '$($track.Type)' in HandBrake track $($track.TrackKey)"
            $tIsText = $null
        }

        $mkvISubs += [PSCustomObject]@{
            TrackKey = $track.TrackKey
            IsoCode = $null # MKV-I doesn't provide language info
            Language = $null # MKV-I doesn't provide language info
            CodecID = $null # MKV-I doesn't provide codec info
            Forced = $null # MKV-I doesn't provide forced flag
            Default = $null # MKV-I doesn't provide default flag
            FrameCount = $null # MKV-I doesn't provide frame count info
            IsSDH = $null # MKV-I doesn't provide SDH info
            IsText = $tIsText
            IsBitmap = -not $tIsText
            Type = $track.Type
            #SubIndex = $subIdx
        }
        #$subIdx++
    }

    # MediaInfo
    $miSubs = @()
    $miIndex = 0
    foreach ($track in $miSubTracks) {
            $miIndex++
            $iso = Convert-IsoCode $track.Language
            $tlang = if ($iso) {
                Convert-IsoToLanguage (Convert-IsoCode $track.Language.ToLower())
            } else { "Unknown" }

            $tsType = Convert-SubCodecType $track.Format
            if ($tsType -eq "bitmap") {
                $tIsText = $false
            } elseif ($tsType -eq "text") {
                $tIsText = $true
            } else {
                Write-Warning "Unknown subtitle codec '$($track.Format)' in HandBrake track $($track.TrackKey)"
                $tIsText = $null
            }

            $miSubs += [PSCustomObject]@{
                TrackKey = $track.TrackKey
                IsoCode = $iso
                Language = $tlang
                FrameCount = if ($track.ElementCount) { [int]$track.ElementCount } else { 0 }
                Forced = $track.Forced -eq 'Yes'
                Default = $track.Default -eq 'Yes' 
                Title = $track.Title
                Format = $track.Format
                CodecID = $track.CodecID
                StreamSize = if ($track.StreamSize) { [int]$track.StreamSize } else { 0 }
                IsSDH = $false # MediaInfo doesn't provide SDH info
                IsText = $tIsText
                IsBitmap = -not $tIsText
            }
    }

    # Merge + hybrid score for all fields
    $unifiedSubs = @()

    foreach ($miTrack in $miSubs) {
        $mkvJMatch = $mkvJSubs | Where-Object { $_.TrackKey -eq $miTrack.TrackKey } | Select-Object -First 1
        $mkvIMatch = $mkvISubs | Where-Object { $_.TrackKey -eq $miTrack.TrackKey } | Select-Object -First 1
        $ffMatch = $ffSubMetadata | Where-Object { $_.TrackKey -eq $miTrack.TrackKey } | Select-Object -First 1
        $ffPMatch = $ffPacketInfo | Where-Object { $_.TrackKey -eq $miTrack.TrackKey } | Select-Object -First 1
        $hbMatch = $hbSubMetadata | Where-Object { $_.TrackKey -eq $miTrack.TrackKey } | Select-Object -First 1

        # Hybrid scoring for each field
        $ec = Resolve-Field "ElementCount" @{
            MediaInfo = $miTrack.ElementCount
            MKVMerge = $mkvJMatch.FrameCount
            FFProbe = $ffPMatch.PacketCount
            HandBrake = $hbMatch.FrameCount
        } $weights

        $forced = Resolve-Field "Forced" @{
            MediaInfo = $miTrack.Forced
            MKVMerge = $mkvJMatch.Forced
            FFProbe = if ($ffMatch -and $ffMatch.disposition) { $ffMatch.disposition.forced } else { $null }
            HandBrake = $hbMatch.Forced
        } $weights

        $default = Resolve-Field "Default" @{
            MediaInfo = $miTrack.Default
            MKVMerge = $mkvJMatch.Default
            FFProbe = if ($ffMatch -and $ffMatch.disposition) { $ffMatch.disposition.default } else { $null }
            HandBrake = $hbMatch.Default
        } $weights

        $lang = Resolve-Field "Language" @{
             MediaInfo = $miTrack.Language
             MKVMerge = $mkvJMatch.IsoCode
             FFProbe = if ($ffMatch -and $ffMatch.tags) { $ffMatch.tags.language } else { $null }
             HandBrake = $hbMatch.Language
        } $weights

        $format = Resolve-Field "Format" @{
             MediaInfo = $miTrack.Format
             MKVMerge = $mkvJMatch.CodecID
             FFProbe = if ($ffMatch) { $ffMatch.codec_name } else { $null }
             HandBrake = $hbMatch.CodecID
        } $weights

        $codec = Resolve-Field "CodecID" @{
             MediaInfo = $miTrack.CodecID
             MKVMerge = $mkvJMatch.CodecID
             FFProbe = if ($ffMatch) { $ffMatch.codec_name } else { $null }
             HandBrake = $hbMatch.CodecID
        } $weights

        $text = Resolve-Field "Text" @{
             MediaInfo = $miTrack.IsText
             MKVMerge = $mkvJMatch.IsText
             FFProbe = $ffMatch.IsText
             HandBrake = $hbMatch.IsText
        } $weights

        $bitmap = Resolve-Field "Bitmap" @{
             MediaInfo = $miTrack.IsBitmap
             MKVMerge = $mkvJMatch.IsBitmap
             FFProbe = $ffMatch.IsBitmap
             HandBrake = $hbMatch.IsBitmap
        } $weights

        $miIso = Convert-IsoCode $miTrack.IsoCode
        $mkvJIso = Convert-IsoCode $mkvJMatch.IsoCode
        $ffIso = Convert-IsoCode $ffMatch.IsoCode
        $hbIso = Convert-IsoCode $hbMatch.IsoCode

        $isoCode = Resolve-Field "IsoCode" @{
             MediaInfo = $miIso
             MKVMerge = $mkvJIso
             FFProbe = $ffIso
             HandBrake = $hbIso
        } $weights

        # Track level confidence rollup

        $confLevels = @($ec.Confidence, $forced.Confidence, $default.Confidence, $lang.Confidence, $format.Confidence, $codec.Confidence, $text.Confidence, $bitmap.Confidence)
        $trackConf = if ($confLevels -contains "Low") {
            "Low"
        } elseif ($confLevels -contains "Medium") {
            "Medium"
        } else {
            "High"
        }

        # Unified object
        $unifiedSubs += [PSCustomObject]@{
                TrackKey = $miTrack.TrackKey
                MKVTrackID = $mkvIMatch.MKVTrackID
                MKVOrder = $mkvIMatch.SubIndex

                Language = $lang
                LanguageConfidence = $lang.Confidence
                LanguageReason = $lang.Reason

                Forced = $forced.Value
                ForcedConfidence = $forced.Confidence
                ForcedReason = $forced.Reason

                Default = $default.Value
                DefaultConfidence = $default.Confidence
                DefaultReason = $default.Reason

                Format = $format.Value
                FormatConfidence = $format.Confidence
                FormatReason = $format.Reason

                CodecID = $codec.Value
                CodecIDConfidence = $codec.Confidence
                CodecIDReason = $codec.Reason

                ElementCount = $ec.Value
                ElementCountConfidence = $ec.Confidence
                ElementCountReason = $ec.Reason

                IsoCode = $isoCode.Value
                IsoCodeConfidence = $isoCode.Confidence
                IsoCodeReason = $isoCode.Reason

                StreamSize = $miTrack.StreamSize
                Title = $miTrack.Title

                IsBitmap = $bitmap.Value
                IsBitmapConfidence = $bitmap.Confidence
                IsBitmapReason = $bitmap.Reason
                
                IsText = $text.Value
                IsTextConfidence = $text.Confidence
                IsTextReason = $text.Reason

                TrackConfidence = $trackConf
            }
    }

    return [PSCustomObject]@{
        Subtitles = $unifiedSubs
        Audio = $unifiedAudio
        Video = $unifiedVideo
    }
}

function Get-SubtitleClassification {
    param([object]$Subtitle, [array]$AllSubtitles)
    $ec  = $Subtitle.ElementCount
    $iso = $Subtitle.IsoCode

    if ($Subtitle.Forced) {
        return @{ Type="$(if($iso -eq 'eng'){'forced'}else{'forced-foreign'})"; NameType="Forced"; Confidence="High"; Reason="Forced flag in metadata"; Default=$Subtitle.Default }
    }
    if ($Subtitle.Title -match '(?i)\b(SDH|CC|Closed Caption|Hearing Impaired)\b') {
        return @{ Type="sdh"; NameType="SDH"; Confidence="High"; Reason="Title contains SDH/CC marker"; Default=$Subtitle.Default }
    }
    if ($Subtitle.Title -match '(?i)\b(Commentary|Director|Producer)\b') {
        return @{ Type="commentary"; NameType="Commentary"; Confidence="High"; Reason="Title contains Commentary marker"; Default=$Subtitle.Default }
    }
    
    if ($iso -ne "eng") {
        if ($ec -gt 0 -and $ec -lt 200) { $Subtitle.Forced = $true; return @{ Type="forced-foreign"; NameType="Forced"; Confidence="High"; Reason="Very low element count ($ec)"; Default=$Subtitle.Default } }
        return @{ Type="foreign"; NameType="Standard"; Confidence="High"; Reason="Foreign language standard track"; Default=$Subtitle.Default }
    }
    if ($ec -eq 0) { return @{ Type="standard"; NameType="Standard"; Confidence="Low"; Reason="No element count available"; Default=$Subtitle.Default } }
    if ($ec -lt 200) { $Subtitle.Forced = $true; return @{ Type="forced"; NameType="Forced"; Confidence="High"; Reason="Very low element count ($ec)"; Default=$Subtitle.Default } }

    $engTracks = @($AllSubtitles | Where-Object { ($_.IsoCode -eq "eng") -and $_.ElementCount -gt 399 })
    if ($engTracks.Count -eq 0) { return @{ Type="standard"; NameType="Standard"; Confidence="Low"; Reason="No other English tracks for comparison"; Default=$Subtitle.Default } }

    $avg = ($engTracks | Measure-Object -Property ElementCount -Average).Average
    $min = ($engTracks | Measure-Object -Property ElementCount -Minimum).Minimum
    $max = ($engTracks | Measure-Object -Property ElementCount -Maximum).Maximum

    if ($ec -gt ($avg * 2.5)) { return @{ Type="commentary"; NameType="Commentary"; Confidence="High"; Reason="Very high element count ($ec vs avg $([int]$avg))"; Default=$Subtitle.Default } }

    if ($engTracks.Count -ge 2) {
        if ($ec -eq $max -and $ec -gt ($min * 1.12)) { return @{ Type="sdh"; NameType="SDH"; Confidence="Medium"; Reason="Highest count ($ec) >12% above min ($min)"; Default=$Subtitle.Default } }
    } else {
        $foreignTracks = @($AllSubtitles | Where-Object { $_.IsoCode -ne "eng" -and $_.ElementCount -gt 399 })
        if ($foreignTracks.Count -gt 0) {
            $fAvg = ($foreignTracks | Measure-Object -Property ElementCount -Average).Average
            if ($ec -gt ($fAvg * 1.3)) { return @{ Type="sdh"; NameType="SDH"; Confidence="Medium"; Reason="Count ($ec) >30% above foreign avg ($([int]$fAvg))"; Default=$Subtitle.Default } }
            if ($ec -ge ($fAvg * 0.8))  { return @{ Type="standard"; NameType="Standard"; Confidence="Medium"; Reason="Count matches foreign avg ($([int]$fAvg))"; Default=$Subtitle.Default } }
        }
    }
    return @{ Type="standard"; NameType="Standard"; Confidence="Low"; Reason="No strong indicators"; Default=$Subtitle.Default }
}

function Get-SuggestedType {
    param([int]$FrameCount, [string]$Language, [array]$AllEnglishTracks, [array]$AllTracks, [string]$Description, [bool]$Default, [bool]$Forced)
    $trackType="standard"; $isDef=$false; $isForced=$false

	if ($Description -match '(?i)SDH')        { $trackType="sdh";        $isDef=$false; $isForced=$false }
    if ($Description -match '(?i)Standard')   { $trackType="standard";   $isDef=$false; $isForced=$false }
    if ($Description -match '(?i)Commentary') { $trackType="commentary"; $isDef=$false; $isForced=$false }
	
    if ($Language -ne "eng") {
        if ($FrameCount -gt 0 -and $FrameCount -lt 200) { $trackType="forced-foreign" }
        else { $trackType="foreign" }
    } elseif ($FrameCount -gt 0) {
		$eng = @($AllEnglishTracks | Where-Object { $_.Language -eq "eng" -and $_.FrameCount -gt 0 })

        if ($eng.Count -gt 0) {
            $avg = ($eng | Measure-Object -Property FrameCount -Average).Average
            $min = ($eng | Measure-Object -Property FrameCount -Minimum).Minimum
            $max = ($eng | Measure-Object -Property FrameCount -Maximum).Maximum
            if ($FrameCount -lt ($avg * 0.1))   { $trackType="forced"; $isForced=$true }
            elseif ($FrameCount -gt ($avg * 2.5)){ $trackType="commentary" }
            if ($eng.Count -ge 2) {
                $foreign = @($AllTracks | Where-Object { $_.Language -ne "eng" -and $_.FrameCount -gt 0 })
                if ($foreign.Count -gt 0) {
                    $fAvg = ($foreign | Measure-Object -Property FrameCount -Average).Average
                    if ($FrameCount -ge ($fAvg * 0.8) -and $FrameCount -le ($fAvg * 1.2)) { $trackType="standard"; $isForced=$false }
                }
                if ($FrameCount -eq $max -and $FrameCount -gt ($min * 1.15)) { $trackType="sdh" }
				else { $trackType = "standard" }
            } 
        }
    }
	
    if ($Description -match '(?i)Forced' -or $Forced) { $isDef=$true;  $isForced=$true;  }
	
    return @{ TrackType=$trackType; IsDefault=$isDef; IsForced=$isForced }
}

function Get-OrderedTrack {
    param([array]$Subtitles, [hashtable]$Classifications)
    $engStd=@(); $engForced=@(); $engSDH=@(); $engCom=@(); $foreign=@()
    foreach ($sub in $Subtitles) {
        $type = $Classifications[$sub.TrackId].type
        if ($type -eq "skip") { continue }
        $info = [PSCustomObject]@{ TrackId=$sub.TrackId; Language=$sub.Language; Type=$type }
        if ($sub.Language -eq "eng") {
            switch ($type) { "standard"{$engStd+=$info} "forced"{$engForced+=$info} "sdh"{$engSDH+=$info} "commentary"{$engCom+=$info} }
        } else { $foreign += $info }
    }
    return @($engStd|Sort-Object TrackId) + @($engForced|Sort-Object TrackId) + @($engSDH|Sort-Object TrackId) + @($foreign|Sort-Object Language,TrackId) + @($engCom|Sort-Object TrackId)
}

function Analyze-ExtractedSubtitle {
    param([string]$basePath, [int]$trackNum, [bool]$MetadataForced)
    $r = [PSCustomObject]@{ TrackNum=$trackNum; Language=''; IsForced=$MetadataForced; IsText=$false; IsSDH=$false; IsCommentary=$false; IsoCode=''; IsVobSub=$false; Hash='' }
    $srt="$basePath.srt"; $idx="$basePath.idx"; $sub="$basePath.sub"; $sup="$basePath.sup"; $ass="$basePath.ass"
    if (Test-Path $srt) {
        $r.IsText=$true; $p=Parse-Srt -SrtPath $srt
        $r.IsSDH=$p.IsSDH; $r.IsCommentary=$p.IsCommentary; $r.IsForced=$p.IsForced
        $iso="eng"; if ($srt -match '\.(spa|fra|ita|rus)\.srt$') { $iso=$matches[1] }
        $r.Language=$iso; $r.IsoCode=$iso
    } elseif ((Test-Path $idx) -and (Test-Path $sub)) {
        $r.IsVobSub=$true; $p=Parse-VobSubIdx -IdxPath $idx
        $r.Language=$p.Language; $r.IsoCode=$p.IsoCode; $r.IsSDH=$p.IsSDH; $r.IsCommentary=$p.IsCommentary
        if ($MetadataForced -or $p.IsForced) { $r.IsForced=$true }
    } elseif (Test-Path $sub)  { $r.IsVobSub=$true; $r.IsoCode="und"; $r.Language="und" }
    elseif (Test-Path $sup)    { $r.IsoCode="und"; $r.Language="und" }
    elseif (Test-Path $ass)    { $r.IsText=$true; $r.IsoCode="und"; $r.Language="und" }
    else { Write-Log "  WARNING: No subtitle file found at $basePath" -Color Red }
    return $r
}

		# ============================================
		# Tier 4 - Workflow Executors
		# ============================================

function Build-AudioStrategy {
    param([array]$AudioTracks)
    $s = @{ Tracks=@(); Encoders=@(); Mixdowns=@(); Bitrates=@(); Names=@(); LanguageOrder=@(); DescriptionList=@() }
    $allowedLangs = @("spa","fra","ita","rus")
    $english = @($AudioTracks | Where-Object { $_.IsEnglish -and -not $_.IsCommentary })
	$english = @($english | Sort-Object @{Expression={$_.Quality}; Descending=$true}, TrackKey)
    $commentary = @($AudioTracks | Where-Object { $_.IsEnglish -and $_.IsCommentary })
    $addedLossless=$false; $addedSurround=$false; $addedAC3=$false; $i=0
	$losslessTrack = $null

    foreach ($track in $english) {
        $inc=$false; $enc="copy"; $mix="none"; $bit=0; $name=""

		if ($track.IsAD.Value) {
			$s.Tracks     += $track.TrackKey
			$s.Encoders   += "av_aac"
			$s.Mixdowns   += "mono"
			$s.Bitrates   += 96
			$s.Names      += "English Audio Description"
			Write-Log "    [$i] Track $($track.TrackKey): English Audio Description (AAC 96kbps)" -Color Cyan
			$s.DescriptionList += "[$i] Track $($track.TrackKey): English Audio Description (AAC 96kbps)"
			$i++
			continue
		}

		# Track 1: Best Lossless 5.1+ (if exist)
        if ($track.Quality -ge 85 -and $track.Channels -ge 5.1 -and -not $addedLossless) {
            $inc=$true; $addedLossless=$true; $addedSurround=$true; $losslessTrack=$track
            if ($track.Format -match 'LPCM|pcm_s16le|pcm_s24le') {
				$enc="ac3" #Universally compatible
				$mix="5point1" #7.1 not supported ac3
				$bit=640 #max bitrate for ac3
				$name="English AC3 (from PCM)"
			} else {
				$name="English Lossless"
			}
            Write-Log "    [$i] Track $($track.TrackKey): $name" -Color Cyan
            $s.DescriptionList += "[$i] Track $($track.TrackKey): $name"; $i++
		# Track 2: AC3 5.1 for compatibility
		} elseif ($track.Quality -ge 50 -and $track.Channels -ge 5.1 -and -not $addedAC3) {
			$inc=$true; $addedSurround=$true; $addedAC3=$true
			if ($losslessTrack){
				# Encode from lossless track
				$s.Tracks+=$losslessTrack.TrackNum
				$s.Encoders+="ac3"
				$s.Mixdowns+="5point1"
				$s.Bitrates+=640
				$s.Names+="English AC3 5.1 (from Lossless)"
				Write-Log "    [$i] Track $($losslessTrack.TrackKey): English AC3 5.1 (from Lossless)" -Color Cyan
				$s.DescriptionList += "[$i] Track $($losslessTrack.TrackKey): English AC3 5.1 (from Lossless)"; $i++
				$inc=$false
			} else {
				# Copy AC3 or first surround
				$name="English Surround"
				Write-Log "    [$i] Track $($track.TrackKey): $name" -Color Cyan
				$s.DescriptionList += "[$i] Track $($track.TrackKey): $name"; $i++
			}
        } 
        if ($inc) { $s.Tracks+=$track.TrackKey; $s.Encoders+=$enc; $s.Mixdowns+=$mix; $s.Bitrates+=$bit; $s.Names+=$name }
    }
	
	# Always add English AAC-256
    if ($english.Count -gt 0) {
		$bestTrack = $english[0]

        if ($bestTrack.Channels -le 2.0 -and $bestTrack.Bitrate -le 256000) {
			$enc = "copy"
			$mix = "none"
			$bit = 0
			$name = "English Stereo (copy)"
			Write-Log "    [$i] Track $($bestTrack.TrackKey): $name" -Color Cyan
			$s.DescriptionList += "[$i] Track $($bestTrack.TrackKey): $name"; $i++
		} else {
			$enc = "av_aac"
			$mix = "stereo"
			$bit = 256
			$name = "English Stereo"
			Write-Log "    [$i] Track $($bestTrack.TrackKey): $name (AAC 256kbps)" -Color Cyan
			$s.DescriptionList += "[$i] Track $($bestTrack.TrackKey): $name (AAC 256kbps)"; $i++
		}
        $s.Tracks+=$bestTrack.TrackKey
		$s.Encoders+=$enc
		$s.Mixdowns+=$mix
		$s.Bitrates+=$bit
		$s.Names+=$name
    }
	
	# Process Foreign Tracks
    $AudioTracks | Where-Object { -not $_.IsEnglish -and -not $_.IsCommentary -and $allowedLangs -contains $_.IsoCode } |
        Group-Object Language | ForEach-Object { $_.Group | Sort-Object @{Expression='Quality'; Descending=$true}, TrackKey | Select-Object -First 1 } |
        ForEach-Object {
            $n="$($langDisplayMap[$_.IsoCode]) Stereo"
            $s.Tracks+=$_.TrackKey; $s.Encoders+="av_aac"; $s.Mixdowns+="stereo"; $s.Bitrates+=128; $s.Names+=$n
            Write-Log "    [$i] Track $($_.TrackKey): $n (AAC 128kbps)" -Color Yellow
            $s.DescriptionList += "[$i] Track $($_.TrackKey): $n (AAC 128kbps)"; $i++
        }

    foreach ($c in $commentary) {
        $s.Tracks+=$c.TrackKey; $s.Encoders+="av_aac"; $s.Mixdowns+="mono"; $s.Bitrates+=96; $s.Names+="English Commentary"
        Write-Log "    [$i] Track $($c.TrackKey): English Commentary (AAC 96kbps)" -Color Yellow
        $s.DescriptionList += "[$i] Track $($c.TrackKey): English Commentary (AAC 96kbps)"; $i++
    }

    foreach ($t in $s.Tracks) {
        $tr = $AudioTracks | Where-Object { $_.TrackKey -eq $t } | Select-Object -First 1
        if ($tr -and -not ($s.LanguageOrder -contains $tr.IsoCode)) { $s.LanguageOrder += $tr.IsoCode }
    }
    if ($commentary.Count -gt 0) { $s.LanguageOrder += "eng-commentary" }

    return $s
}

function Extract-SubtitleTrack {
    param(
        [string]$InputFile,
        [object]$Track,      # unified track object
        [string]$TempDir
    )

    $base = Join-Path $TempDir "track_$($Track.TrackNum)"
    $mkvID = $Track.MKVTrackID
    $si    = $Track.MKVOrder   # correct stream index for ffmpeg

    #
    # --- BITMAP: VobSub / DVD ---
    #
    if ($Track.IsBitmap -and ($Track.CodecID -match "vobsub|dvd|S_VOBSUB")) {

        $cmd = "`"$mkvextractPath`" tracks `"$InputFile`" $($mkvID):`"$base`""
        cmd /c $cmd

        if ($LASTEXITCODE -ne 0) {
            Write-Log "  WARNING: VobSub extraction failed, trying fallback..." -Color Yellow

            $tmp = "$base.temp.mkv"
            cmd /c "`"$ffmpegPath`" -y -i `"$InputFile`" -map 0:s:$si -c copy `"$tmp`" 2>&1" | Out-Null

            if (Test-Path $tmp) {
                cmd /c "`"$ffmpegPath`" -y -i `"$tmp`" -map 0:s:0 -c:s dvdsub `"$base`" 2>&1" | Out-Null
                Remove-Item $tmp -ErrorAction SilentlyContinue
            }
        }

        return $base
    }

    #
    # --- TEXT: SRT / UTF-8 / SUBRIP ---
    #
    if ($Track.IsText -and ($Track.CodecID -match "srt|utf|text|subrip|S_TEXT")) {
        $out = cmd /c "`"$ffmpegPath`" -y -i `"$InputFile`" -map 0:s:$si -c:s srt `"$base.srt`" 2>&1"
        if ($LASTEXITCODE -ne 0) {
            Write-Log "  WARNING: SRT extraction failed ($LASTEXITCODE)" -Color Red
        }
        return "$base.srt"
    }

    #
    # --- PGS / SUP ---
    #
    if ($Track.CodecID -match "pgs|hdmv|sup") {
        cmd /c "`"$ffmpegPath`" -y -i `"$InputFile`" -map 0:s:$si -c:s copy `"$base.sup`" 2>&1" | Out-Null
        return "$base.sup"
    }

    #
    # --- ASS / SSA ---
    #
    if ($Track.CodecID -match "ass|ssa") {
        cmd /c "`"$ffmpegPath`" -y -i `"$InputFile`" -map 0:s:$si -c:s copy `"$base.ass`" 2>&1" | Out-Null
        return "$base.ass"
    }

    #
    # --- FALLBACK ---
    #
    cmd /c "`"$ffmpegPath`" -y -i `"$InputFile`" -map 0:s:$si -c:s srt `"$base.srt`" 2>&1" | Out-Null
    return "$base.srt"
}

function Select-Preset {
    param([int]$height, [bool]$HasAtmos, [bool]$HasLossless, [bool]$IsDVD, [bool]$HasBitmapSub)
    if ($HasAtmos -or $HasLossless -or $HasBitmapSub) {
        $ext="mkv"; $ct="mkv"
        if ($HasBitmapSub) { Write-Log "  Bitmap subtitles detected - using MKV" -Color Green }
        else                  { Write-Log "  ATMOS/Lossless audio detected - using MKV" -Color Green }
    } else { $ext="m4v"; $ct="m4v" }
    if ($IsDVD -or $height -le 480) {
        Write-Log "  SD/DVD source - using DVD preset" -Color Yellow
        return [PSCustomObject]@{ Preset="Mine-265-10b-$ct-dvd"; Extension=".$ext" }
    } elseif ($height -le 1080) {
        Write-Log "  1080p source - using BD preset" -Color Green
        return [PSCustomObject]@{ Preset="Mine-265-10b-$ct-bd";  Extension=".$ext" }
    } else {
        Write-Log "  4K source - using 4K preset" -Color Green
        return [PSCustomObject]@{ Preset="Mine-265-10b-$ct-4k";  Extension=".$ext" }
    }
}

function Get-Vid {
    param([Parameter(mandatory=$true)][string]$SrcDirPath)
    $results = @(Get-ChildItem -Path "$SrcDirPath" -Recurse -Include *.mkv,VIDEO_TS | Where-Object {
        $folderPart    = if ($_.Name -eq 'VIDEO_TS') { $_.Parent.Name }    else { $_.Directory.Name }
        $baseNamePart  = if ($_.Name -eq 'VIDEO_TS') { $_.Parent.Name }    else { $_.BaseName }
        $outBase       = "$($_.PSDrive.Root)Encoded\$folderPart\$baseNamePart"
        $outVob        = "$($_.PSDrive.Root)Encoded\VobSub\$folderPart\$baseNamePart"
        $exists = (Test-Path "$outBase.mkv") -or (Test-Path "$outBase.m4v") -or (Test-Path "$outVob.mkv") -or (Test-Path "$outVob.m4v")
        if ($exists) { Write-Log "    Skipping `"$baseNamePart`" - already exists" -Color Red }
        -not $exists
    } | Sort-Object { $_.Name -ne 'VIDEO_TS' }, Length)
    Write-Log "Found $($results.Count) videos to encode"
    if ($results.Count -eq 0) { Write-Log "No videos to encode, exiting" -Color Yellow; return @() }
    return $results
}

function Get-Classification {
    if (Test-Path $classificationsFile) {
        Write-Log "Loading existing classifications from: $classificationsFile" -Color Yellow
        return Get-Content $classificationsFile -Raw | ConvertFrom-Json
    }
    return @{ version=1; files=@{} }
}

function Save-Classification {
    param([object]$Classifications)
    $out = @{ version=$Classifications.version; files=@{} }
    
    $fileNames = if ($Classifications.files -is [hashtable]) { 
        $Classifications.files.Keys 
    } else { 
        $Classifications.files.PSObject.Properties.Name 
    }
    
    foreach ($fn in $fileNames) {
        $f = if ($Classifications.files -is [hashtable]) {
            $Classifications.files[$fn]
        } else {
            $Classifications.files.PSObject.Properties[$fn].Value
        }
        $ts = @{}
        $trackKeys = if ($f.tracks -is [hashtable]) { $f.tracks.Keys } else { $f.tracks.PSObject.Properties.Name }
        foreach ($id in $trackKeys) {
            $ts["$id"] = if ($f.tracks -is [hashtable]) { $f.tracks[$id] } else { $f.tracks.PSObject.Properties[$id].Value }
        }
        $out.files[$fn] = @{ processed=$f.processed; relativePath=$f.relativePath; tracks=$ts }
    }
    
    $out | ConvertTo-Json -Depth 10 | Set-Content $classificationsFile -Encoding UTF8
    Write-Log "Saved classifications to: $classificationsFile" -Color Green
}

function Get-UserClassification {
    param([string]$FileName, [array]$Subtitles, [object]$ExistingClassification)
    Write-Log "`n========================================" -Color Cyan
    Write-Log "File: $FileName" -Color Cyan
    Write-Log "========================================" -Color Cyan
    Write-Log "Found $($Subtitles.Count) subtitle tracks:`n" -Color Cyan

    $engTracks      = $Subtitles | Where-Object { $_.Language -eq "eng" }

    $classifications = @{}

    foreach ($sub in $Subtitles) {
        $origName = if ($sub.TrackName -match ' ') { ($sub.TrackName -split ' ')[1] } else { $sub.TrackName }
        $origDef  = if ($sub.TrackDefault) { ", Default" } else { "" }
        $origForc = if ($sub.TrackForced)  { ", Forced"  } else { "" }

        $sug = Get-SuggestedType -FrameCount $sub.FrameCount -Language $sub.Language -AllEnglishTracks $engTracks -AllTracks $Subtitles -Description $sub.TrackName -Default $sub.TrackDefault -Forced $sub.TrackForced
        $recDef  = if ($sug.IsDefault) { ", Default" } else { "" }
        $recForc = if ($sug.IsForced)  { ", Forced"  } else { "" }
        $sugType = $sug.TrackType

        if ($ExistingClassification -and $ExistingClassification.tracks) {
            $key = "$($sub.TrackId)"
            if ($ExistingClassification.tracks.PSObject.Properties[$key]) { $sugType = $ExistingClassification.tracks.PSObject.Properties[$key].Value.type }
        }

        $sugLabel = switch ($sugType) {
            "standard"      {"Standard"} "sdh"{"SDH"} "commentary"{"Commentary"}
            "forced"        {"Forced"}   "foreign"{"Foreign Standard"} "forced-foreign"{"Forced Foreign (Auto-Skip)"}
        }
        $langDisp = if ($langDisplayMap[$sub.Language]) { $langDisplayMap[$sub.Language] } else { $sub.Language.ToUpper() }
        $trackDesc = switch ($sugType) {
            "standard"      {"Standard - [$langDisp]"} "sdh"{"SDH - [$langDisp]"} "commentary"{"Commentary - [$langDisp]"}
            "forced"        {"Forced - [$langDisp]"} "foreign"{"Standard - [$langDisp]"} "forced-foreign"{"Forced - [$langDisp] (will skip)"}
        }
        $autoLabel = "$(if($sub.Language -ne 'eng'){'Auto'}else{'Suggested'}): $sugLabel$recDef"

        Write-Log "[$($sub.TrackId)] $($sub.Language.ToUpper()) [$($sub.Codec)] ($($sub.FrameCount) frames)".PadRight(40) -Color White
        Write-Log "Original: $origName$origDef$origForc".PadRight(50) -Color White
        Write-Log "$autoLabel".PadRight(50) -Color Yellow
        Write-Log "-> $trackDesc$recDef".PadRight(20) -Color Cyan

        $classifications[$sub.TrackId] = @{ suggested=$sugType; language=$sub.Language; codec=$sub.Codec; default=$recDef; forced=$recForc }
    }

    Write-Log "`nAccept suggestions? ([Y]/n/q to quit): " -NoNewLine -Color Green
    $resp = Read-Host
    if ($resp -eq 'q') { return $null }

    if ($resp -eq '' -or $resp -eq 'y' -or $resp -eq 'Y') {
        foreach ($sub in $Subtitles) {
            $t = $classifications[$sub.TrackId].suggested
            $classifications[$sub.TrackId].type = if ($t -eq "forced-foreign") { "skip" } else { $t }
        }
    } else {
        Write-Log "`nClassify English tracks (1=Standard, 2=SDH, 3=Commentary, 4=Forced, S=Skip):" -Color Cyan
        foreach ($sub in ($Subtitles | Where-Object { $_.Language -eq "eng" })) {
            $defType = $classifications[$sub.TrackId].suggested
            $defNum  = switch ($defType) { "standard"{"1"} "sdh"{"2"} "commentary"{"3"} "forced"{"4"} }
            $defDef  = $classifications[$sub.TrackId].default
            Write-Log "  Track $($sub.TrackId) - English: " -NoNewLine
            Write-Log "[Default: $defNum]: " -NoNewLine -Color Yellow
            $inp = Read-Host; if ($inp -eq '') { $inp = $defNum }

            Write-Log "`nThis track is$(if(-not $defDef){' not'}else{''}) the default. Maintain? ([Y]/N): " -NoNewLine -Color Cyan
            $defInp = Read-Host
            $classifications[$sub.TrackId].default = if ($defInp -eq '' -or $defInp -eq 'Y') { $defDef } else { -not $defDef }
            $classifications[$sub.TrackId].type = switch ($inp) {
                "1"{"standard"} "2"{"sdh"} "3"{"commentary"} "4"{"forced"} "s"{"skip"} "S"{"skip"} default{$defType}
            }
        }
		
		if ([bool]($Subtitles.Where({ $_.Language -ne "eng"}, 'First'))){
			Write-Log "`nDo you want to change foreign tracks? (y/[N]/q to quit): " -NoNewLine -Color Green
			$resp2 = Read-Host
			if ($resp2 -eq 'q') { return $null }
			if ($resp2 -eq 'y' -or $resp2 -eq 'Y') {
				Write-Log "`nClassify Foreign tracks (1=Standard, 2=SDH, 3=Commentary, 4=Forced, S=Skip):" -Color Cyan
				foreach ($sub in ($Subtitles | Where-Object { $_.Language -ne "eng" })) {
					$defType = $classifications[$sub.TrackId].suggested
					$defNum  = switch ($defType) { "standard"{"1"} "sdh"{"2"} "commentary"{"3"} "forced"{"4"} }
					$defDef  = $classifications[$sub.TrackId].default
					Write-Log "  Track $($sub.TrackId) - $($sub.Language): " -NoNewLine
					Write-Log "[Default: $defNum]: " -NoNewLine -Color Yellow
					$inp = Read-Host; if ($inp -eq '') { $inp = $defNum }

					Write-Log "`nThis track is$(if(-not $defDef){' not'}else{''}) the default. Maintain? ([Y]/N): " -NoNewLine -Color Cyan
					$defInp = Read-Host
					$classifications[$sub.TrackId].default = if ($defInp -eq '' -or $defInp -eq 'Y') { $defDef } else { -not $defDef }
					$classifications[$sub.TrackId].type = switch ($inp) {
						"1"{"standard"} "2"{"sdh"} "3"{"commentary"} "4"{"forced"} "s"{"skip"} "S"{"skip"} default{$defType}
					}
				}
			} else {
				foreach ($sub in ($Subtitles | Where-Object { $_.Language -ne "eng" })) {
					$t = $classifications[$sub.TrackId].suggested
					$classifications[$sub.TrackId].type = if ($t -eq "forced-foreign") { "skip" } else { "foreign" }
				}
			}
		}
    }
    return $classifications
}

function Get-ProposedTrackName ([string]$existing) {
    $firstWord = $existing.Split(' ')[0].Trim()
    $proposed = switch -Regex ($firstWord) {
        "English"                                               { "English" }
        "Fran(cais|\xe7ais)|French"                             { "Fran$([char]0xe7)ais" }
        "Spanish|Espa(.*|\xf1)ol"                               { "Espa$([char]0xf1)ol" }
        "Italian|Italiano"                                      { "Italiano" }
        "Russian| CAA:89"                                       { -join [char[]](0x0420,0x0443,0x0441,0x0441,0x043a,0x0438,0x0439) }
        "German|Deutsch"                                        { "Deutsch" }
        default                                                 { $firstWord }
    }
    if ($existing -match ' ') { $proposed += $existing.Substring($firstWord.Length) }
    return $proposed
}

function Build-SubtitleMuxPlan {
    param(
        [array]$SubTracks,
        [string]$PrimaryAudioIso
    )

    # --- 1. INITIALIZATION & METADATA ---
    $allEntries = @()
    $needsManualReview = $false
    $allowedIso = @('eng','spa','fra','ita','rus')
    $nameMap = @{ 'eng'='English'; 'spa'='Spanish'; 'fra'='French'; 'ita'='Italian'; 'rus'='Russian' }
    $SubTracks = $SubTracks | Where-Object { $allowedIso -contains $_.IsoCode }
    $i = $SubTracks[0].TrackKey - 1
    $classified = foreach ($t in $SubTracks) {
        $cl = Get-SubtitleClassification -Subtitle $t -AllSubtitles $SubTracks
        if ($cl.Confidence -eq 'Low') { $needsManualReview = $true }

        #$color = switch ($cl.Confidence) { "High"{"Green"} "Medium"{"Yellow"} "Low"{"Red"} }
        Write-Log "    [$i] Track $($t.TrackKey): $($t.Language.Value) $($cl.Type)" -Color Cyan 
        #(Confidence: $($cl.Confidence))" -Color Cyan -NoNewLine
        #Write-Log "      Reason: $($cl.Reason)" -Color DarkGray -NoTimeStamp

        [PSCustomObject]@{
            Track        = $t
            IsoCode      = $t.IsoCode
            Type         = $cl.Type
            Forced       = $t.Forced
            Default      = $t.Default
            ElementCount = $t.ElementCount
            IsBitmap     = $t.IsBitmap
        }
        $i++
    }

    $ordered = @()

    # 1. ENG standard (first)
    $ordered += $classified |
        Where-Object { $_.IsoCode -eq 'eng' -and $_.Type -eq 'standard' } |
        Sort-Object { $_.Track.TrackKey } |
        Select-Object -First 1

    # 2. ENG SDH
    $ordered += $classified |
        Where-Object { $_.IsoCode -eq 'eng' -and $_.Type -eq 'sdh' } |
        Sort-Object { $_.Track.TrackKey }

	# 3. ENG Forced
    $ordered += $classified |
        Where-Object { $_.IsoCode -eq 'eng' -and $_.Type -eq 'forced' } |
        Sort-Object { $_.Track.TrackKey }
	
	# 4. Non-ENG allowed, non-commentary
    $ordered += $classified |
        Where-Object { $_.IsoCode -ne 'eng' -and $_.Type -ne 'commentary' } |
        Group-Object { $_.IsoCode } |
        ForEach-Object { $_.Group | Select-Object -First 1 }

    # 5. ENG commentary
    $ordered += $classified |
        Where-Object { $_.IsoCode -eq 'eng' -and $_.Type -eq 'commentary' } |
        Sort-Object { $_.Track.TrackKey }

    $allEntries = foreach ($entry in $ordered) {
        [PSCustomObject]@{
            Action       = 'Keep'
            SourceType   = if ($entry.IsBitmap) { 'Bitmap' } else { 'Text' }
            TrackKey     = $entry.Track.TrackKey
            Language     = $entry.IsoCode
            Role         = $entry.Type
            Forced       = $entry.Forced
            Default      = $entry.Default
            ElementCount = $entry.ElementCount
        }
    }

    $deduped = @()
    foreach ($entry in $allEntries) {
        $existingMatch = $deduped | Where-Object { 
            $_.Language -eq $entry.Language -and 
            $_.Role -eq $entry.Role -and (
                ($_.ElementCount -gt 0 -and $entry.ElementCount -gt 0 -and [Math]::Abs($_.ElementCount - $entry.ElementCount) / $_.ElementCount -lt 0.12) -or 
                ($_.ElementCount -eq 0 -or $entry.ElementCount -eq 0)
            )
        }

        if ($null -eq $existingMatch) {
            $deduped += $entry
        } elseif ($existingMatch.SourceType -eq 'Bitmap' -and $entry.SourceType -eq 'Text') {
            $deduped = $deduped | Where-Object { $_.TrackKey -ne $existingMatch.TrackKey }
            $deduped += $entry
        }
    }

    $ordered = @()
    $ordered += $deduped | Where-Object { $_.Language -eq 'eng' -and $_.Role -eq 'standard' }
    $ordered += $deduped | Where-Object { $_.Language -eq 'eng' -and $_.Role -eq 'sdh' }
    $ordered += $deduped | Where-Object { $_.Language -eq 'eng' -and $_.Role -eq 'forced' }
    $ordered += $deduped | Where-Object { $_.Language -ne 'eng' } | Sort-Object Language
    $ordered += $deduped | Where-Object { $_.Language -eq 'eng' -and $_.Role -eq 'commentary' }

    $plan = foreach ($entry in $ordered) {
        # Only Burn if it's the first track in the final list and marked for burn
        $finalAction = if ($entry.Action -eq 'Burn' -and $ordered[0].TrackKey -eq $entry.TrackKey) { 'Burn' } else { 'Keep' }
		if (($entry.Default) -and (-not $entry.Forced)){
			$entry.Default = $false
		}
        
        [PSCustomObject]@{
            Action     = $finalAction
            SourceType = $entry.SourceType
            TrackKey   = $entry.TrackKey
            Language   = $entry.Language
            Role       = $entry.Role
            Forced     = $entry.Forced
            Default    = $entry.Default
        }
    }

    return @{
        Plan              = $plan
        NeedsManualReview = $needsManualReview
    }
}

function Invoke-SubRemux {
    param([string]$InputFile, [string]$OutputFile, [array]$OrderedTracks, [array]$AllTracks, [hashtable]$AllClassifications)
    Write-Log "  Remuxing with corrected subtitle order..." -Color Yellow

    $subtitleTrackIds = ($OrderedTracks | ForEach-Object { $_.TrackId }) -join ","
    $mkvArgs = @("-o", $OutputFile)

    foreach ($track in $OrderedTracks) {
        #$langDisp = if ($langDisplayMap[$track.Language]) { $langDisplayMap[$track.Language] } else { $track.Language.ToUpper() }
        $trackName = switch ($track.Type) { "standard"{"Standard"} "forced"{"Forced"} "sdh"{"SDH"} "commentary"{"Commentary"} "foreign"{"Standard"} }
        $mkvArgs += "--language",    "$($track.TrackId):$($track.Language)"
        $mkvArgs += "--track-name",  "$($track.TrackId):$trackName"
        if ($track.Type -eq "forced" -and $track.Language -eq "eng") {
            $mkvArgs += "--default-track-flag", "$($track.TrackId)"
            $mkvArgs += "--forced-display-flag","$($track.TrackId)"
        } else {
			$mkvArgs += "--default-track-flag","$($track.TrackId):0"
            $mkvArgs += "--forced-display-flag","$($track.TrackId):0"
        }
    }

    $trackOrder = @()
    foreach ($t in $AllTracks) { if ($t.type -ne "subtitles") { $trackOrder += "0:$($t.id)" } }
    foreach ($t in $OrderedTracks) { $trackOrder += "0:$($t.TrackId)" }
    $mkvArgs += "--track-order", ($trackOrder -join ",")
    $mkvArgs += "--subtitle-tracks", $subtitleTrackIds
    $mkvArgs += $InputFile

    if ($DryRun) { Write-Log "  [DRY RUN] Would execute mkvmerge remux" -Color Yellow; return $true }

    & $mkvmergePath @mkvArgs 2>&1 | Out-File -FilePath $logFile -Append
    if ($LASTEXITCODE -ne 0) { Write-Log "  ERROR: mkvmerge failed ($LASTEXITCODE)" -Color Red; return $false }
    if (-not (Test-Path $OutputFile)) { Write-Log "  ERROR: Output file not created" -Color Red; return $false }

    $inSz  = (Get-Item $InputFile).Length
    $outSz = (Get-Item $OutputFile).Length
    if ($outSz -lt ($inSz * 0.9) -or $outSz -gt ($inSz * 1.1)) { Write-Log "  WARNING: Output size differs significantly" -Color Yellow }
    Write-Log "  Remux completed successfully" -Color Green
    return $true
}

function Invoke-SubReviewMode {
    Test-Dependency @(
        @{ Name="mkvmerge"; Path=$mkvmergePath }
        @{ Name="ffprobe";  Path=$ffprobePath  }
    )
    Write-Log "VobSub Manual Review & Remux" -Color Cyan
    Write-Log "Dry Run: $DryRun" -Color Yellow

    $vobsubFiles = Get-ChildItem -Path $vobsubDir -Recurse -Include *.mkv,*.m4v
    if ($vobsubFiles.Count -eq 0) { Write-Log "No files found in: $vobsubDir" -Color Yellow; return }
    Write-Log "Found $($vobsubFiles.Count) files to review" -Color Green

    $allClassifications = Get-Classification
    $filesToProcess = @()

    Write-Log "`nPhase 1: User Classification..." -Color Cyan
    foreach ($file in $vobsubFiles) {
		$fileName     = $file.Name
		$relativePath = $file.FullName.Replace($vobsubDir,"").TrimStart("\")
		Write-Log "`nAnalyzing: $fileName" -Color Cyan

		#$info      = Get-MkvSubtitleInfo -FilePath $file.FullName
        $info = Get-Metadata -FilePath $file.FullName
		$subtitles = $info.Subtitles

		if ($subtitles.Count -eq 0) { Write-Log "  No subtitles found - skipping" -Color Yellow; continue }

		$existingCl = $null
		if ($allClassifications.files.$fileName) { $existingCl = $allClassifications.files.$fileName; Write-Log "  Found existing classification" -Color Yellow }

		$classification = Get-UserClassification -FileName $fileName -Subtitles $subtitles -ExistingClassification $existingCl
		$userQuit = ($null -eq $classification)

		if (-not $userQuit) {
			# Deduplicate: prefer SRT over VobSub for same language+type
			$finalSubs = @(); $seen = @{}
			foreach ($sub in $subtitles) {
				$type = $classification[$sub.TrackId].type
				if ($type -eq "skip") { continue }
				$key = "$($sub.Language)_$type"
				if (-not $seen.ContainsKey($key)) { $seen[$key] = $finalSubs.Count; $finalSubs += $sub }
				else {
					$ei = $seen[$key]; $ex = $finalSubs[$ei]
					if ($sub.Codec -match "SubRip|SRT" -and $ex.Codec -match "VobSub") {
						$finalSubs[$ei] = $sub; Write-Log "  Dedup: SRT $($sub.TrackId) over VobSub $($ex.TrackId)" -Color Yellow
					} else { Write-Log "  Dedup: Skipping duplicate $($sub.TrackId)" -Color Yellow }
				}
			}
			$subtitles   = $finalSubs
			$filteredCl  = @{}; foreach ($sub in $finalSubs) { $filteredCl[$sub.TrackId] = $classification[$sub.TrackId] }
			$classification = $filteredCl

			if (-not $allClassifications.files.PSObject.Properties[$fileName]) {
				$allClassifications.files | Add-Member -NotePropertyName $fileName -NotePropertyValue @{ processed=$false; relativePath=$relativePath; tracks=$classification } -Force
			} else { $allClassifications.files.$fileName = @{ processed=$false; relativePath=$relativePath; tracks=$classification } }

			$filesToProcess += @{ File=$file; Subtitles=$subtitles; Classification=$classification }
		}

		if ($userQuit) { Write-Log "User quit - saving progress" -Color Yellow; Save-Classification -Classifications $allClassifications; return }
	}

    Save-Classification -Classifications $allClassifications

    Write-Log "`nPhase 2: Processing files..." -Color Cyan
    $processedCount = 0
    foreach ($item in $filesToProcess) {
        $file = $item.File; $fileName=$file.Name; $folderName=$file.Directory.Name
        Write-Log "========================================" -Color Cyan
        Write-Log "Processing: $fileName" -Color Cyan
        Write-Log "========================================" -Color Cyan

        $orderedTracks = Get-OrderedTrack -Subtitles $item.Subtitles -Classifications $item.Classification
        Write-Log "  Subtitle order:" -Color Yellow
        $i=0; foreach ($track in $orderedTracks) {
            $label = switch($track.Type){"standard"{"Standard"}"sdh"{"SDH"}"commentary"{"Commentary"}"foreign"{"Foreign"}"forced"{"Forced"}}
            Write-Log "    [$i] Track $($track.TrackId): $($track.Language.ToUpper()) ($label)" -Color Cyan; $i++
        }

        $outputDir = Join-Path $encodedBaseDir $folderName
        if (-not (Test-Path $outputDir)) { New-Item $outputDir -ItemType Directory | Out-Null; Write-Log "  Created: $outputDir" -Color Yellow }
        $outputFile = Join-Path $outputDir $fileName

        $info = Get-MkvSubtitleInfo -FilePath $file.FullName
        $success = Invoke-SubRemux -InputFile $file.FullName -OutputFile $outputFile -OrderedTracks $orderedTracks -AllTracks $info.AllTracks -AllClassifications $item.Classification
        if ($success) {
            $garbageDir = Join-Path $garbageBaseDir $folderName
            if (-not (Test-Path $garbageDir)) { New-Item $garbageDir -ItemType Directory | Out-Null }
            $garbageFile = Join-Path $garbageDir $fileName
            if ($DryRun) { Write-Log "  [DRY RUN] Would move to: $garbageFile" -Color Yellow }
            else {
                if (Test-Path $garbageFile) { Remove-Item $garbageFile -Force }
                Move-Item $file.FullName $garbageFile
                Write-Log "  Moved to garbage" -Color Green
                if ((Get-Item $file.DirectoryName).GetFileSystemInfos().Count -eq 0) { Remove-Item $file.DirectoryName }
            }
            $allClassifications.files.$fileName.processed = $true
            $processedCount++
        } else { Write-Log "  FAILED" -Color Red }
    }

    Save-Classification -Classifications $allClassifications
    Write-Log "`nPROCESSING COMPLETE! $processedCount/$($filesToProcess.Count) files" -Color Green
}

function Invoke-MetadataRemux {
    $files = Get-ChildItem -Path $metaSourceDir -Recurse | Where-Object { $_.Extension -match '\.(mkv|m4v|mp4)$' }
    if (-not $files -or $files.Count -eq 0) { Write-Log "No files found in $metaSourceDir" -Color Red; return }
    Write-Log "Found $($files.Count) files. Analyzing metadata..." -Color Cyan

    $batchData = @()
    foreach ($file in $files) {
        Write-Log "Analyzing: $($file.Name)" -Color Yellow
        $ffCmd = ((& $ffprobePath -v error -show_entries stream=index,codec_type:stream_tags=title,handler_name,language -of json "$($file.FullName)") -join "`n") | ConvertFrom-Json
        $tracks = @()
        foreach ($s in $ffCmd.streams) {
            if ($s.codec_type -notin @("audio","subtitle")) { continue }
            if ($s.tags.title)       { $existing=$s.tags.title;        $proposed=Get-ProposedTrackName $existing }
            elseif ($s.tags.handler_name -and $s.tags.handler_name -notmatch "handler") { $existing=$s.tags.handler_name; $proposed=Get-ProposedTrackName $existing }
            else { $lang=if($s.tags.language){$s.tags.language}else{"und"}; $existing="$lang $($s.codec_type)"; $proposed=$existing }
            $tracks += [PSCustomObject]@{ Id=$s.index; Type=$s.codec_type; Language=if($s.tags.language){$s.tags.language}else{"und"}; CurrentName=$existing; NewName=""; ProposedName=$proposed }
        }
        $batchData += [PSCustomObject]@{ FileInfo=$file; Tracks=$tracks }
    }

    Write-Log "`nAnalysis complete. Starting user input phase..." -Color Cyan
    foreach ($item in $batchData) {
        Write-Log "`n=================================================" -Color Gray
        Write-Log "FILE: $($item.FileInfo.Name)" -Color Green
        Write-Log "=================================================" -Color Gray
        foreach ($track in $item.Tracks) {
            Write-Log "  Track $($track.Id) [$($track.Type)]" -Color Cyan
            Write-Log "  Current:  " -NoNewline 
            Write-Log "'$($track.CurrentName)'"  -Color Yellow
            Write-Log "  Proposed: " -NoNewline
            Write-Log "'$($track.ProposedName)'" -Color Yellow
            $inp = Read-Host "  Enter name (Enter to accept proposed)"
            $track.NewName = if ([string]::IsNullOrWhiteSpace($inp)) { $track.ProposedName } else { $inp }
            Write-Log "  -> `"$($track.NewName)`""
        }
    }

    Write-Log "`nStarting batch remux..." -Color Cyan
    foreach ($item in $batchData) {
        $relDir    = $item.FileInfo.DirectoryName.Replace($metaSourceDir,"").TrimStart('\')
        $targetDir = Join-Path $metaOutputDir $relDir
        if (-not (Test-Path $targetDir)) { New-Item $targetDir -ItemType Directory -Force | Out-Null }
        $outPath = Join-Path $targetDir $item.FileInfo.Name

        $ffArgs = @("-i", "`"$($item.FileInfo.FullName)`"", "-map", "0", "-c", "copy")
        foreach ($track in $item.Tracks) {
            if ($track.NewName) { $ffArgs += "-metadata:s:$($track.Id)"; $ffArgs += "title=`"$($track.NewName)`"" }
        }
        $ffArgs += "`"$outPath`""

        Write-Log "Remuxing: $($item.FileInfo.Name)" -Color Yellow
        if ($DryRun) { Write-Log "  [DRY RUN] ffmpeg $($ffArgs -join ' ')" -Color Gray; continue }

        $proc = Start-Process -FilePath $ffmpegPath -ArgumentList $ffArgs -Wait -NoNewWindow -PassThru
        if ($proc.ExitCode -eq 0) { Write-Log "  SUCCESS -> $outPath" -Color Green }
        else                      { Write-Log "  FAILED (exit $($proc.ExitCode))" -Color Red }
    }
}

function Invoke-EncodeMode {
    Test-Dependency @(
        @{ Name="FFmpeg";       Path=$ffmpegPath    }
        @{ Name="mkvmerge";     Path=$mkvmergePath  }
        @{ Name="mkvextract";   Path=$mkvextractPath}
        @{ Name="MediaInfo";    Path=$mediaInfoPath  }
        @{ Name="HandBrakeCLI"; Path=$handBrakePath  }
    )

    $vids = Get-Vid -SrcDirPath $SrcDir
    if ($vids.Count -eq 0) { return }

    $FullEncodingPlan = @()
    Write-Log "`n---------------------------- PRE-FLIGHT ANALYSIS --------------------------------" -Color Cyan

    foreach ($vid in $vids[9]) {
        Write-Log " Processing ($($vids.IndexOf($vid)+1)/$($vids.Count)): $($vid.Name)" -Color Green
        
        try { $scan = Get-Metadata -VideoPath $vid.FullName }
        catch { $e = $_.Exception
            Write-Log "  CRITICAL ERROR scanning $($vid.Name) - skipping" -Color Red
            Write-Host "$e"
            continue
        }

        $audioInfo = $scan.Audio
		$adAnalysis = Get-ADAnalysis -AudioTracks $audioInfo.Tracks -FilePath $vid.FullName
		$adTrack = $adAnalysis.ADTrackNum
		$adConfidence = $adAnalysis.Confidence

		if ($adTrack -and ($adTrack -is [int])) {
			$t = $audioInfo.Tracks | Where-Object TrackKey -eq $adTrack
			if ($t) {
				$t.IsAD.Value = $true
				$t.IsCommentary.Value = $false
				Write-Log "  Detected AD Track: $($t.TrackNum) with a" -NoNewLine -Color Green
				Write-Log "$($adConfidence)" -NoNewLine -Color Red -NoTimeStamp
				Write-Log "confidence" -Color Green -NoTimeStamp
			} else {
				Write-Log "  AD detection returned TrackNum=$($adTrack) but no matching track exists" -Color Red
			}
		} else {
			Write-Log "  No AD Track detected" -Color DarkGray
		}

		Write-Log "  Audio Strategy:" -Color Yellow

		$audioStrategy = Build-AudioStrategy -AudioTracks $audioInfo.Tracks
        $audioSummary  = ($audioStrategy.DescriptionList | ForEach-Object { $_.Trim() -replace "\r","" } | Where-Object { $_ -match '\S' }) -join "`n"
        Write-Log "  Subtitle Strategy:" -Color Yellow
        $subtitleTracks = $scan.Subtitles
        $isTextSub     = @($subtitleTracks | Where-Object { $_.IsText })
        if ($isTextSub.Count -gt 0) { Write-Log "    Found $($isTextSub.Count) text subtitle tracks" -Color Yellow }
        $hasBitmap     = @($subtitleTracks | Where-Object { $_.IsBitmap })
        if ($hasBitmap.Count -gt 0) { Write-Log "    Found $($hasBitmap.Count) bitmap subtitle tracks" -Color Yellow }

		$primaryAudio = $audioInfo.Tracks[0]
Write-Host "DEBUG: subtracks $($subtitleTracks[0])"
        $subPlan = Build-SubtitleMuxPlan -SubTracks $subtitleTracks -PrimaryAudioIso $primaryAudio.IsoCode.Value
		$effectiveBitmap = @($subPlan.Plan | Where-Object { $_.SourceType -eq 'Bitmap' })

		Write-Log "  Selecting Preset" -Color Yellow
		$isDVD         = ($vid.Name -eq "VIDEO_TS")
        $vHeight           = $scan.Video.Height.Value
        
        $presetInfo    = Select-Preset -Height $vHeight -HasAtmos $audioInfo.HasAtmos -HasLossless $audioInfo.HasLossless -IsDVD $isDVD -HasBitmapSub ($effectiveBitmap.Count -gt 0)
        $displayName = if ($isDVD) { $vid.Parent.Name } else { $vid.BaseName }
        $doProcess = $true

        # normalize subtitle plan -> legacy schema used by flat plan display
        $planList = @($subPlan.Plan)
        $subtitleList = if ($planList.Count -gt 0) { ($planList.TrackKey -join ",") } else { $null }
Write-Host "DEBUG: planlist $($planList.Count)"
Write-Host "DEBUG: planlist[0].default $($planList[0].Default)"
Write-Host "DEBUG: planlist[1].default $($planList[1].Default)"
        # Burn if any plan entry is Burn
        $burnFlag = ($planList | Where-Object { $_.Action -eq 'Burn' }).Count -gt 0

        # Build Classifications array (indexable by i in existing code)
        $classifications = @()
        foreach ($entry in $planList) {
            $classifications += [PSCustomObject]@{
                TrackKey = $entry.TrackKey
                Default  = $entry.Default
                Forced   = $entry.Forced
                Type     = $entry.Role
                NameType = if ($entry.Role -eq 'forced' -or $entry.Role -eq 'forced-foreign') { 'Forced' }
                        elseif ($entry.Role -eq 'sdh') { 'SDH' }
                        elseif ($entry.Role -eq 'commentary') { 'Commentary' } else { 'Standard' }
            }
        }

        # Build Names array aligned with subtitleList order (fallback to proposed name)
        $names = @()
        if ($subtitleList) {
            $keys = $subtitleList.Split(',') | ForEach-Object { $_.Trim() }
            foreach ($k in $keys) {
                $track = $subtitleTracks | Where-Object { $_.TrackKey -eq $k } | Select-Object -First 1
                if ($track -and $track.Title) {
                    $names += $track.Title 
                } elseif (-not $null -eq $track.Language.Value -and -not "" -eq $track.Language.Value) {
                        $names += (Get-ProposedTrackName $track.Language.Value)
                } else { $names += "Unknown" }
            }
        }

        $subPlanNormalized = [PSCustomObject]@{
            SubtitleList   = $subtitleList
            Burn           = $burnFlag
            Names          = $names
            Classifications= $classifications
            NeedsManualReview = $subPlan.NeedsManualReview
            RawPlan        = $subPlan.Plan
        }

        $FullEncodingPlan += [PSCustomObject]@{
            VideoObject=$vid
            DisplayName=$displayName
            PresetName=$presetInfo.Preset
            Extension=$presetInfo.Extension
            AudioInfo=$audioInfo
            AudioArgs=$audioStrategy
            AudioSummary=$audioSummary
            IsTextSub=$isTextSub
            Resolution=$vHeight
            SubtitleTracks=$subtitleTracks
            SubtitleStrategy=$subPlanNormalized
            HasBitmap=($effectiveBitmap.Count -gt 0)
            DoProcess=$doProcess
            Classifications=$subPlanNormalized.Classifications
        }
    }

    # Display plan table
    $flatPlan = foreach ($video in $FullEncodingPlan) {
        $sub = $video.SubtitleStrategy
        $subArr = if ($sub.SubtitleList -is [string]) { $sub.SubtitleList.Split(',').Trim() } else { @($sub.SubtitleList) }
        $audioLines = $video.AudioSummary -split "`n"
        $max = [Math]::Max($audioLines.Count, $subArr.Count)
        for ($i=0; $i -lt $max; $i++) {
            [PSCustomObject]@{
                Title     = if($i-eq 0){$video.DisplayName}else{""}
                Quality   = if($i-eq 0){$video.Resolution}else{""}
                'File Ext'= if($i-eq 0){$video.Extension}else{""}
                Audio     = if($i-lt $audioLines.Count){$audioLines[$i]}else{""}
                SubTitle  = if($i-lt $subArr.Count){$subArr[$i]}else{""}
                'Sub Action'=if($i-lt $subArr.Count){if($video.IsTextSub.IsText){"Process"}else{"Copy"}}else{""}
                Default   = if($i-lt $sub.Classifications.Count){$sub.Classifications[$i].Default}else{""}
                Burn      = if($i-lt $subArr.Count){$sub.Burn}else{""}
                Forced    = if($i-lt $sub.Classifications.Count){$sub.Classifications[$i].Forced}else{""}
                Name      = if($i-lt $subArr.Count -and $sub.Names -is [array]){"$($sub.Names[$i]) $(if($i -lt $video.Classifications.Count){$video.Classifications[$i].NameType})"}else{""}
            }
        }
    }

    $cols = @(
        @{Expression="Title";Width=50}
		@{Expression="Quality";Width=10}
		@{Expression="File Ext";Width=10}
        @{Expression="Audio";Width=60}
		@{Expression="SubTitle";Width=10}
		@{Expression="Sub Action";Width=10}
        @{Expression="Default";Width=7}
		@{Expression="Burn";Width=7}
		@{Expression="Forced";Width=8}
		@{Expression="Name";Width=25}
    )
    $outTable = $flatPlan | Format-Table -Property $cols -Wrap | Out-String -Width 400
    $lines = ($outTable -split "`n") | Where-Object { $_.Trim() -ne '' } | ForEach-Object { $_.TrimEnd() }
    $newLines = @()
    for ($i=0; $i -lt $lines.Count; $i++) {
        $newLines += $lines[$i]
        if ($i -lt $lines.Count-1 -and $lines[$i+1] -match '^\S' -and $lines[$i+1] -notmatch '^-+') { $newLines += "" }
    }
    Write-Host ""
    Write-Log ($newLines -join "`n") -NoTimeStamp -Color White

    if ($AnalyzeOnly) { Write-Log "`n-AnalyzeOnly: no encodes started." -Color Yellow; return }

    $confirm = Read-Host "`nProceed with encoding $($vids.Count) files? (Y/N)"
    if ($confirm -ne "Y") { Write-Log "Aborting." -Color Red; return }

    $encodeStart = Get-Date; $completed = 0
    foreach ($vid in $FullEncodingPlan) {
        $percent = [math]::Round(($completed/$FullEncodingPlan.Count)*100,1)
        $etaString = if ($completed -gt 0) {
            $eta = [TimeSpan]::FromSeconds(((Get-Date)-$encodeStart).TotalSeconds/$completed*($FullEncodingPlan.Count-$completed))
            "ETA: $([int]$eta.TotalHours)h $($eta.Minutes)m"
        } else { "Calculating ETA..." }

        Write-Log "========================================" -Color Cyan
        Write-Log "[$percent%] $etaString - $($completed+1)/$($FullEncodingPlan.Count) : $($vid.DisplayName)" -Color Cyan
        Write-Log "========================================" -Color Cyan
        $host.ui.RawUI.WindowTitle = "Encoding $($completed+1)/$($FullEncodingPlan.Count) - $($vid.DisplayName)"

        $reasons = @()
        if ($vid.HasBitmap)              { $reasons += "bitmap subtitles" }
        if ($vid.AudioInfo.HasLossless)  { $reasons += "lossless audio" }
        if ($vid.AudioInfo.HasAtmos)     { $reasons += "Atmos audio" }
        if ($reasons.Count -gt 0) { Write-Log "  MKV container due to: $($reasons -join ' and ')" -Color Yellow }

        $encodedDir = if ($vid.HasBitmap -and -not $vid.DoProcess) {
            "$($DstDir)VobSub\$($vid.VideoObject.Directory.Name)"
			#"$($vid.VideoObject.PSDrive.Root)Encoded\VobSub\$($vid.VideoObject.Directory.Name)"
        } else {
            "$DstDir$($vid.VideoObject.Directory.Name)"
			#"$($vid.VideoObject.PSDrive.Root)Encoded\$($vid.VideoObject.Directory.Name)"
        }
        $garbageDir = $GbgDir
		#$garbageDir = "$($vid.VideoObject.PSDrive.Root)Garbage\$($vid.VideoObject.Directory.Name)"
        $outputFile = "$encodedDir\$($vid.DisplayName)$($vid.Extension)"

        if (-not (Test-Path $encodedDir)) { Write-Log "  Creating: $encodedDir" -Color Yellow; New-Item $encodedDir -ItemType Directory | Out-Null }
        if (-not (Test-Path $garbageDir)) { Write-Log "  Creating: $garbageDir" -Color Yellow; New-Item $garbageDir -ItemType Directory | Out-Null }

        Write-Log "  Audio Strategy:" -Color Yellow
        $vid.AudioSummary -split "`n" | Where-Object { $_.Trim() } | ForEach-Object {
            Write-Log "    $_" -Color $(if ($_ -match "English") {"Cyan"} else {"Blue"})
        }

        Write-Log "  Subtitle Strategy:" -Color Yellow
        $sub = $vid.SubtitleStrategy
        $hbSubOrder = @()

        if ($sub.SubtitleList) {
            $i = 1
            $keys = $sub.SubtitleList.Split(',') | ForEach-Object { $_.Trim() }

            foreach ($k in $keys) {
                $track = $subtitleTracks | Where-Object { $_.TrackKey -eq $k } | Select-Object -First 1
                $classification = $vid.Classifications | Where-Object { $_.TrackKey -eq $k } | Select-Object -First 1

                if ($track) {
                    $trackName = if ($track.Title) { $track.Title
                    } elseif ($track.Language.Value) {
                        Get-ProposedTrackName $track.Language.Value
                    } else { "Unknown" }

                    $nameType = if ($classification) {
                        $classification.NameType
                    } else { "" }
                    
                    if ($classification.Default) { $nameType += ", Default" }
                    if ($sub.Burn) { $nameType += ", Burn" }
                    if ($classification.Forced) { $nameType += ", Forced" }
                    
                    Write-Log "    [$i] Track $k`: $trackName $nameType" -Color Cyan
                    $hbSubOrder += $i
                }
                $i++
            }
            $hbSubOrder = $hbSubOrder -split " " -join ","
        } else {
            Write-Log "    No subtitles to process" -Color DarkGray
        }

        Write-Log "  Input:  $($vid.VideoObject.FullName)" -Color Green
        Write-Log "  Preset: $($vid.PresetName)"           -Color Green
        Write-Log "  Output: $outputFile"                  -Color Green
        Write-Log "  Starting encode..."                    -Color Yellow

        $hbArgs = @(
            "--title",           $(if($vid.VideoObject.Name -eq "VIDEO_TS"){"0"}else{"1"}),
            "--preset-import-gui",
            "-Z",                $vid.PresetName,
            "-i",                "$($vid.VideoObject.FullName)",
            "--main-feature",
            "--audio",           ($vid.AudioArgs.Tracks   -join ","),
            "--aencoder",        ($vid.AudioArgs.Encoders  -join ","),
            "--mixdown",         ($vid.AudioArgs.Mixdowns  -join ","),
            "--ab",              ($vid.AudioArgs.Bitrates  -join ","),
            "--aname",           (($vid.AudioArgs.Names | ForEach-Object { "`"$_`"" }) -join ","),
            "-o",                "$outputFile"
        )
		foreach ($tk in $sub) {
Write-Host "DEBUG: vid istext $($vid.IsTextSub.IsText)"
Write-Host "DEBUG: vid doprocess $($vid.DoProcess)"
Write-Host "DEBUG: sub forced $($tk.ForcedTrack)"
Write-Host "DEBUG: sub burn $($tk.Burn)"
Write-Host "DEBUG: sub default $($tk.Default)"
		}
        if ($sub.SubtitleList) {
            $hbArgs += "--subtitle=$hbSubOrder" #$($sub.SubtitleList)"
            $i=0; $subNames = foreach ($name in $sub.Names) {
                $nt = if ($i -lt $vid.Classifications.Count) { $vid.Classifications[$i].NameType } else { "" }
                "`"$name $nt`""; $i++
            }
            $hbArgs += "--subname=$($subNames -join ',')"
            if ($vid.IsTextSub.IsText -or $vid.DoProcess) {
Write-Host "DEBUG: sub count $($sub.Count)"
                if ($sub.ForcedTrack) { $hbArgs += "--subtitle-forced=$($sub.ForcedTrack.TrackNum)" }
                if ($sub.Burn)        { $hbArgs += "--subtitle-burned=$($sub.SubtitleList.Split(',')[0])" }
                if ($sub.Default -contains $true) { $hbArgs += "--subtitle-default=$($sub.Default.IndexOf($true)+1)" }
            }
        }
Write-Host "DEBUG: hbargs = $($hbArgs -join ' ')" -ForegroundColor Red
        exit
        & $handBrakePath @hbArgs 2>> $logFile 3>$null
        $failed = $false
        if ($LASTEXITCODE -ne 0) { Write-Log "  FAILED - HandBrake exit $LASTEXITCODE" -Color Red; $failed=$true }
        if (-not (Test-Path $outputFile)) { Write-Log "  FAILED - Output not created" -Color Red; $failed=$true }
        elseif ((Get-Item $outputFile).Length -lt ($vid.VideoObject.Length*0.1)) { Write-Log "  FAILED - Output too small" -Color Red; $failed=$true }

        if ($failed) { if (Test-Path $outputFile) { Remove-Item $outputFile -Force }; continue }

        $compression = [math]::Round(((Get-Item $outputFile).Length/$vid.VideoObject.Length)*100,1)
        Write-Log "  SUCCESS! Compression: $compression%" -Color Green
        Move-Item $vid.VideoObject.FullName "$garbageDir\$($vid.VideoObject.Name).old"
        if ((Get-Item $vid.VideoObject.DirectoryName).GetFileSystemInfos().Count -eq 0) { Remove-Item $vid.VideoObject.DirectoryName }
        $completed++
    }

    $elapsed = (Get-Date) - $encodeStart
    Write-Log "========================================" -Color Green
    Write-Log "ENCODING COMPLETE!" -Color Green
    Write-Log "Total time: $($elapsed.Hours)h $($elapsed.Minutes)m" -Color Green
    Write-Log "Encoded: $completed/$($FullEncodingPlan.Count) videos" -Color Green
    Write-Log "========================================" -Color Green
    $host.ui.RawUI.WindowTitle = "Windows PowerShell"
}

# ============================================
# DISPATCH
# ============================================
if      ($SubReview)     { Invoke-SubReviewMode }
elseif  ($MetadataRemux) { Test-Dependency @(@{Name="FFmpeg";Path=$ffmpegPath}; @{Name="ffprobe";Path=$ffprobePath}); Invoke-MetadataRemux }
elseif  ($Encode)        { Invoke-EncodeMode }
elseif  ($AnalyzeOnly)   { Invoke-EncodeMode }
else {
	Write-Log "==============================================================================================================="
	Write-Log "Usage instructions: .\Claude-Unified.ps1 [switch (-DryRun)]"
	Write-Log ""
	Write-Log "-AnalyzeOnly".PadRight(30) -NoNewLine
	Write-Log "# Scans files, provides plan. No change to files."
	Write-Log "-SubReview".PadRight(30) -NoNewLine
	Write-Log "# Scans files for subtitles, allows manual review/editing of subtitles"
	Write-Log "-SubReview -DryRun".PadRight(30) -NoNewLine
	Write-Log "# Scans files for subtitles, allows manual review/editing of subtitles. Provides a dry run. No change to files"
	Write-Log "-MetadataRemux".PadRight(30) -NoNewLine
	Write-Log "# Scans files, allows editing of track names."
	Write-Log "-MetadataRemux -DryRun".PadRight(30) -NoNewLine
	Write-Log "# Scans files, provides a dry run for changing track names. No change to files"
	Write-Log "-Encode".PadRight(30) -NoNewLine
	Write-Log "# Scans files. Analyzes video, audio and subtitles subtitles. Creates encoding plan according to logic"
	Write-Log "".PadRight(30) -NoNewLine
	Write-Log "#   video resolution, types of audio tracks and languages, types of subtitle tracks and languages,etc "
	Write-Log "".PadRight(30) -NoNewLine
	Write-Log "#   Allows changing/customizing plan."
	Write-Log "-Encode -DryRun".PadRight(30) -NoNewLine
	Write-Log "# Scans files. Analyzes video, audio and subtitles subtitles. Creates encoding plan according to logic"
	Write-Log "".PadRight(30) -NoNewLine
	Write-Log "#   video resolution, types of audio tracks and languages, types of subtitle tracks and languages,etc "
	Write-Log "".PadRight(30) -NoNewLine
	Write-Log "#   Allows changing/customizing plan. No change to files"
}