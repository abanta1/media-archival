$mkvs = Get-ChildItem -Recurse -Include *.mkv
foreach ($mkv in $mkvs){
$host.ui.RawUI.WindowTitle = “Encoding $($mkvs.IndexOf($mkv))/$($mkvs.Count) - $($mkv.Directory.Name)/$($mkv.Name)”
If (-not (Test-Path "$($mkv.PSDrive.Root)\Encoded\$($mkv.Directory.Name)")){
Write-Host "-------------------------------------------------------------------------------Creating Encoded directory $($mkv.psdrive.root)\Encoded\$($mkv.directory.name)"
New-Item "$($mkv.psdrive.root)\Encoded\$($mkv.directory.name)" -ItemType Directory
}
If (-not (Test-Path "$($mkv.PSDrive.Root)\Garbage\$($mkv.Directory.Name)")){
New-Item "$($mkv.psdrive.root)\Garbage\$($mkv.directory.name)" -ItemType Directory
Write-Host "-------------------------------------------------------------------------------Creating Garbage directory $($mkv.psdrive.root)\Garbage\$($mkv.directory.name)"
}
Write-Host """C:\Users\abanta\Downloads\HandBrakeCLI-1.5.1-win-x86_64\HandBrakeCLI.exe -Z ""Fast 1080p30"" -i ""$($mkv.FullName)"" --main-feature -o ""$($mkv.psdrive.root)Encoded\$($mkv.directory.name)\$($mkv.BaseName).m4v"""
C:\Users\abanta\Downloads\HandBrakeCLI-1.5.1-win-x86_64\HandBrakeCLI.exe --preset-import-gui -Z "Fast 1080p30" -i "$($mkv.FullName)" --main-feature -o "$($mkv.psdrive.root)Encoded\$($mkv.directory.name)\$($mkv.BaseName).m4v"
If ($?) {
Write-Host "----------------------------------------------------------------------------------------------------------------Encode successful - Moving item to garbage"
Move-Item "$($mkv.FullName)" "$($mkv.psdrive.root)\Garbage\$($mkv.directory.name)\$($mkv.Name).old"
} else { Write-Host "---------------------------------------------------------------------------------------------------------------------Not encoded, not moving"
}
}
$host.ui.RawUI.WindowTitle = "Windows PowerShell"