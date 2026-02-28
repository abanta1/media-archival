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
        $line = $e.Extent.StartLineNumber
        $col  = $e.Extent.StartColumnNumber
        $msg  = $e.Message
        Write-Output "ERROR: Line:$line Col:$col -- $msg"
        $start = [Math]::Max(1, $line-2)
        $end = $line+2
        try {
            $snippet = Get-Content $Target -TotalCount ($end) | Select-Object -Index ($start-1..($end-1)) -ErrorAction SilentlyContinue
            if ($snippet) { $i = $start; foreach ($s in $snippet) { Write-Output ('{0,4}: {1}' -f $i,$s); $i++ } }
        } catch { }
        Write-Output "----"
    }
} else { Write-Output 'No syntax errors' }
