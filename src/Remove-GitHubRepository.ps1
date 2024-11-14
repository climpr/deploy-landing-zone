[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateScript({ $_ | Test-Path -PathType Container })]
    [string]
    $LandingZonePath,

    [Parameter(Mandatory)]
    [ValidateScript({ $_ | Test-Path -PathType Container })]
    [string]
    $SolutionPath
)

Write-Debug "Remove-GitHubRepository.ps1: Started"
Write-Debug "Input parameters: $($PSBoundParameters | ConvertTo-Json -Depth 3)"

#* Establish defaults
$scriptRoot = $PSScriptRoot
Write-Debug "Working directory: $((Resolve-Path -Path .).Path)"
Write-Debug "Script root directory: $(Resolve-Path -Relative -Path $scriptRoot)"

#* Import Modules
Import-Module $scriptRoot/modules/support-functions.psm1 -Force

#* Resolve files
$lzFile = Get-Item -Path "$LandingZonePath/metadata.json" -Force
$lzDirectory = Get-Item -Path $LandingZonePath -Force
Write-Debug "[$($lzDirectory.BaseName)] Found $($lzFile.Name) file."

#* Parse Landing Zone configuration file
$lzConfig = Get-Content -Path $lzFile.FullName -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 10

#* Declare git variables
$org = $lzConfig.organization
$repo = $lzConfig.repoName

#* Find existing Git repository if any
$repoInfo = gh repo view $org/$repo --json "name,isArchived" | ConvertFrom-Json

$failedEnvironmentOperations = @()

if ($repoInfo) {
    Write-Host "Found GitHub repo '$repo'"

    ##################################
    ###* Processing environments
    ##################################
    #region
    Write-Host "Processing environments"

    #* Process Environments
    foreach ($environment in $lzConfig.environments) {
        $environmentName = $environment.name

        ##################################
        ###* Processing environment
        ##################################
        #region
        Write-Host "Processing environment: $($environmentName)"

        if ($environment.decommissioned) {
            try {
                Invoke-GitHubCliApiMethod -Method "DELETE" -Uri "/repos/$org/$repo/environments/$environmentName"
                Write-Host "[$environmentName] Successfully deleted GitHub environment."
            }
            catch {
                $failedEnvironmentOperations += $environmentName
                Write-Error "[$environmentName] Unable to delete GitHub environment file. GitHub Api response: $($_.Exception)"
            }
        }
        else {
            Write-Debug "Skipped. Environment not set to decommissioned in $($lzFile.Name) file."
        }

        #endregion
    }
    
    #endregion

    ##################################
    ###* Archive repository
    ##################################
    #region
    Write-Host "Archive repository"

    if ($lzConfig.decommissioned) {
        if (!$repoInfo.isArchived) {
            Write-Host "Archiving repository."
            gh repo archive $org/$repo --yes
        }
        else {
            Write-Debug "Repository already archived."
        }
    }
    
    #endregion
}
else {
    Write-Debug "Skipped. Repository not found."
}
        
#endregion