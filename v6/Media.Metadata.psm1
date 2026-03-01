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

    $height = Resolve-Field "Video Height" @{
        HandBrake = $RawMetaData.HbVideo.Height
        MediaInfo = $RawMetaData.MiVideo.Height
        MKVMerge = $RawMetaData.MkvJVideoHeight
        FFProbe = $RawMetaDta.FfVideo.Height
    } $weights

        $width = Resolve-Field "Video Width" @{
        HandBrake = $RawMetaData.HbVideo.Width
        MediaInfo = $RawMetaDta.MiVideo.Width
        MKVMerge = $RawMetaData.MkvJVideo.Width
        FFProbe = $RawMetaData.FfVideo.Width
    } $weights
   
    return $vidTracks += [PSCustomObject]@{
        Width = $width
        Height = $height
    }
}

function Merge-SubtitleMetadata {
    param([object]$RawMetaData, [hashtable]$Weights)

    $hbSubTracks = $RawMetaData.HbSubs
    $ffSubTracks = $RawMetaData.FfSubs
    $mkvJSubTracks = $RawMetaData.MkvJSubs
    $mkvISubTracks = $RawMetaData.MkvISubs
    $miSubTracks = $RawMetaData.MiSubs
    $ffPacketInfo = $RawMetaData.FfPackets
    
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

function Get-QualityScore {
    param([string]$codec)
    if (-not $codec -or $null -eq $codec -or $codec -eq 0 -or $codec -eq "") { return 0 }
    
    $quality = switch -Regex ($codec) {
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

# Other functions are isolated to this module, not exporting
Export-ModuleMember -Function Get-Metadata, Get-QualityScore
