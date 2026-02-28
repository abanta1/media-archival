function New-AudioStrategy {
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

function New-SubtitleMuxPlan {
    param(
        [array]$SubTracks,
        [string]$PrimaryAudioIso
    )

    # --- 1. INITIALIZATION & METADATA ---
    $allEntries = @()
    $needsManualReview = $false
    $allowedIso = @('eng','spa','fra','ita','rus')
    $nameMap = @{ 'eng'='English'; 'spa'='Spanish'; 'fra'='French'; 'ita'='Italian'; 'rus'='Russian' }
    
    if ($null -ne $SubTracks){
    Write-Host $SubTracks.GetType()
    } else {
        Write-Host "WARN: No subs found" -ForegroundColor Yellow
    }
    
    $SubTracks = $SubTracks | Where-Object { $allowedIso -contains $_.IsoCode }
    
    Write-Host $SubTracks.GetType()
    
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

function Get-ProposedTrackName {
    param([string]$existing)

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

function Export-SubtitleTrack {
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

function New-RemuxWithSubtitles {
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









Export-ModuleMember -Function New-AudioStrategy, New-SubtitleMuxPlan, Get-SubtitleClassification, Get-UserClassification, Get-ProposedTrackName