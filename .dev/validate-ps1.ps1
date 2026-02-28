param([string]$Target = 'c:\Users\abanta\Media-Archival\Claude-Unified.ps1')

$errors = $null
try {
    [void][System.Management.Automation.Language.Parser]::ParseFile($Target,[ref]$errors,[ref]$null)
} catch {
    Write-Output "PARSER-EXCEPTION: $($_.Exception.Message)"
    exit 2
}

if ($errors -and $errors.Count -gt 0) {
    foreach ($e in $errors) {
        Write-Output ("SYNTAX: Line:{0} Col:{1} {2}" -f $e.Extent.StartLineNumber, $e.Extent.StartColumnNumber, $e.Message)
    }
} else {
    Write-Output 'No syntax errors'
}

if (Get-Module -ListAvailable -Name PSScriptAnalyzer) {
    try {
        Import-Module PSScriptAnalyzer -ErrorAction Stop
        $res = Invoke-ScriptAnalyzer -Path $Target -Severity Error,Warning -Recurse
        if ($res -and $res.Count -gt 0) {
            $res | Select-Object Severity,RuleName,Line,Message | Format-Table -AutoSize
        } else {
            Write-Output 'PSScriptAnalyzer: No findings'
        }
    } catch {
        Write-Output "PSScriptAnalyzer error: $($_.Exception.Message)"
    }
} else {
    Write-Output 'PSScriptAnalyzer not installed'
}
