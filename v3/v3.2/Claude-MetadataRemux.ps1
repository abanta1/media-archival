# ============================================
# Metadata Review & Batch Remux Script
# ============================================
param(
    [string]$SourceDir = "G:\Encoded\VobSub",
    [string]$OutputDir = "G:\Final_Library",
    [switch]$DryRun
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'
$OutputEncoding = [System.Text.Encoding]::UTF8

# ============================================
# Configuration & Dependencies
# ============================================
$mkvmergePath = "C:\Program Files\MKVToolNix\mkvmerge.exe"
$ffprobePath = "G:\ffprobe.exe" # Adjusted to your root per previous logs
$logFile = ".\remux_log_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
Set-Content -Path $logFile -Value "" -Encoding UTF8

# Ensure the log function exists BEFORE calling it
function Write-Log {
    param([string]$Message, [string]$Color = "White")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $Message"
    Write-Host $logMessage -ForegroundColor $Color
    $logMessage | Out-File -FilePath $logFile -Append -Encoding UTF8
}

if (-not (Test-Path $mkvmergePath)) { Write-Error "mkvmerge not found at $mkvmergePath"; exit }
if (-not (Test-Path $ffprobePath)) { Write-Error "ffprobe not found at $ffprobePath"; exit }

# ============================================
# 1. BATCH ANALYSIS PHASE
# ============================================
Write-Log "Searching in: $SourceDir" -Color Cyan
$files = Get-ChildItem -Path $SourceDir -Recurse | Where-Object { $_.Extension -match '\.(mkv|m4v|mp4)$' }
$batchData = @()

if ($null -eq $files -or $files.Count -eq 0) {
    Write-Log "ERROR: No files found in $SourceDir" -Color Red
    exit
}

Write-Log "Found $($files.Count) files. Analyzing metadata..." -Color Cyan

foreach ($file in $files) {
    Write-Log "Analyzing: $($file.Name)" -Color Yellow
    
    # Use ffprobe to get the REAL names/titles from M4V/MKV
    $ffCmd = & $ffprobePath -v error -show_entries stream=index,codec_type:stream_tags=title,handler_name,language -of json "$($file.FullName)" | ConvertFrom-Json
    
    $tracks = @()
    foreach ($s in $ffCmd.streams) {
		if ($s.codec_type -notin @("audio", "subtitle")) { continue }

		$existingName = ""
		$proposedName = ""
		if ($s.tags.title) { 
			$existingName = $s.tags.title 
			$firstWord = $existingName.Split(' ')[0].Trim()
			#Write-Host "    [DEBUG-HANDLER] First Word: '$firstWord' (Length: $($firstWord.Length))" -ForegroundColor Cyan
			#Write-Host "    [DEBUG-HEX] FirstWord Bytes: $([System.Text.Encoding]::UTF8.GetBytes($firstWord) -join ' ')" -ForegroundColor Red
			$proposedName = switch -Regex ($firstWord) {
				"English" { "English" }
				"Fran(c|ais|ch|\xe7ais)" { "Fran$([char]0xe7)ais" } # \xe7 matches ç
				"Span(ish|ish|ol)|Espa(ñ|.*|Ã±|\xf1)ol" { "Espa$([char]0xf1)ol" }
				"Italian|Italiano" { "Italiano" }
				"Russian|Русский|\x0420\x0443\x0441\x0441\x043a\x0438\x0439" { -join [char[]](0x0420, 0x0443, 0x0441, 0x0441, 0x043a, 0x0438, 0x0439) }
				"German|Deutsch" { "Deutsch" }
				default { $firstWord } # CHANGED: returning $firstWord prevents the double-up
			}
			
			if ($existingName -match ' ') {
				$suffix = $existingName.Substring($firstWord.Length)
				$proposedName = "$proposedName$suffix"
			}

		} elseif ($s.tags.handler_name -and $s.tags.handler_name -notmatch "handler") { 
			$existingName = $s.tags.handler_name
			#Write-Host "    [DEBUG-HANDLER] Raw Existing: '$existingName'" -ForegroundColor Cyan
			
			$firstWord = $existingName.Split(' ')[0].Trim()
			#Write-Host "    [DEBUG-HANDLER] First Word: '$firstWord'" -ForegroundColor Cyan
			#Write-Host "    [DEBUG-HANDLER] First Word: '$firstWord' (Length: $($firstWord.Length))" -ForegroundColor Cyan
			#Write-Host "    [DEBUG-HEX] FirstWord Bytes: $([System.Text.Encoding]::UTF8.GetBytes($firstWord) -join ' ')" -ForegroundColor Red
			$proposedName = switch -Regex ($firstWord) {
				"English" { "English" }
				"Fran(c|ais|ch|\xe7ais)" { "Fran$([char]0xe7)ais" } # \xe7 matches ç
				"Span(ish|ish|ol)|Espa(ñ|.*|Ã±|\xf1)ol" { "Espa$([char]0xf1)ol" }
				"Italian|Italiano" { "Italiano" }
				"Russian|Русский|\x0420\x0443\x0441\x0441\x043a\x0438\x0439" { -join [char[]](0x0420, 0x0443, 0x0441, 0x0441, 0x043a, 0x0438, 0x0439) }
				"German|Deutsch" { "Deutsch" }
				default { $firstWord } # CHANGED: returning $firstWord prevents the double-up
			}
			#Write-Host "    [DEBUG-HANDLER] After Switch: '$proposedName'" -ForegroundColor Cyan
			
			if ($existingName -match ' ') {
				$suffix = $existingName.Substring($firstWord.Length)
				#Write-Host "    [DEBUG-HANDLER] Suffix Found: '$suffix'" -ForegroundColor Cyan
				$proposedName = "$proposedName$suffix"
			}
			#Write-Host "    [DEBUG-HANDLER] Final Proposed: '$proposedName'" -ForegroundColor Cyan

		} else {
			$lang = if ($s.tags.language) { $s.tags.language } else { "und" }
			$existingName = "$lang $($s.codec_type)"
			$proposedName = $existingName
		}

		$tracks += [PSCustomObject]@{
			Id           = $s.index
			Type         = $s.codec_type
			Language     = if ($s.tags.language) { $s.tags.language } else { "und" }
			CurrentName  = $existingName
			NewName      = ""
			ProposedName = $proposedName
		}
	}
		
	$batchData += [PSCustomObject]@{
		FileInfo = $file
		Tracks   = $tracks
	}
}

# ============================================
# 2. USER PROMPT PHASE
# ============================================
Write-Host "`nAnalysis Complete. Starting User Input Phase..." -ForegroundColor Cyan

foreach ($item in $batchData) {
    Write-Host "`n=================================================" -ForegroundColor Gray
    Write-Host "FILE: $($item.FileInfo.Name)" -ForegroundColor Green
    Write-Host "=================================================" -ForegroundColor Gray
    
    foreach ($track in $item.Tracks) {
        Write-Host "  Track $($track.Id) [$($track.Type)]" -ForegroundColor Cyan
        Write-Host "  Current Name: " -NoNewline
        Write-Host "'$($track.CurrentName)'" -ForegroundColor Yellow
		Write-Host "  Proposed Name: " -NoNewline
		Write-Host "'$($track.ProposedName)'" -ForegroundColor Yellow
        
        $input = Read-Host "  Enter New Name (Enter to take suggested)"
        
        $track.NewName = if ([string]::IsNullOrWhiteSpace($input)) { $track.ProposedName } else { $input }
		Write-Host "Taking `"$($track.NewName)`" as Suggested"
    }
}

# ============================================
# 3. BATCH REMUX PHASE (M4V Version)
# ============================================
Write-Log "`nStarting Batch Remuxing (Keeping M4V)..." -Color Cyan

foreach ($item in $batchData) {
    $relativeDir = $item.FileInfo.DirectoryName.Replace($SourceDir, "").TrimStart('\')
    $targetDir = Join-Path $OutputDir $relativeDir
    if (-not (Test-Path $targetDir)) { New-Item $targetDir -ItemType Directory -Force | Out-Null }
    
    # Keeping the original extension (.m4v)
    $outputPath = Join-Path $targetDir "$($item.FileInfo.Name)"
    
    # Build FFmpeg Metadata arguments
    # -map 0 maps all streams. -c copy ensures NO re-encoding happens.
    $ffArgs = @("-i", "`"$($item.FileInfo.FullName)`"", "-map", "0", "-c", "copy")
    
    foreach ($track in $item.Tracks) {
        if ($track.NewName) {
            # Metadata tags for MP4/M4V use -metadata:s:index
            $ffArgs += "-metadata:s:$($track.Id)"
            $ffArgs += "title=`"$($track.NewName)`""
        }
    }
    
    $ffArgs += "`"$outputPath`""
    
    Write-Log "Remuxing: $($item.FileInfo.Name)" -Color Yellow
    
    if (-not $DryRun) {
        # Using Start-Process to handle quotes in names correctly
        $proc = Start-Process -FilePath $ffmpegPath -ArgumentList $ffArgs -Wait -NoNewWindow -PassThru
        if ($proc.ExitCode -eq 0) {
            Write-Log "  SUCCESS -> $outputPath" -Color Green
        } else {
            Write-Log "  FAILED with exit code $($proc.ExitCode)" -Color Red
        }
    } else {
        Write-Log "  [DRY RUN] Command: ffmpeg $($ffArgs -join ' ')" -Color Gray
    }
}

Write-Log "`nALL TASKS COMPLETE!" -Color Green