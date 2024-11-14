[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateScript({ $_ | Test-Path -PathType Container })]
    [string]
    $LandingZonePath,

    [Parameter(Mandatory)]
    [ValidateScript({ $_ | Test-Path -PathType Container })]
    [string]
    $RootLandingZonesPath,

    [Parameter(Mandatory)]
    [ValidateScript({ $_ | Test-Path -PathType Container })]
    [string]
    $DecommissionedLandingZonesPath,

    [Parameter(Mandatory)]
    [ValidateScript({ $_ | Test-Path -PathType Container })]
    [string]
    $SolutionPath
)

Write-Debug "Move-LandingZoneDirectory.ps1: Started"
Write-Debug "Input parameters: $($PSBoundParameters | ConvertTo-Json -Depth 3)"

#* Establish defaults
$scriptRoot = $PSScriptRoot
Write-Debug "Working directory: $((Resolve-Path -Path .).Path)"
Write-Debug "Script root directory: $(Resolve-Path -Relative -Path $scriptRoot)"

#* Resolve files
$lzFile = Get-Item -Path "$LandingZonePath/metadata.json" -Force
$lzDirectory = Get-Item -Path $LandingZonePath -Force
Write-Debug "[$($lzDirectory.BaseName)] Found $($lzFile.Name) file."

#* Parse Landing Zone configuration file
$lzConfig = Get-Content -Path $lzFile.FullName -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 10

##################################
###* Move landing zone directory to disabled landing zones directory
##################################
#region
Write-Host "Move landing zone directory to disabled landing zones directory"

#* Resolve relative paths to ensure consistent compares
$relativeLandingZonePath = Resolve-Path -Relative $LandingZonePath
$relativeRootLandingZonesPath = Resolve-Path -Relative $RootLandingZonesPath
$relativeDecommissionedLandingZonesPath = Resolve-Path -Relative $DecommissionedLandingZonesPath

#* Determine current root path
$isInRootLandingZonesDirectory = $relativeLandingZonePath.StartsWith("$relativeRootLandingZonesPath$([System.IO.Path]::DirectorySeparatorChar)")
$isInDecommissionedLandingZonesDirectory = $relativeLandingZonePath.StartsWith("$relativeDecommissionedLandingZonesPath$([System.IO.Path]::DirectorySeparatorChar)")
$isInUnknownDirectory = !$isInRootLandingZonesDirectory -and !$isInDecommissionedLandingZonesDirectory

#* Determine if landing zone directory should be moved
$shouldBeMoved = $false
if ($lzConfig.decommissioned -and $isInRootLandingZonesDirectory) {
    $shouldBeMoved = $true
    $targetPath = $relativeLandingZonePath -replace ([Regex]::Escape($relativeRootLandingZonesPath)), $relativeDecommissionedLandingZonesPath
}
elseif (!$lzConfig.decommissioned -and $isInDecommissionedLandingZonesDirectory) {
    $shouldBeMoved = $true
    $targetPath = $relativeLandingZonePath -replace ([Regex]::Escape($relativeDecommissionedLandingZonesPath)), $relativeRootLandingZonesPath
}
elseif ($isInUnknownDirectory) {
    Write-Host "Skipping. Landing Zone path does not match 'RootLandingZonesPath' or 'DecommissionedLandingZonesPath'. Unable to calculate source/destination paths."
}
else {
    Write-Host "Skipping. Landing Zone already located in the correct root directory."
}

#* Move directory if applicable
if ($shouldBeMoved) {
    Write-Host "Moving Landing Zone directory to [$targetPath]"

    #* Create parent directory if applicable
    $parentPath = [System.IO.Path]::GetRelativePath(".", [System.IO.Directory]::GetParent($targetPath).FullName)
    if (!(Test-Path -Path $parentPath)) {
        New-Item -ItemType Directory -Path $parentPath -Force | Out-Null
    }
    
    #* Move directory
    Move-Item -Path $relativeLandingZonePath -Destination $targetPath -Force
    $moveSucceeded = $?
}

#endregion

##################################
###* Push changes to GitHub
##################################
#region
Write-Host "Push changes to GitHub"

if ($shouldBeMoved -and $moveSucceeded) {
    git add $relativeLandingZonePath
    git add $targetPath
    git pull -q
    git stash save --keep-index --include-untracked | Out-Null
    git commit -m "[skip ci] Move Landing Zone to correct root directory. [$relativeLandingZonePath] to [$targetPath]"
    git push -q
    if ($LASTEXITCODE) {
        Write-Warning "Unable to push changes!"
        exit 1
    }
}
else {
    Write-Host "Skipping. Landing Zone directory already located in the correct root directory."
}

#endregion