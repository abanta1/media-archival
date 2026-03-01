
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
    $timestamp = if ($NoTimeStamp) { "" } else { "[$([DateTime]::Now.ToString('yyyy-MM-Ddd HH:mm:ss'))]" }
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
        if ($line -match '^id:\s*([a-z]{2,3})') { $info.IsoCode = Convert-IsoCode $matches[1]; $info.Language = $info.IsoCode }
        if ($line -match '(?i)forced\s*subs:\s*on')             { $info.IsForced = $true }
        if ($line -match '(?i)(sdh|hearing.impaired|closed.caption|cc)') { $info.IsSDH = $true }
        if ($line -match '(?i)commentary')                       { $info.IsCommentary = $true }
    }
    
    if ($idxPath -match '(?i)(sdh|cc|hearing)') { $info.IsSDH = $true }
    if ($idxPath -match '(?i)commentary')        { $info.IsCommentary = $true }
    
    return $info
}

Export-ModuleMember -Function Write-Log, Find-Tool, Test-Dependency, Read-Srt, Read-VobSubIdx