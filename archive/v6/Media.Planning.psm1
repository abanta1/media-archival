function Select-Preset {
    param(
        [int]$Height,
        [bool]$HasAtmos,
        [bool]$HasLossless,
        [bool]$IsDVD,
        [bool]$HasBitmapSub
    )

    if ($HasAtmos -or $HasLossless -or $HasBitmapSub) {
        $ext = "mkv"; $ct = "mkv"
        if ($HasBitmapSub) { Write-Log "  Bitmap subtitles detected - using MKV" -Color Green }
        else               { Write-Log "  Atmos/Lossless audio detected - using MKV" -Color Green }
    } else {
        $ext = "m4v"; $ct = "m4v"
    }

    if ($IsDVD -or $Height -le 480) {
        Write-Log "  SD/DVD source - using DVD preset" -Color Yellow
        return [PSCustomObject]@{ Preset = "Mine-265-10b-$ct-dvd"; Extension = ".$ext" }
    } elseif ($Height -le 1080) {
        Write-Log "  1080p source - using BD preset" -Color Green
        return [PSCustomObject]@{ Preset = "Mine-265-10b-$ct-bd";  Extension = ".$ext" }
    } else {
        Write-Log "  4K source - using 4K preset" -Color Green
        return [PSCustomObject]@{ Preset = "Mine-265-10b-$ct-4k";  Extension = ".$ext" }
    }
}

function New-EncodingPlan {
    param(
        [string]$VideoPath,
        [string]$DisplayName,
        [bool]$IsDVD,
        [object]$Metadata,          # output of Get-Metadata
        [hashtable]$AudioStrategy,  # output of New-AudioStrategy
        [hashtable]$SubtitlePlan,   # output of New-SubtitleMuxPlan
        [object]$Preset             # output of Select-Preset
    )

    # --- Audio rows ---
    $audioRows = @()
    for ($i = 0; $i -lt $AudioStrategy.Tracks.Count; $i++) {
        $audioRows += [PSCustomObject]@{
            NewIndex  = $i
            TrackKey  = $AudioStrategy.Tracks[$i]
            Encoder   = $AudioStrategy.Encoders[$i]
            Mixdown   = $AudioStrategy.Mixdowns[$i]
            Bitrate   = $AudioStrategy.Bitrates[$i]
            Name      = $AudioStrategy.Names[$i]
        }
    }

    # --- Subtitle rows ---
    $subRows = @()
    $newSubIdx = 0
    foreach ($entry in $SubtitlePlan.Plan) {
        $subRows += [PSCustomObject]@{
            NewIndex   = $newSubIdx
            TrackKey   = $entry.TrackKey
            SourceType = $entry.SourceType   # 'Bitmap' or 'Text'
            Action     = $entry.Action       # 'Copy', 'Process', 'Burn'
            Role       = $entry.Role         # 'standard', 'sdh', 'forced', 'commentary', 'foreign'
            IsoCode    = $entry.Language
            Name       = "$(Convert-IsoToLanguage $entry.Language) $(switch ($entry.Role) {
                              'standard'  { 'Standard'  }
                              'sdh'       { 'SDH'       }
                              'forced'    { 'Forced'    }
                              'commentary'{ 'Commentary'}
                              'foreign'   { 'Standard'  }
                              default     { $entry.Role }
                          })"
            Default    = $entry.Default
            Forced     = $entry.Forced
        }
        $newSubIdx++
    }

    # --- Flags ---
    $hasBitmap   = ($subRows | Where-Object { $_.SourceType -eq 'Bitmap' }).Count -gt 0
    $resolution  = $Metadata.Video.Height.Value

    return [PSCustomObject]@{
        # Identity
        DisplayName = $DisplayName
        VideoPath   = $VideoPath
        IsDVD       = $IsDVD

        # Preset
        PresetName  = $Preset.Preset
        Extension   = $Preset.Extension
        Resolution  = $resolution

        # Tracks
        Audio       = $audioRows
        Subtitles   = $subRows

        # Flags
        HasBitmap        = $hasBitmap
        NeedsReview      = $SubtitlePlan.NeedsManualReview
        HasAtmos         = $Metadata.Audio.HasAtmos
        HasLossless      = $Metadata.Audio.HasLossless
    }
}

function Invoke-Encode {
    param(
        [object]$Plan,
        [string]$OutputPath,
        [string]$handBrakePath,
        [string]$logFile,
        [bool]$DryRun = $false
    )

    Write-Log "  Input:  $($Plan.VideoPath)"  -Color Green
    Write-Log "  Preset: $($Plan.PresetName)" -Color Green
    Write-Log "  Output: $OutputPath"          -Color Green

    # --- Build audio args ---
    $trackNums = $Plan.Audio.TrackKey  -join ","
    $encoders  = $Plan.Audio.Encoder   -join ","
    $mixdowns  = $Plan.Audio.Mixdown   -join ","
    $bitrates  = $Plan.Audio.Bitrate   -join ","
    $anames    = ($Plan.Audio.Name | ForEach-Object { "`"$_`"" }) -join ","

    # --- Build subtitle args ---
    $subKeys   = $Plan.Subtitles.TrackKey -join ","
    $subNames  = ($Plan.Subtitles.Name | ForEach-Object { "`"$_`"" }) -join ","

    $burnEntry   = $Plan.Subtitles | Where-Object { $_.Action -eq 'Burn' }  | Select-Object -First 1
    $forcedEntry = $Plan.Subtitles | Where-Object { $_.Forced -eq $true }   | Select-Object -First 1
    $defaultEntry= $Plan.Subtitles | Where-Object { $_.Default -eq $true }  | Select-Object -First 1

    $hbArgs = @(
        "--title",             $(if ($Plan.IsDVD) { "0" } else { "1" }),
        "--preset-import-gui",
        "-Z",                  $Plan.PresetName,
        "-i",                  $Plan.VideoPath,
        "--main-feature",
        "--audio",             $trackNums,
        "--aencoder",          $encoders,
        "--mixdown",           $mixdowns,
        "--ab",                $bitrates,
        "--aname",             $anames,
        "-o",                  $OutputPath
    )

    if ($subKeys) {
        $hbArgs += "--subtitle=$subKeys"
        $hbArgs += "--subname=$subNames"

        if ($burnEntry)    { $hbArgs += "--subtitle-burned=$($burnEntry.NewIndex + 1)" }
        if ($forcedEntry)  { $hbArgs += "--subtitle-forced=$($forcedEntry.NewIndex + 1)" }
        if ($defaultEntry) { $hbArgs += "--subtitle-default=$($defaultEntry.NewIndex + 1)" }
    }

    Write-Log "  Starting encode..." -Color Yellow

    if ($DryRun) {
        Write-Log "  [DRY RUN] HandBrakeCLI $($hbArgs -join ' ')" -Color Gray
        return $true
    }

    & $handBrakePath @hbArgs 2>> $logFile 3>$null

    if ($LASTEXITCODE -ne 0) {
        Write-Log "  FAILED - HandBrake exit $LASTEXITCODE" -Color Red
        return $false
    }

    if (-not (Test-Path $OutputPath)) {
        Write-Log "  FAILED - Output not created" -Color Red
        return $false
    }

    $srcSize = (Get-Item $Plan.VideoPath).Length
    $outSize = (Get-Item $OutputPath).Length

    if ($outSize -lt ($srcSize * 0.1)) {
        Write-Log "  FAILED - Output too small ($outSize vs $srcSize)" -Color Red
        return $false
    }

    $compression = [math]::Round(($outSize / $srcSize) * 100, 1)
    Write-Log "  SUCCESS! Compression: $compression%" -Color Green
    return $true
}

Export-ModuleMember -Function Select-Preset, New-EncodingPlan, Invoke-Encode