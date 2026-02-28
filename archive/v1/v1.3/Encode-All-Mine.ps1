function Get-Vids {	
	$global:vids = @()	
	$vids2 = @()
	#Create array of videos
	$global:vids += Get-ChildItem -Recurse -Include *.mkv,VIDEO_TS | Sort-Object -Property Length
    #-Exclude *_t[0-9][0-9].mkv | Sort-Object -Property Length
	#create second array starting with VIDEO_TS folders
	$vids2 += $global:vids | where { $_.Name -eq 'VIDEO_TS' }
	#Add non-VIDEO_TS files to array
	$vids2 += $global:vids | where { $_.Name -ne 'VIDEO_TS' }
	#Copy array2 into array1
	$global:vids = $vids2
	#delete array2
	$vids2 = ''
}

Get-Vids

#Encode array of vids
foreach ($vid in $global:vids){
	If ($vid.Name -Like "VIDEO_TS"){
		$host.ui.RawUI.WindowTitle = "Encoding $($global:vids.IndexOf($vid)+1)/$($global:vids.Count) - $($vid.Parent.Name)"
		If (-not (Test-Path "$($vid.PSDrive.Root)\Encoded\$($vid.Parent.Name)")){
			Write-Host "-------------------------------------------------------------------------------Creating Encoded directory $($vid.psdrive.root)\Encoded\$($vid.parent.name)"
			New-Item "$($vid.psdrive.root)\Encoded\$($vid.parent.name)" -ItemType Directory
		}
		If (-not (Test-Path "$($vid.PSDrive.Root)\Garbage\$($vid.Parent.Name)")){
			New-Item "$($vid.psdrive.root)\Garbage\$($vid.parent.name)" -ItemType Directory
			Write-Host "-------------------------------------------------------------------------------Creating Garbage directory $($vid.psdrive.root)\Garbage\$($vid.parent.name)"
		}
		Write-Host """C:\Users\abanta\Downloads\HandBrakeCLI-1.5.1-win-x86_64\HandBrakeCLI.exe -Z ""Mine"" -i ""$($vid.FullName)"" --main-feature -o ""$($vid.psdrive.root)Encoded\$($vid.parent.name)\$($vid.Parent.Name).m4v"""
		C:\Users\abanta\Downloads\HandBrakeCLI-1.5.1-win-x86_64\HandBrakeCLI.exe --preset-import-gui -Z "Mine" -i "$($vid.FullName)" --main-feature -o "$($vid.psdrive.root)Encoded\$($vid.parent.name)\$($vid.Parent.Name).m4v"
		If ($?) {
			Write-Host "----------------------------------------------------------------------------------------------------------------Encode successful - Moving item to garbage"
			Move-Item "$($vid.FullName)" "$($vid.psdrive.root)\Garbage\$($vid.parent.name)\$($vid.Name).old"
		} else {
				Write-Host "---------------------------------------------------------------------------------------------------------------------Not encoded, not moving"
		}
	} ElseIf ($vid.Name -Like "*.mkv"){
		$host.ui.RawUI.WindowTitle = "Encoding $($global:vids.IndexOf($vid)+1)/$($global:vids.Count) - $($vid.Directory.Name)/$($vid.Name)"
		If (-not (Test-Path "$($vid.PSDrive.Root)\Encoded\$($vid.Directory.Name)")){
			Write-Host "-------------------------------------------------------------------------------Creating Encoded directory $($vid.psdrive.root)\Encoded\$($vid.directory.name)"
			New-Item "$($vid.psdrive.root)\Encoded\$($vid.directory.name)" -ItemType Directory
		}
		If (-not (Test-Path "$($vid.PSDrive.Root)\Garbage\$($vid.Directory.Name)")){
			New-Item "$($vid.psdrive.root)\Garbage\$($vid.directory.name)" -ItemType Directory
			Write-Host "-------------------------------------------------------------------------------Creating Garbage directory $($vid.psdrive.root)\Garbage\$($vid.directory.name)"
		}
		Write-Host """C:\Users\abanta\Downloads\HandBrakeCLI-1.5.1-win-x86_64\HandBrakeCLI.exe -Z ""Mine"" -i ""$($vid.FullName)"" --main-feature -o ""$($vid.psdrive.root)Encoded\$($vid.directory.name)\$($vid.BaseName).m4v"""
		C:\Users\abanta\Downloads\HandBrakeCLI-1.5.1-win-x86_64\HandBrakeCLI.exe --preset-import-gui -Z "Mine" -i "$($vid.FullName)" --main-feature -o "$($vid.psdrive.root)Encoded\$($vid.directory.name)\$($vid.BaseName).m4v"
		If ($?) {
			Write-Host "----------------------------------------------------------------------------------------------------------------Encode successful - Moving item to garbage"
			Move-Item "$($vid.FullName)" "$($vid.psdrive.root)\Garbage\$($vid.directory.name)\$($vid.Name).old"
		} else {
			Write-Host "---------------------------------------------------------------------------------------------------------------------Not encoded, not moving"
		}
	}
	#Get-Vids
	If (-Not $vids){ 
		Write-Host "No more vids to encode, exiting" 
		break 
		}
}
$host.ui.RawUI.WindowTitle = "Windows PowerShell"

#Stop-Computer -Force
#shutdown -f -s -t 0