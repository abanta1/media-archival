function Get-Metadata {
    param(
        [string]$VideoPath,
        [string]$handBrakePath,
        [string]$ffprobePath,
        [string]$mkvmergePath,
        [string]$mediaInfoPath,
        [string]$ffmpegPath
    )

    # high-level entry; raw metadata retrieval will log tool details
    Write-Log "  Gathering metadata from various sources..." -Color Yellow

    $weights = @{ HandBrake = 1; MediaInfo = 3; MKVMerge = 4; FFProbe = 5 }

    $raw          = Get-RawMetadata        -VideoPath $VideoPath `
                                         -handBrakePath $handBrakePath `
                                         -ffprobePath $ffprobePath `
                                         -mkvmergePath $mkvmergePath `
                                         -mediaInfoPath $mediaInfoPath `
                                         -ffmpegPath $ffmpegPath
    $audio        = Merge-AudioMetadata    -RawMetaData $raw -Weights $weights
    $subs         = Merge-SubtitleMetadata -RawMetaData $raw -Weights $weights
    $video        = Merge-VideoMetadata    -RawMetaData $raw -Weights $weights

    return [PSCustomObject]@{
        Subtitles = $subs
        Audio     = $audio
        Video     = $video
    }
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
        Write-Log "   Retreiving HandBrake metadata" -Color Yellow
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

    Write-Log "   Retreiving ffmpeg metadata" -Color Yellow
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

    Write-Log "   Retreiving MKVMerge metadata" -Color Yellow
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
    }

    # Assign Track Key for MKV-I
    for ($i = 0; $i -lt $mkvIAudioTracks.Count; $i++) {
        $mkvIAudioTracks[$i] | Add-Member -MemberType NoteProperty -Name "TrackKey" -Value ($i + 1)
    }
    for ($i = 0; $i -lt $mkvISubTracks.Count; $i++) {
        $mkvISubTracks[$i] | Add-Member -MemberType NoteProperty -Name "TrackKey" -Value ($mkvIAudioTracks.Count + $i + 1)
    }

    Write-Log "   Retreiving MediaInfo metadata" -Color Yellow
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

function Merge-AudioMetadata {
    param([object]$RawMetaData, [hashtable]$Weights)

    $hbAudioTracks = $RawMetaData.HbAudio
    $ffAudioTracks = $RawMetaData.FfAudio
    $mkvJAudioTracks = $RawMetaData.MkvJAudio
    $mkvIAudioTracks = $RawMetaData.MkvIAudio
    $miAudioTracks = $RawMetaData.MiAudio

    Write-Log "  Processing audio metadata..." -Color Green
    $normHbAudio = @()
    if ($hbAudioTracks) {
        foreach ($track in $hbAudioTracks) {
            $trackLang = if (-not $track.Language) {
                if ($track.LanguageCode) {
                    if ($track.LanguageCode.Trim() -match '^[a-z]{2,3}$') {
                        $l = Convert-IsoCode $track.LanguageCode.Trim().ToLower()
                        $tIsoCode = $l
                        Convert-IsoToLanguage $l
                    } else { "Unknown" }
                } else { "Unknown"}
            } else { $track.Language }

            $format = ($track.Description -replace '^[^(]+\(', '' -replace '\)$', '')
            $tCodec = Convert-AudioCodecName -codec $format
            $quality = Get-QualityScore -codec $tCodec
            $tIsoCode = Convert-IsoCode $track.LanguageCode

            $normHbAudio += [PSCustomObject]@{
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

    $normFfAudio = @()
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


        $normFfAudio += [PSCustomObject]@{
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
    

    $normMkvIAudio = @()
    foreach ($track in $mkvIAudioTracks) {
        $normMkvIAudio += [PSCustomObject]@{
            TrackKey = $track.TrackKey
            Type = $track.Type
        }
    }

    $normMkvJAudio = @()
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
        $tChannel = switch ($track.properties.audio_channels) {
                { $_ -ge 7.1 } { "7.1" }
                { $_ -ge 5.1 } { "5.1" }
                { $_ -ge 2.0 } { "2.0" }
                { $_ -ge 1.0 } { "1.0" }
                default        { "$($_) ch" }
            }
            $tBitRate = [math]::Round($track.bit_rate / 1000)

        $normMkvJAudio += [PSCustomObject]@{
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

    $normMiAudio = @()
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

        $normMiAudio += [PSCustomObject]@{
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

    $tracks = @()

    foreach ($track in $ffAudioTracks) {

        $key = $track.TrackKey

        $miAudio = $normMiAudio | Where-Object { $_.TrackKey -eq $key } | Select-Object -First 1
        #$mkviam = $normMkvIAudio | Where-Object { $_.TrackKey -eq $key } | Select-Object -First 1
        $mkvJAudio = $normMkvJAudio | Where-Object { $_.TrackKey -eq $key } | Select-Object -First 1
        $hbAudio  = $normHbAudio  | Where-Object { $_.TrackKey -eq $key } | Select-Object -First 1
        $ffAudio  = $normFfAudio  | Where-Object { $_.TrackKey -eq $key } | Select-Object -First 1

        $ad = Resolve-Field "AD" @{
            HandBrake = if ($null -ne $hbAudio.IsAD) { [bool]$hbAudio.IsAD } else { $false }
            MediaInfo = if ($null -ne $miAudio.IsAD) { [bool]$miAudio.IsAD } else { $false }
            MKVMerge = if ($null -ne $mkvJAudio.IsAD) { [bool]$mkvJAudio.IsAD } else { $false }
            FFProbe = if ($null -ne $ffAudio.IsAD) { [bool]$ffAudio.IsAD } else { $false }
        } $weights

        $bitrate = Resolve-Field "Bitrate" @{
            HandBrake = $hbAudio.BitRate
            MediaInfo = $miAudio.BitRate
            MKVMerge = $mkvJAudio.BitRate
            FFProbe = $ffAudio.BitRate
        } $weights

        $channels = Resolve-Field "Channels" @{ # 6 (5.1)
            HandBrake = $hbAudio.Channels
            MediaInfo = $miAudio.Channels
            MKVMerge = $mkvJAudio.Channels
            FFProbe = $ffAudio.Channels
        } $weights

        $codec = Resolve-Field "Codec" @{
            HandBrake = $hbAudio.Codec
            MediaInfo = $miAudio.Codec
            MKVMerge = $mkvJAudio.Codec
            FFProbe = $ffAudio.Codec
        } $weights

        $commentary = Resolve-Field "Commentary" @{
            HandBrake = if ($null -ne $hbAudio.IsCommentary) { [bool]$hbAudio.IsCommentary } else { $false }
            MediaInfo = if ($null -ne $miAudio.IsCommentary) { [bool]$miAudio.IsCommentary } else { $false }
            MKVMerge = if ($null -ne $mkvJAudio.IsCommentary) { [bool]$mkvJAudio.IsCommentary } else { $false }
            FFProbe = if ($null -ne $ffAudio.IsCommentary) { [bool]$ffAudio.IsCommentary } else { $false }
        } $weights

        $default = Resolve-Field "Default" @{
            HandBrake = if ($null -ne $hbAudio.IsDefault) { [bool]$hbAudio.IsDefault } else { $false }
            MediaInfo = if ($null -ne $miAudio.IsDefault) { [bool]$miAudio.IsDefault } else { $false }
            MKVMerge = if ($null -ne $mkvJAudio.IsDefault) { [bool]$mkvJAudio.IsDefault } else { $false }
            FFProbe = if ($null -ne $ffAudio.IsDefault) { [bool]$ffAudio.IsDefault } else { $false }
        } $weights

        $description = Resolve-Field "Description" @{
            HandBrake = $hbAudio.Description
            MediaInfo = $miAudio.Description
            MKVMerge = $mkvJAudio.Description
            FFProbe = $ffAudio.Description
        } $weights

        $english = Resolve-Field "English" @{
            HandBrake = if ($null -ne $hbAudio.IsEnglish) { [bool]$hbAudio.IsEnglish } else { $false }
            MediaInfo = if ($null -ne $miAudio.IsEnglish) { [bool]$miAudio.IsEnglish } else { $false }
            MKVMerge = if ($null -ne $mkvJAudio.IsEnglish) { [bool]$mkvJAudio.IsEnglish } else { $false }
            FFProbe = if ($null -ne $ffAudio.IsEnglish) { [bool]$ffAudio.IsEnglish } else { $false }
        } $weights
        
        $forced = Resolve-Field "Forced" @{
            HandBrake = if ($null -ne $hbAudio.IsForced) { [bool]$hbAudio.IsForced } else { $false }
            MediaInfo = if ($null -ne $miAudio.IsForced) { [bool]$miAudio.IsForced } else { $false }
            MKVMerge = if ($null -ne $mkvJAudio.IsForced) { [bool]$mkvJAudio.IsForced } else { $false }
            FFProbe = if ($null -ne $ffAudio.IsForced) { [bool]$ffAudio.IsForced } else { $false }
        } $weights

        $iso = Resolve-Field "IsoCode" @{
            HandBrake = $hbAudio.IsoCode
            MediaInfo = $miAudio.IsoCode
            MKVMerge = $mkvJAudio.IsoCode
            FFProbe = $ffAudio.IsoCode
        } $weights

        $lang = Resolve-Field "Language" @{
            HandBrake = $hbAudio.Language
            MediaInfo = $miAudio.Language
            MKVMerge = $mkvJAudio.Language
            FFProbe = $ffAudio.Language
        } $weights

        $name = Resolve-Field "Name" @{
            HandBrake = $hbAudio.Name
            MediaInfo = $miAudio.Name
            MKVMerge = $mkvJAudio.Name
            FFProbe = $ffAudio.tags.title
        } $weights

        $quality = Resolve-Field "Quality" @{
            HandBrake = $hbAudio.Quality
            MediaInfo = $miAudio.Quality
            MKVMerge = $mkvJAudio.Quality
            FFProbe = $ffAudio.Quality
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
    
    return $unifiedAudio
}

function Merge-VideoMetadata {
param([object]$RawMetaData, [hashtable]$Weights)

    $hbVideoTracks = $RawMetaData.HbVideo
    $ffVideoTracks = $RawMetaData.FfVideo
    $mkvVideoTracks = $RawMetaData.MkvJVideo
    $miVideoTracks = $RawMetaData.MiVideo

    $vidTracks = @()
    foreach ($track in $hbVideoTracks) {
        $height = Resolve-Field "Video Height" @{
            HandBrake = $track.Height
            MediaInfo = $miVideoTracks.Height
            MKVMerge = $mkvVideoTracks.Height
            FFProbe = $ffVideoTracks.Height
         } $weights

         $width = Resolve-Field "Video Width" @{
            HandBrake = $track.Width
            MediaInfo = $miVideoTracks.Width
            MKVMerge = $mkvVideoTracks.Width
            FFProbe = $ffVideoTracks.Width
         } $weights

         $vidTracks += [PSCustomObject]@{
            Width = $width
            Height = $height
        }
    }

    $unifiedVideo = $vidTracks

    return $unifiedVideo
}

function Merge-SubtitleMetadata {
    param([object]$RawMetaData, [hashtable]$Weights)

    $hbSubTracks = $RawMetaData.HbSubs
    $ffSubTracks = $RawMetaData.FfSubs
    $mkvJSubTracks = $RawMetaData.MkvJSubs
    $mkvISubTracks = $RawMetaData.MkvISubs
    $miSubTracks = $RawMetaData.MiSubs
    
    Write-Log "  Processing subtitle metadata..." -Color Green

    # HandBrake
    $normHbSubs = @()
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

        $normHbSubs += [PSCustomObject]@{
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
    $normFfSubs = @()
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

        $normFfSubs += [PSCustomObject]@{
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
    $normMkvJSubs = @()
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

            $normMkvJSubs += [PSCustomObject]@{
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
    $normMkvISubs = @()
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

        $normMkvISubs += [PSCustomObject]@{
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
    $normMiSubs = @()
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

            $normMiSubs += [PSCustomObject]@{
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

    foreach ($miTrack in $normMiSubs) {
        $mkvJMatch = $normMkvJSubs | Where-Object { $_.TrackKey -eq $miTrack.TrackKey } | Select-Object -First 1
        $mkvIMatch = $normMkvISubs | Where-Object { $_.TrackKey -eq $miTrack.TrackKey } | Select-Object -First 1
        $ffMatch = $normFfSubs | Where-Object { $_.TrackKey -eq $miTrack.TrackKey } | Select-Object -First 1
        $ffPMatch = $ffPacketInfo | Where-Object { $_.TrackKey -eq $miTrack.TrackKey } | Select-Object -First 1
        $hbMatch = $normHbSubs | Where-Object { $_.TrackKey -eq $miTrack.TrackKey } | Select-Object -First 1

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
             MKVMerge = if ($mkvJMatch.IsoCode) { Convert-IsoToLanguage $mkvJMatch.IsoCode } else { $null }
             FFProbe = $ffMatch.Language
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

                Language = $lang.Value
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

    return $unifiedSubs
}

function Get-SubtitleHash (){
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

function Get-ADAnalysis {
    param(
        [array]$AudioTracks,
        [string]$FilePath,
        [string]$ffmpegPath
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
        $r1 = Get-CenterRMS -FilePath $FilePath -TrackKey ($eng[0].TrackKey - 1) -ffmpegPath $ffmpegPath
        $r2 = Get-CenterRMS -FilePath $FilePath -TrackKey ($eng[1].TrackKey - 1) -ffmpegPath $ffmpegPath
        $maxR = [math]::Max($r1, $r2)
        $f1_rms = ($maxR - $r1) / 10
        $f2_rms = ($maxR - $r2) / 10
    } else {
        $f1_rms = 0; $f2_rms = 0
    }

    # LRA
    Write-Log "  Loudness Range (LRA)..." -Color Yellow
    $l1 = Get-AudioLRA -FilePath $FilePath -StreamIndex ($eng[0].TrackKey - 1) -ffmpegPath $ffmpegPath
    $l2 = Get-AudioLRA -FilePath $FilePath -StreamIndex ($eng[1].TrackKey - 1) -ffmpegPath $ffmpegPath
    $maxL = [math]::Max($l1, $l2)
    $f1_lra = ($maxL - $l1)
    $f2_lra = ($maxL - $l2)

    # Spectral flatness (stereo fallback)
    if ($eng[0].Channels.Value -le 2.0 -and $eng[1].Channels.Value -le 2.0) {
        $sf1 = Get-SpectralFlatness -FilePath $FilePath -StreamIndex ($eng[0].TrackKey - 1) -ffmpegPath $ffmpegPath
        $sf2 = Get-SpectralFlatness -FilePath $FilePath -StreamIndex ($eng[1].TrackKey - 1) -ffmpegPath $ffmpegPath
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

function Get-ExtractedSubtitle {
    param([string]$basePath, [int]$trackNum, [bool]$MetadataForced)
    $r = [PSCustomObject]@{ TrackNum=$trackNum; Language=''; IsForced=$MetadataForced; IsText=$false; IsSDH=$false; IsCommentary=$false; IsoCode=''; IsVobSub=$false; Hash='' }
    $srt="$basePath.srt"; $idx="$basePath.idx"; $sub="$basePath.sub"; $sup="$basePath.sup"; $ass="$basePath.ass"
    if (Test-Path $srt) {
        $r.IsText=$true; $p=Read-Srt -SrtPath $srt
        $r.IsSDH=$p.IsSDH; $r.IsCommentary=$p.IsCommentary; $r.IsForced=$p.IsForced
        $iso="eng"; if ($srt -match '\.(spa|fra|ita|rus)\.srt$') { $iso=$matches[1] }
        $r.Language=$iso; $r.IsoCode=$iso
    } elseif ((Test-Path $idx) -and (Test-Path $sub)) {
        $r.IsVobSub=$true; $p=Read-VobSubIdx -IdxPath $idx
        $r.Language=$p.Language; $r.IsoCode=$p.IsoCode; $r.IsSDH=$p.IsSDH; $r.IsCommentary=$p.IsCommentary
        if ($MetadataForced -or $p.IsForced) { $r.IsForced=$true }
    } elseif (Test-Path $sub)  { $r.IsVobSub=$true; $r.IsoCode="und"; $r.Language="und" }
    elseif (Test-Path $sup)    { $r.IsoCode="und"; $r.Language="und" }
    elseif (Test-Path $ass)    { $r.IsText=$true; $r.IsoCode="und"; $r.Language="und" }
    else { Write-Log "  WARNING: No subtitle file found at $basePath" -Color Red }
    return $r
}

function Get-Vid {
    param([Parameter(mandatory=$true)][string]$SrcDirPath,[int]$VidCountIn)

    $results = @(Get-ChildItem -Path "$SrcDirPath" -Recurse -Include *.mkv,VIDEO_TS | Where-Object {
        $folderPart    = if ($_.Name -eq 'VIDEO_TS') { $_.Parent.Name }    else { $_.Directory.Name }
        $baseNamePart  = if ($_.Name -eq 'VIDEO_TS') { $_.Parent.Name }    else { $_.BaseName }
        $outBase       = "$($_.PSDrive.Root)Encoded\$folderPart\$baseNamePart"
        $outVob        = "$($_.PSDrive.Root)Encoded\VobSub\$folderPart\$baseNamePart"
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

# Other functions are isolated to this module, not exporting
Export-ModuleMember -Function Get-Metadata, Get-Vid, Get-ADAnalysis