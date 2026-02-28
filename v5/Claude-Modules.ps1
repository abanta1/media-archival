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

$moduleName = @(
	"Media.IO.psm1",
	"Media.Normalize.psm1",
	"Media.Metadata.psm1",
	"Media.Workflows.psm1",
	"Media.Process.psm1"
)

foreach ($module in $moduleName){
	$modulePath = Join-Path $PSScriptRoot $module
	Import-Module $modulePath -Force #-Verbose
}

[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'

$vobsubDir           = $SrcDir         # SubReview: input folder
$encodedBaseDir      = $DstDir         # SubReview: output root
$garbageBaseDir      = $GbgDir         # SubReview: garbage root
$classificationsFile = ".\vobsub_classifications.json"
$metaSourceDir       = $SrcDir         # MetadataRemux: input
$metaOutputDir       = $DstDir         # MetadataRemux: output

$searchRoots = @("C:\AV Tools")

$ffmpegPath      = Find-Tool "ffmpeg.exe"       $searchRoots
$ffprobePath     = Find-Tool "ffprobe.exe"      $searchRoots
$mkvmergePath    = Find-Tool "mkvmerge.exe"     $searchRoots
$mkvextractPath  = Find-Tool "mkvextract.exe"   $searchRoots
$mkvpropeditPath = Find-Tool "mkvpropedit.exe"  $searchRoots
$handBrakePath   = Find-Tool "HandBrakeCLI.exe" $searchRoots
$mediaInfoPath   = Find-Tool "MediaInfo.exe"    $searchRoots



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
	Write-Log " "
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