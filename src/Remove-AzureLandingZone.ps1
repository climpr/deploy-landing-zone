#Requires -Modules @{ ModuleName="Az.Accounts"; ModuleVersion="2.17.0" }
#Requires -Modules @{ ModuleName="Az.Subscription"; ModuleVersion="0.11.0" }

[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateScript({ $_ | Test-Path -PathType Container })]
    [string]
    $LandingZonePath,

    [Parameter(Mandatory)]
    [ValidateScript({ $_ | Test-Path -PathType Container })]
    [string]
    $ArchetypesPath,

    [Parameter(Mandatory)]
    [ValidateScript({ $_ | Test-Path -PathType Container })]
    [string]
    $SolutionPath
)

Write-Debug "Remove-AzureLandingZone.ps1: Started"
Write-Debug "Input parameters: $($PSBoundParameters | ConvertTo-Json -Depth 3)"

#* Establish defaults
$scriptRoot = $PSScriptRoot
$failedDeployments = @()
Write-Debug "Working directory: $((Resolve-Path -Path .).Path)"
Write-Debug "Script root directory: $(Resolve-Path -Relative -Path $scriptRoot)"

#* Import Modules
Import-Module $scriptRoot/modules/azure.psm1 -Force

#* Resolve files
$lzFile = Get-Item -Path "$LandingZonePath/metadata.json" -Force
$lzDirectory = Get-Item -Path $LandingZonePath -Force
Write-Debug "[$($lzDirectory.BaseName)] Found $($lzFile.Name) file."

#* Parse climprconfig.json
$climprConfigPath = (Test-Path -Path "$SolutionPath/climprconfig.json") ? "$SolutionPath/climprconfig.json" : "climprconfig.json"
$climprConfig = Get-Content -Path $climprConfigPath | ConvertFrom-Json -AsHashtable -Depth 10 -NoEnumerate

#* Declare climprconfig settings
$decommissionedManagementGroupId = $climprConfig.lzManagement.decommissionedManagementGroupId

#* Parse Landing Zone configuration file
$lzConfig = Get-Content -Path $lzFile.FullName -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 10

##################################
###* Processing environments
##################################
#region
Write-Host "Processing environments"

#* Create Environments
foreach ($environment in $lzConfig.environments) {
    $environmentName = $environment.name

    ##################################
    ###* Processing environment
    ##################################
    #region
    Write-Host "Processing environment: $($environmentName)"

    #* Process Azure subscription
    if ($environment.azure) {
        #* Check if Azure subscription should be decommissioned
        $shouldBeDecommissioned = $lzConfig.decommissioned -or $environment.decommissioned -or $environment.azure.decommissioned
        
        if ($shouldBeDecommissioned) {
            #* Get subscription
            $subscriptionId = $environment.azure.subscriptionId
            $subscriptionInfo = Get-AzSubscription | Where-Object { $_.Id -eq $subscriptionId }

            try {
                ##################################
                ###* Running Decommission pre-scripts
                ##################################
                #region

                Write-Host "Running Decommission pre-scripts"

                if ($subscriptionInfo) {
                    if ($subscriptionInfo.State -eq "Enabled") {
                        #* Invoke Pre scripts
                        $param = @{
                            Path              = $lzDirectory.FullName
                            ScriptType        = "DecommissionPre"
                            ArchetypePath     = Join-Path $ArchetypesPath -ChildPath $($environment.azure.archetype)
                            LandingZoneConfig = $lzConfig 
                            Environment       = $environmentName
                        }
                        Invoke-LzScripts @param
                    }
                    else {
                        Write-Host "Skipping. Subscription already in disabled state."
                    }
                }
                else {
                    Write-Host "Skipping. Subscription not found."
                }

                #endregion

                ##################################
                ###* Disabling subscription
                ##################################
                #region

                Write-Host "Disabling subscription"

                if ($subscriptionInfo) {
                    if ($subscriptionInfo.State -eq "Enabled") {
                        $null = Disable-AzSubscription -Id $subscriptionId -Confirm:$false
                    }
                    else {
                        Write-Host "Skipping. Subscription already in disabled state."
                    }
                }
                else {
                    Write-Host "Skipping. Subscription not found."
                }

                #endregion

                ##################################
                ###* Moving subscription to Decommissioned Management Group
                ##################################
                #region

                Write-Host "Moving subscription to Decommissioned Management Group"

                if ($subscriptionInfo) {
                    if ($subscriptionInfo.State -eq "Enabled") {
                        $isInDecommissionedMg = [bool](Get-AzManagementGroupSubscription -SubscriptionId $subscriptionId -GroupName $decommissionedManagementGroupId -ErrorAction Ignore)
                        if ($isInDecommissionedMg) {
                            Write-Host "Skipping. Subscription is already in Decommissioned Management Group."
                        }
                        else {
                            $null = New-AzManagementGroupSubscription -GroupId $decommissionedManagementGroupId -SubscriptionId $subscriptionId -ErrorAction Stop
                            Write-Host "Moving subscription to Decommissioned Management Group."
                        }
                    }
                    else {
                        Write-Host "Skipping. Subscription is not disabled."
                    }
                }
                else {
                    Write-Host "Skipping. Subscription not found."
                }

                #endregion

                ##################################
                ###* Running Decommission post-scripts
                ##################################
                #region

                Write-Host "Running Decommission post-scripts"

                if ($subscriptionInfo) {
                    if ($subscriptionInfo.State -eq "Enabled") {
                        #* Invoke Post scripts
                        $param = @{
                            Path              = $lzDirectory.FullName
                            ScriptType        = "DecommissionPost"
                            ArchetypePath     = Join-Path $ArchetypesPath -ChildPath $($environment.azure.archetype)
                            LandingZoneConfig = $lzConfig 
                            Environment       = $environmentName
                        }
                        Invoke-LzScripts @param
                    }
                    else {
                        Write-Host "Skipping. Subscription already in disabled state."
                    }
                }
                else {
                    Write-Host "Skipping. Subscription not found."
                }

                #endregion
            }
            catch {
                Write-Warning "Unable to fully deploy Azure environment [$environmentName]: $_."
                $failedDeployments += $environmentName
            }
        }
        else {
            Write-Host "Skipping. Environment and/or repository not marked as decommissioned."
        }
    }
    else {
        Write-Host "Skipping. No Azure environment definition found in Landing Zone config file."
    }

    #endregion
}

#* Reporting
if ($failedDeployments) {
    Write-Error "The following Azure environment decommission processes failed: $($failedDeployments -join ', ')"
} 
else {
    Write-Host "All environment decommission processes completed successfully."
}
