function Invoke-EncodeMode {
    param(
        [string]$SrcDir,
        [int]$VidCountIn,
        [string]$DstDir,
        [string]$GbgDir,
        [string]$ffmpegPath,
        [string]$ffprobePath,
        [string]$mkvmergePath,
        [string]$mkvextractPath,
        [string]$mkvpropeditPath,
        [string]$handBrakePath,
        [string]$mediaInfoPath,
        [switch]$DryRun
    )
    Write-host "DEBUG: vidcount $VidCountIn"
    Write-Host "DEBUG: SrcDir=$SrcDir"
    Write-Host "DEBUG: ffmpegPath=$ffmpegPath"
    Test-Dependency @(
        @{ Name="FFmpeg";       Path=$ffmpegPath    }
        @{ Name="mkvmerge";     Path=$mkvmergePath  }
        @{ Name="mkvextract";   Path=$mkvextractPath}
        @{ Name="MediaInfo";    Path=$mediaInfoPath  }
        @{ Name="HandBrakeCLI"; Path=$handBrakePath  }
    )

    write-host "DEBUG: vidcount $VidCountIn"
    if ($null -eq $VidCountIn -or $VidCountIn -eq 0){
        $vids = Get-Vid -SrcDirPath $SrcDir
    } else {
        $vids = Get-Vid -SrcDirPath $SrcDir -VidCount $VidCountIn
    }
    if ($vids.Count -eq 0) { return }

    $FullEncodingPlan = @()
    Write-Log "`n---------------------------- PRE-FLIGHT ANALYSIS --------------------------------" -Color Cyan

    foreach ($vid in $vids) {
        Write-Log " Processing ($($vids.IndexOf($vid)+1)/$($vids.Count)): $($vid.Name)" -Color Green

        try { 
            $scan = Get-Metadata -VideoPath $vid.FullName `
                        -handBrakePath $handBrakePath -ffprobePath $ffprobePath `
                        -mkvmergePath $mkvmergePath -mediaInfoPath $mediaInfoPath `
                        -ffmpegPath $ffmpegPath
        }
        catch { $e = $_.Exception
            Write-Log "  CRITICAL ERROR scanning $($vid.Name) - skipping" -Color Red
            Write-Host "$e"
            continue
        }

        $audioInfo = $scan.Audio
		$adAnalysis = Get-ADAnalysis -AudioTracks $audioInfo.Tracks -FilePath $vid.FullName -ffmpegPath $ffmpegPath
		$adTrack = $adAnalysis.ADTrackNum
		$adConfidence = $adAnalysis.Confidence

		if ($adTrack -and ($adTrack -is [int])) {
			$t = $audioInfo.Tracks | Where-Object TrackKey -eq $adTrack
			if ($t) {
				$t.IsAD = $true
				$t.IsCommentary = $false
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

		$audioStrategy = New-AudioStrategy -AudioTracks $audioInfo.Tracks
        $audioSummary  = ($audioStrategy.DescriptionList | ForEach-Object { $_.Trim() -replace "\r","" } | Where-Object { $_ -match '\S' }) -join "`n"
        Write-Log "  Subtitle Strategy:" -Color Yellow
        $subtitleTracks = $scan.Subtitles
        $isTextSub     = @($subtitleTracks | Where-Object { $_.IsText })
        if ($isTextSub.Count -gt 0) { Write-Log "    Found $($isTextSub.Count) text subtitle tracks" -Color Yellow }
        $hasBitmap     = @($subtitleTracks | Where-Object { $_.IsBitmap })
        if ($hasBitmap.Count -gt 0) { Write-Log "    Found $($hasBitmap.Count) bitmap subtitle tracks" -Color Yellow }

		$primaryAudio = $audioInfo.Tracks[0]

        $subPlan = New-SubtitleMuxPlan -SubTracks $subtitleTracks -PrimaryAudioIso $primaryAudio.IsoCode
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
                SourceType = $entry.SourceType
                IsBitmap = ($entry.SourceType -eq 'Bitmap')
                IsText   = ($entry.SourceType -eq 'Text')
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
                } elseif ($track -and -not [string]::IsNullOrEmpty($track.Language)) {
                    $names += (Get-ProposedTrackName $track.Language)
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
                Type      = if($i -lt $subArr.Count){if($sub.Classifications[$i].IsBitmap){"Bitmap"}elseif($sub.Classifications[$i].IsText){"Text"}else{""}}else{""}
                'Sub Action'=if($i-lt $subArr.Count){if($sub.Classifications[$i].IsText){"Process"}else{"Copy"}}else{""}
                Default   = if($i-lt $sub.Classifications.Count){$sub.Classifications[$i].Default}else{""}
                Burn      = if($i-lt $subArr.Count){$sub.Burn}else{""}
                Forced    = if($i-lt $sub.Classifications.Count){$sub.Classifications[$i].Forced}else{""}
                Name      = if($i-lt $subArr.Count -and $sub.Names -is [array]){"$($sub.Names[$i]) $(if($i -lt $sub.Classifications.Count){$sub.Classifications[$i].NameType})"}else{""}
            }
        }
    }

    $cols = @(
        @{Expression="Title";Width=50}
		@{Expression="Quality";Width=10}
		@{Expression="File Ext";Width=10}
        @{Expression="Audio";Width=60}
		@{Expression="SubTitle";Width=10}
        @{Expression="Type";Width=10}
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
    if ($newLines.Count -gt 0) {
        Write-Log ($newLines -join "`n") -NoTimeStamp -Color White
    }

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
            $keys = $sub.SubtitleList.Split(',') | ForEach-Object { $_.Trim() }
            $i = 1

            foreach ($k in $keys) {
                $track = $subtitleTracks | Where-Object { $_.TrackKey -eq $k } | Select-Object -First 1
                $classification = $sub.Classifications | Where-Object { $_.TrackKey -eq $k } | Select-Object -First 1

                if ($track) {
                    $hbIndex = [int]$k - $vid.AudioInfo.Tracks.Count
                    $trackName = if ($i -le $sub.Names.Count) { $sub.Names[$i-1] } else { "Unknown" }

                    $nameType = if ($classification) {
                        $classification.NameType
                    } else { "" }
                    
                    if ($classification.Default) { $nameType += ", Default" }
                    if ($sub.Burn) { $nameType += ", Burn" }
                    if ($classification.Forced) { $nameType += ", Forced" }
                    
                    Write-Log "    [$i] Track $k`: $trackName $nameType" -Color Cyan
                    $hbSubOrder += $hbIndex
                    $i++
                }
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
        
        if ($sub.SubtitleList) {
            $hbArgs += "--subtitle=$hbSubOrder" #$($sub.SubtitleList)"
            $i=0; $subNames = foreach ($name in $sub.Names) {
                $nt = if ($i -lt $sub.Classifications.Count) { $sub.Classifications[$i].NameType } else { "" }
                "`"$name $nt`""; $i++
            }
            $hbArgs += "--subname=$($subNames -join ',')"
            if ($vid.IsTextSub.IsText -or $vid.DoProcess) {
                if ($sub.ForcedTrack) { $hbArgs += "--subtitle-forced=$($sub.ForcedTrack.TrackNum)" }
                if ($sub.Burn)        { $hbArgs += "--subtitle-burned=$($sub.SubtitleList.Split(',')[0])" }
                if ($sub.Default -contains $true) { $hbArgs += "--subtitle-default=$($sub.Default.IndexOf($true)+1)" } 
                else { $hbArgs += "--subtitle-default=none" }
            }
        }

        #Write-Host "DEBUG: hbargs $hbArgs"
        #exit
        
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

function Invoke-SubReviewMode {
    param(
        [string]$vobsubDir,
        [string]$encodedBaseDir,
        [string]$garbageBaseDir,
        [string]$classificationsFile,
        [string]$mkvmergePath,
        [string]$ffprobePath,
        [string]$ffmpegPath,
        [string]$handBrakePath,
        [string]$mediaInfoPath,
        [switch]$DryRun
    )
    
    Test-Dependency @(
        @{ Name="mkvmerge"; Path=$mkvmergePath }
        @{ Name="ffprobe";  Path=$ffprobePath  }
    )
    Write-Log "VobSub Manual Review & Remux" -Color Cyan
    Write-Log "Dry Run: $DryRun" -Color Yellow

    $vobsubFiles = Get-ChildItem -Path $vobsubDir -Recurse -Include *.mkv,*.m4v
    if ($vobsubFiles.Count -eq 0) { Write-Log "No files found in: $vobsubDir" -Color Yellow; return }
    Write-Log "Found $($vobsubFiles.Count) files to review" -Color Green

    $allClassifications = Get-Classification -ClassificationsFile $classificationsFile
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

		if ($userQuit) { Write-Log "User quit - saving progress" -Color Yellow; Save-Classification -Classifications $allClassifications -ClassificationsFile $classificationsFile; return }
	}

    Save-Classification -Classifications $allClassifications -ClassificationsFile $classificationsFile

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

    Save-Classification -Classifications $allClassifications -ClassificationsFile $classificationsFile
    Write-Log "`nPROCESSING COMPLETE! $processedCount/$($filesToProcess.Count) files" -Color Green
}

function Save-Classification {
    param(
        [Parameter(Mandatory=$true)][hashtable]$Classifications,
        [Parameter(Mandatory=$true)][string]$ClassificationsFile
    )
    $Classifications | ConvertTo-Json -Depth 5 | Out-File -FilePath $ClassificationsFile -Encoding UTF8
}

function Get-Classification {
    param([string]$ClassificationsFile)
    if (Test-Path $ClassificationsFile) {
        return Get-Content $ClassificationsFile -Raw | ConvertFrom-Json
    } else {
        return @{ files = @{} }
    }
}

function Invoke-MetadataRemux {
    param(
        [string]$metaSourceDir,
        [string]$metaOutputDir,
        [string]$ffmpegPath,
        [string]$ffprobePath,
        [switch]$DryRun
    )
    
    Test-Dependency @(
        @{Name="FFmpeg";Path=$ffmpegPath}
        @{Name="ffprobe";Path=$ffprobePath}
    )

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

# classification helper functions are implemented above
Export-ModuleMember -Function Invoke-SubReviewMode, Invoke-EncodeMode, Invoke-MetadataRemux