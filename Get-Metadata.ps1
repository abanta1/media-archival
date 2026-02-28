function Get-Metadata {
    param([string]$VideoPath)
    
    # Scan Once
    
    # HandBrake metadata scan
    # if needed in future, full scan
    # $hbScan = & $handBrakePath --scan -i $VideoPath 2>&1
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

    $hbAudioTracks = $hbJson.TitleList.AudioList
    $hbSubTracks = $hbJson.TitleList.SubtitleList


    # ffprobe metadata scan
    $ff = & $ffprobePath -v error -show_streams "$VideoPath"
    $ffPackets = & $ffprobePath -v error -count_packets -show_entries stream=index,codec_type,nb_read_packets -of default=noprint_wrappers=1 "$VideoPath" 2>&1
    $ffPacketInfo = @()
    for ($i = 0; $i -lt $ffPackets.Count; $i += 3) {
        $indexLine = $ff[$i]
        $codecLine = $ff[$i + 1]
        $packetLine = $ff[$i + 2]

        $index = ($indexLine -split '=')[1].Trim()
        $codec = ($codecLine -split '=')[1].Trim()
        $packets = ($packetLine -split '=')[1].Trim()
        
        $ffPacketInfo += [PSCustomObject]@{
            Index = [int]$index
            CodecType = $codec
            PacketCount = [int]$packets
        }
    }
    $ffJson = & $ffprobePath -v error -show_streams -of json "$VideoPath" | ConvertFrom-Json
    $ffAudioTracks = $ffJson.streams | Where-Object { $_.codec_type -eq "audio" }
    $ffSubTracks = $ffJson.streams | Where-Object { $_.codec_type -eq "subtitle" }

    # mkvmerge json metadata scan
    $mkvJson = & $mkvmergePath -J "$VideoPath" | ConvertFrom-Json
    $mkvJAudioTracks = $mkvJson.tracks | Where-Object { $_.type -eq "audio" }
    $mkvJSubTracks = $mkvJson.tracks | Where-Object { $_.type -eq "subtitles" }

    # mkvmerge -i metadata scan
    $mkvI = & $mkvmergePath -i "$VideoPath" 2>&1
    $mkvIAudioTracks = foreach ($line in $mkvI) {
        if ($line -match '^Track ID (\d+): audio \((.+)\)$') {
            [PSCustomObject]@{
                MKVTrackID = [int]$matches[1]
                Type = $matches[2].ToLower()
            }
        }
    }
    $mkvISubTracks = foreach ($line in $mkvI) {
        if ($line -match '^Track ID (\d+): subtitles \((.+)\)$') {
            [PSCustomObject]@{
                MKVTrackID = [int]$matches[1]
                Type = $matches[2].ToLower()
            }
        }
    }
    
    # MediaInfo metadata scan
    $miJson = & $mediainfoPath --Output=JSON "$VideoPath" | ConvertFrom-Json
    $miAudioTracks = $miJson.media.track | Where-Object { $_.'@type' -eq "Audio" }
    $miSubTracks = $miJson.media.track | Where-Object { $_.'@type' -eq "Text" }


    #
    # Audio processing
    #

    $hbAudioMetadata = @()
    if ($hbAudioTracks) {
        foreach ($track in $hbAudioTracks) {
            $hbAudioMetadata += [PSCustomObject]@{
                Commentary = $track.Attributes.Commentary
                Default = $track.Attributes.Default
                VisualImpaired = $track.Attributes.VisualImpaired
                Bitrate = $track.Bitrate
                Channels = $track.Channels
                CodecID = $track.CodecName
                Description = $track.Description
                Language = $track.Language
                IsoCode = Convert-IsoCode $track.LanguageCode
                Name = $track.Name                
                TrackNum = $track.Track
                Original = $track
            }
        }
    }

    $ffAudioMetadata = @()
    foreach ($track in $ffAudioTracks) {
        $ffAudioMetadata += [PSCustomObject]@{
            TrackNum = [int]$track.index
            CodecName = $track.codec_name
            BitRate = if ($track.bit_rate) { [int]$track.bit_rate } else { 0 }
            Channels = if ($track.channels) { [double]$track.channels } else { 0 }
            Language = $track.tags.language
            Title = $track.tags.title
            IsAD = $track.disposition.visual_impaired
        }
    }

    $mkvIAudioMetadata = @()
    foreach ($track in $mkvIAudioTracks) {
        $mkvIAudioMetadata += [PSCustomObject]@{
            MKVTrackID = $track.MKVTrackID
            Type = $track.Type
        }
    }

    $mkvJAudioTracks = @()
    foreach ($track in $mkvJAudioTracks) {
        $mkvJAudioTracks += [PSCustomObject]@{
            TrackNum = $track.id
            Codec = $track.codec
            Language = $track.properties.language
            Channels = $track.properties.audio_channels
            BitRate = $track.properties.tags_bps
            Name = $track.properties.track_name
            IsDefault = $track.properties.default_track
            IsForced = $track.properties.forced_track
        }
    }

    $miAudioTracks = @()
    foreach ($track in $miAudioTracks) {
        $miAudioTracks += [PSCustomObject]@{
            TrackNum = [int]$track.ID
            Codec = $track.Format
            Bitrate = if ($track.BitRate) { [int]$track.BitRate } else { 0 }
            Channels = if ($track.Channels) { [double]$track.Channels } else { 0 }
            Language = Convert-IsoCode $track.Language
            Title = $track.Title
        }
    }































    # Merge ffprobe, mkvmerge, MediaInfo with HandBrake data and apply hybrid scoring to resolve conflicts

    $tracks = @()
    $index = 0

    foreach ($ff in $ffAudioTracks) {
        $index++
        
        $mkv = $mkvAudioTracks | Where-Object { $_.id -eq ($index - 1) } | Select-Object -First 1

        $hb = $hbAudioTracks | Where-Object { $_.TrackNum -eq $index } | Select-Object -First 1

        $lang = $ff.tags.language
        if (-not $lang -and $mkv.properties.language) { $lang = $mkv.properties.language }
        if (-not $lang -and $hb.IsoCode) { $lang = $hb.IsoCode }

        $iso = $null
        if ($lang -match '^[a-z]{3}$') { $iso = $lang.ToLower() }
         elseif ($lang -match '^[a-z]{2}$') { $iso = Convert-IsoCode $lang.ToLower() }
        
        $title = $ff.tags.title
        if (-not $title -and $mkv.properties.title) { $title = $mkv.properties.title }

        $disp = $ff.disposition
        $rawMeta = ($ff | ConvertTo-Json -Depth 5)

        $channels = if ($ff.channels) { [double]$ff.channels } elseif ($hb.Channels) { $hb.Channels } elseif ($mkv.properties.audio_channels) { [double]$mkv.properties.audio_channels } else { 0 }

        $codec = if ($ff.codec_name) { $ff.codec_name } elseif ($hb.CodecID) { $hb.CodecID } elseif ($mkv.codec_id) { $mkv.codec_id } else { $null }

        $bitrate = if ($ff.bit_rate) { [int]$ff.bit_rate } elseif ($hb.Bitrate) { [int]$hb.Bitrate } elseif ($mkv.properties.audio_bit_rate) { [int]$mkv.properties.audio_bit_rate } else { 0 }

        $isEng = ($iso -eq 'eng')
        $isCommentary = $false
        if ($title -match '(?i)commentary|director|producer|writer|behind the scenes|interview') {
            $isCommentary = $true
        } elseif ($hb.Original -match '(?i)commentary|director|producer|writer|behind the scenes|interview') {
            $isCommentary = $true
        } elseif ($disp.commentary -eq 1) {
            $isCommentary = $true
        }

        $tracks += [PSCustomObject]@{
            TrackNum = $index
            MKVTrackID = if ($null -ne $mkv.id) { $mkv.id } else { $index - 1 }
            Language = $lang
            IsoCode = $iso
            IsEnglish = $isEng
            IsCommentary = $isCommentary
            Channels = $channels
            Codec = $codec
            Bitrate = $bitrate
            Title = $title
            RawMetadata = $rawMeta
            Original = if ($hb.Original) { $hb.Original } elseif ($mkv) { $mkv } else { $ff }
            IsAD = $false
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
    #   # SUBTITLE TRACKS - Hybrid Scoring Example
    #
    #
    $weights = @{
        HandBrake = 2
        MediaInfo = 3
        MKVMerge = 2
        FFProbe = 4
    }

    # HandBrake
    $hbSubMetadata = @()
    foreach ($track in $hbSubTracks) {
        $hbSubMetadata += [PSCustomObject]@{
            TrackNum = [int]$track.TrackNumber
            Language = $track.Language
            IsoCode = Convert-IsoCode $track.LanguageCode
            CodecID = $track.SourceName.ToLower()
            Forced = $track.Attributes.Forced
            Default = $track.Attributes.Default
        }
    }
    
    # FFProbe
    $ffSubMetadata = @()
    foreach ($track in $ffSubTracks) {
        $ffSubMetadata += [PSCustomObject]@{
            TrackNum = [int]$track.index
            Language = $track.tags.language
            IsoCode = Convert-IsoCode $track.tags.language.ToLower()
            CodecID = $track.codec_name
            Forced = $track.disposition.forced
            Default = $track.disposition.default
            IsSDH = $track.disposition.hearing_impaired
        }
    }

    # MKVMerge -J
    $mkvSubs = @()
    foreach ($track in $mkvJSubTracks) {
            $iso = Convert-IsoCode $track.properties.language

            $fc = 0
            if ($track.properties.tag_number_of_frames) {
                $fc = [int]$track.properties.tag_number_of_frames
            } elseif ($track.properties.number_of_frames) {
                $fc = [int]$track.properties.number_of_frames
            } elseif ($track.properties.num_index_entries) {
                $fc = [int]$track.properties.num_index_entries
            }

            $mkvJSubs += [PSCustomObject]@{
                MKVTrackID = $track.id
                IsoCode = $iso
                CodecID = $track.codec_id
                Forced = $track.properties.forced -eq '1'
                Default = $track.properties.default -eq '1' 
                FrameCount = $fc
            }
    }

    # MKVMerge -i
    $mkvISubs = @()
    $subIdx = 0
    foreach ($track in $mkvISubTracks) {
        $mkvISubs += [PSCustomObject]@{
            MKVTrackID = $track.MKVTrackID
            Type = $track.Type
            SubIndex = $subIdx
        }
        $subIdx++
    }

    # MediaInfo
    $miSubs = @()
    $miIndex = 0
    foreach ($track in $miSubTracks) {
            $miIndex++
            $iso = Convert-IsoCode $track.Language

            $miSubs += [PSCustomObject]@{
                TrackNum = $miIndex
                IsoCode = $iso
                Language = $iso
                ElementCount = if ($track.ElementCount) { [int]$track.ElementCount } else { 0 }
                Forced = $track.Forced -eq 'Yes'
                Default = $track.Default -eq 'Yes' 
                Title = $track.Title
                Format = $track.Format
                CodecID = $track.CodecID
                StreamSize = if ($track.StreamSize) { [int]$track.StreamSize } else { 0 }
            }
    }


    # Hybrid Scoring helper
    function Resolve-Field {
        param([string]$FieldName, [hashtable]$Values, [hashtable]$Weights)

        $clean = $Values.GetEnumerator() | Where-Object { $null -ne $_.Value -and $_.Value -ne "" }

        if ($clean.Count -eq 0) {
            return [PSCustomObject]@{
                Value = $null
                Confidence = "Low"
                Reason = "No tool provided $FieldName"
                Sources = $Values
            }
        }

        # All identical ?
        $unique = $clean.Value | Select-Object -Unique
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

    # Merge + hybrid score for all fields
    $unifiedSubs = @()

    foreach ($mi in $miSubs) {
        $mkvMatch = $mkvSubs | Where-Object { $_.IsoCode -eq $mi.IsoCode } | Select-Object -First 1
        $mapMatch = $map | Where-Object { $_.MKVTrackID -eq $mkvMatch.MKVTrackID }

        # ffprobe fallback for element count
        $ffEC = 0
        if ($mi.ElementCount -eq 0 -and $mkvMatch.FrameCount -eq 0) {
            $ffSubPackets = $ffPacketInfo | Where-Object { $_.CodecType -eq "subtitle" }
            if ($ffSubPackets.Count -ge $mi.TrackNum) {
                $ffEC = $ffSubPackets[($mi.TrackNum - 1)].PacketCount
            }
        }

        # Hybrid scoring for each field
        $ec = Resolve-Field "ElementCount" @{
            MediaInfo = $mi.ElementCount
            MKVMerge = $mkvMatch.FrameCount
            FFProbe = $ffEC
        } $weights

        $forced = Resolve-Field "Forced" @{
            MediaInfo = $mi.Forced
            MKVMerge = $mkvMatch.Forced
            FFProbe = $null
        } $weights

        $default = Resolve-Field "Default" @{
            MediaInfo = $mi.Default
            MKVMerge = $mkvMatch.Default
            FFProbe = $null
        } $weights

        $lang = Resolve-Field "Language" @{
             MediaInfo = $mi.Language
             MKVMerge = $mkvMatch.IsoCode
             FFProbe = $null
        } $weights

        $format = Resolve-Field "Format" @{
             MediaInfo = $mi.Format
             MKVMerge = $mkvMatch.CodecID
             FFProbe = $null
        } $weights

        $codec = Resolve-Field "CodecID" @{
             MediaInfo = $mi.CodecID
             MKVMerge = $mkvMatch.CodecID
             FFProbe = $null
        } $weights

        # Track level confidence rollup

        $confLevels = @($ec.Confidence, $forced.Confidence, $default.Confidence, $lang.Confidence, $format.Confidence, $codec.Confidence)
        $trackConf = if ($confLevels -contains "Low") {
            "Low"
        } elseif ($confLevels -contains "Medium") {
            "Medium"
        } else {
            "High"
        }

        # Unified object
        $unifiedSubs += [PSCustomObject]@{
                TrackNum = $mi.TrackNum
                MKVTrackID = $mkvMatch.MKVTrackID
                MKVOrder = $mapMatch.SubIndex

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

                StreamSize = $mi.StreamSize
                Title = $mi.Title

                IsBitmap = ($format.Value -match 'subrip|ass|ssa|vobsub|pgs|hdmv_pgs_subtitle' -or $codec.Value -match 'dvdsub|hdmv_pgs_subtitle')
                IsText = ($format.Value -match 'srt|ass|ssa|subrip' -and $codec.Value -notmatch 'dvdsub|hdmv_pgs_subtitle')

                TrackConfidence = $trackConf
            }
    }

    return [PSCustomObject]@{
        Subtitles = $unifiedSubs
        Audio = $unifiedAudio
    }
}