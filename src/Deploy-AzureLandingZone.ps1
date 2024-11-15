#Requires -Modules @{ ModuleName="Az.Accounts"; ModuleVersion="3.0.4" }
#Requires -Modules @{ ModuleName="Az.Billing"; ModuleVersion="2.0.3" }
#Requires -Modules @{ ModuleName="Az.Resources"; ModuleVersion="6.16.1" }
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

Write-Debug "Deploy-AzureLandingZone.ps1: Started"
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
$defaultLocation = $climprConfig.lzManagement.defaultLocation
$defaultBillingAccountDisplayName = $climprConfig.lzManagement.billingAccountDisplayName

#* Parse Landing Zone configuration file
$lzConfig = Get-Content -Path $lzFile.FullName -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 10
$lzConfigPSObject = Get-Content -Path $lzFile.FullName -Encoding utf8 | ConvertFrom-Json -Depth 10

#* Declare git variables
$org = $lzConfig.organization
$repo = $lzConfig.repoName

if (!$lzConfig.decommissioned) {
    ##################################
    ###* Processing environments
    ##################################
    #region
    Write-Host "Processing environments"

    #* Create Environments
    foreach ($environment in $lzConfig.environments) {
        $environmentName = $environment.name

        Write-Host "Processing environment: $($environmentName)"
        
        if (!$environment.decommissioned) {
            #* Process Azure subscription
            if ($environment.azure) {
                try {

                    ##################################
                    ###* Create Billing Scope
                    ##################################
                    #region
                    Write-Host "Create Billing Scope: $($environmentName)"

                    if ($environment.azure.archetype -ne "no-lz") {
                        #* Create Billing Scope (Billing Profile and Invoice Section)
                        $param = @{
                            BillingAccountDisplayName = $environment.azure.billingAccountDisplayName ? $environment.azure.billingAccountDisplayName : $defaultBillingAccountDisplayName
                            BillingProfileDisplayName = $environment.azure.billingProfileDisplayName
                            InvoiceSectionDisplayName = $environment.azure.invoiceSectionDisplayName
                        }
                        $billingScope = New-BillingScope @param

                        $param = @{
                            AliasName         = "$($lzConfig.repoName)-$($environment.name)".ToLower()
                            SubscriptionId    = $environment.azure.subscriptionId
                            SubscriptionName  = $environment.azure.subscriptionName
                            Offer             = (![string]::IsNullOrEmpty($environment.azure.offer) ? $environment.azure.offer : 'Production')
                            BillingScope      = $billingScope
                            ManagementGroupId = $environment.azure.parentManagementGroupId
                        }

                        #* Create new subscription
                        $subId = New-LzSubscription @param

                        #* Update Landing Zone config objects with subscription Id
                        $environment.azure.subscriptionId = $subId
                        $environmentPSObject = $lzConfigPSObject.environments | Where-Object { $_.name -eq $environmentName }
                        if ($environmentPSObject.azure.subscriptionId -ne $subId) {
                            $environmentPSObject.azure | Add-Member -MemberType NoteProperty -Name "subscriptionId" -Value $subId -Force
                        }
                    }

                    #endregion

                    ##################################
                    ###* Deploy archetype
                    ##################################
                    #region
                    Write-Host "Deploy archetype: $($environmentName)"

                    $lzDirectoryRelativePath = Resolve-Path -Relative $lzFile.Directory.FullName

                    $param = @{
                        Location          = $defaultLocation
                        ArchetypePath     = Join-Path $ArchetypesPath -ChildPath $($environment.azure.archetype)
                        ParameterFile     = Join-Path -Path $lzDirectoryRelativePath -ChildPath "$($environment.name).bicepparam"
                        Path              = $lzDirectoryRelativePath
                        LandingZoneConfig = $lzConfig
                        Environment       = $environmentName
                        SubscriptionId    = $environment.azure.archetype -eq "no-lz" ? $environment.azure.deploymentSubscriptionId : $subId
                    }
            
                    $lzDeployment = New-LzDeployment @param

                    #endregion

                    ##################################
                    ###* Push GitHub variables
                    ##################################
                    #region
                    Write-Host "Push GitHub variables: $($environmentName)"

                    #* Variables to push
                    $outputVars = @{
                        TENANT_ID       = $lzDeployment.tenantId
                        SUBSCRIPTION_ID = $lzDeployment.subscriptionId
                        APP_ID          = $lzDeployment.applicationId
                    }

                    foreach ($name in $outputVars.Keys) {
                        if ($outputVars[$name]) {
                            gh variable set $name `
                                --repo $org/$repo `
                                --body "$($outputVars[$name].Value)" `
                                --env $environmentName
                            Write-Host "Updated repository environment [$environmentName] variable [$name]"
                        }
                    }

                    #endregion
                }
                catch {
                    Write-Warning "Unable to fully deploy Azure environment [$environmentName]: $_."
                    $failedDeployments += $environmentName
                }
            }

        }
        else {
            Write-Host "Skipping. Environment is decommissioned."
        }
    }
    #endregion

    ##################################
    ###* Reporting
    ##################################
    #region
    Write-Host "Reporting"

    if ($failedDeployments) {
        Write-Error "The following Azure environment deployments failed: $($failedDeployments -join ', ')"
    } 
    else {
        Write-Host "All deployments completed successfully."
    }

    #endregion

    ##################################
    ###* Push local Landing Zone config changes
    ##################################
    #region
    Write-host "Push local Landing Zone config changes."

    $lzConfigPSObject | ConvertTo-Json -Depth 10 | Out-File $lzFile.FullName -NoNewline
    $lzFileChanged = [bool](git diff --name-only $lzFile.FullName)
    if ($lzFileChanged) {
        git add $lzFile.FullName
        git pull -q
        git stash save --keep-index --include-untracked | Out-Null
        git commit -m "[skip ci] Update ($lzFile.Name) file"
        git push -q
    }
    else {
        Write-Host "Skipping. $($lzFile.Name) file up to date in repository."
    }

    #endregion
}
else {
    Write-Host "Skipping. Landing Zone is decommissioned."
}
