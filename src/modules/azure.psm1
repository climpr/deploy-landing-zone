function New-BillingScope {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]
        $BillingAccountDisplayName,

        [Parameter(Mandatory = $true)]
        [string]
        $BillingProfileDisplayName,

        [Parameter(Mandatory = $true)]
        [string]
        $InvoiceSectionDisplayName
    )

    Write-Host "- Getting billing account: $BillingAccountDisplayName"
    $billingAccount = Get-AzBillingAccount -IncludeAddress -ExpandBillingProfile -ExpandInvoiceSection -ErrorAction Stop | `
        Where-Object { $_.DisplayName -eq $BillingAccountDisplayName }
    
    if (!$billingAccount) {
        throw "Billing account with display name [$BillingAccountDisplayName] not found"
    }


    Write-Host "- Getting billing profile: $BillingProfileDisplayName"
    $billingProfile = $billingAccount.BillingProfiles | Where-Object { $_.DisplayName -eq $BillingProfileDisplayName } | Select-Object -First 1
    if (!$billingProfile) {
        Write-Host "- Billing profile not found. Creating new billing profile: $BillingProfileDisplayName"
        $uri = "https://management.azure.com$($billingAccount.Id)/billingProfiles/$($BillingProfileDisplayName)?api-version=2020-05-01"
        $body = @{
            properties = @{
                billTo      = $billingAccount.SoldTo
                displayName = $BillingProfileDisplayName
            }
        } | ConvertTo-Json
        $null = Invoke-AzRestMethod -Method PUT -Uri $uri -Payload $body

        #* Get newly created invoice section
        for ($i = 0; $i -lt 10; $i++) {
            Start-Sleep -Seconds 2
            $billingProfile = Get-AzBillingProfile -BillingAccountName $billingAccount.Name -Name $BillingProfileDisplayName -ExpandInvoiceSection -ErrorAction Ignore
            if ($invoiceSection) {
                break
            }
        }
    }

    Write-Host "- Getting invoice section: $InvoiceSectionDisplayName"
    $invoiceSection = $billingProfile.InvoiceSections | Where-Object { $_.DisplayName -eq $InvoiceSectionDisplayName } | Select-Object -First 1
    if (!$invoiceSection) {
        Write-Host "- Invoice section not found. Creating new invoice section: $InvoiceSectionDisplayName"
        $uri = "https://management.azure.com$($billingProfile.Id)/invoiceSections/$($InvoiceSectionDisplayName)?api-version=2020-05-01"
        $body = @{
            properties = @{
                displayName = $InvoiceSectionDisplayName
            }
        } | ConvertTo-Json
        $null = Invoke-AzRestMethod -Method PUT -Uri $uri -Payload $body

        #* Get newly created invoice section
        for ($i = 0; $i -lt 10; $i++) {
            Start-Sleep -Seconds 2
            $invoiceSection = Get-AzInvoiceSection -BillingAccountName $billingAccount.Name -BillingProfileName $billingProfile.Name -Name $InvoiceSectionDisplayName -ErrorAction Ignore
            if ($invoiceSection) {
                break
            }
        }
    }

    #* Return billing scope
    $invoiceSection.Id
}

function New-LzSubscription {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]
        $AliasName,

        [Parameter(Mandatory = $true)]
        [string]
        $SubscriptionName,

        [Parameter(Mandatory = $true)]
        [ValidateSet("Production", "DevTest")]
        [string]
        $Offer,

        [Parameter(Mandatory = $false)]
        [string]
        $BillingScope,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]
        $SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]
        $ManagementGroupId
    )

    #* Enable subscription
    if ($SubscriptionId) {
        Enable-LzSubscription -SubscriptionId $SubscriptionId

        #* Onboard existing if needed
        Write-Host "- Onboarding existing subscription reference"
        try {
            $subAlias = New-AzSubscriptionAlias -AliasName $AliasName -SubscriptionId $SubscriptionId
        }
        catch {
            Write-Warning -Message "Failed to create Subscription Alias resource, assuming it already exists. [$($_.ToString())]"
        }

        #* Ensure subscription is under correct Management Group
        Write-Host "- Set subscription parent management group Id [$ManagementGroupId]"
        $null = New-AzManagementGroupSubscription -GroupId $ManagementGroupId -SubscriptionId $SubscriptionId

        if ($BillingScope) {
            #* Check if subscription is associated with the Billing Account
            #* If not, it cannot be moved to the correct billing scope
            $billingAccountId = $BillingScope.Split("/")[0..4] -join "/"
            $billingSubscriptions = @()
            $nextLink = "$($billingAccountId)/billingSubscriptions?api-version=2024-04-01&top=50"
            do {
                $response = Invoke-AzRestMethod "https://management.azure.com$($nextLink)"
                if ($response.StatusCode -notin 200..299) {
                    Write-Host ($response | Out-String)
                    throw "Failed to get list of current Billing Account subscriptions. Status code: {0}. Error: {1}" -f $response.StatusCode, $response.Content
                }
                $content = $response.Content | ConvertFrom-Json
                $nextLink = $content.nextLink
                foreach ($billingSubscription in $content.value) {
                    $billingSubscriptions += $billingSubscription
                }
            } while ($nextLink)

            if ($billingSubscriptions.properties.subscriptionId -notcontains $SubscriptionId) {
                throw "Subscription either doesn't exist or is not associated with the correct Billing Account. The subscription must exist and be associated with the Billing Account as a 'Billing Subscription'."
            }
            
            #* Ensure subscription has correct invoice section, as long as billingScope is not an Enterprise Agreement (EA) account
            if ($BillingScope -notlike "*/enrollmentAccounts/*") {
                Write-Host "- Set subscription billing invoice section (Only for MCA)"
                $uri = "https://management.azure.com$($billingAccountId)/billingSubscriptions/$($SubscriptionId)/move?api-version=2021-10-01"
                $body = @{ destinationInvoiceSectionId = $BillingScope } | ConvertTo-Json
                $response = Invoke-AzRestMethod -Uri $uri -Method POST -Payload $body
                if ($response.StatusCode -notin 200..299) {
                    Write-Host ($response | Out-String)
                    throw "Failed to move subscription to invoice section. Status code: {0}. Error: {1}" -f $response.StatusCode, $response.Content
                }
            }
        }

        $subId = $SubscriptionId
    }
    else {
        #* Run new alias deployment
        Write-Host "- Running Subscription Alias deployment"
        $param = @{
            AliasName         = $AliasName
            DisplayName       = $SubscriptionName
            ManagementGroupId = "/providers/Microsoft.Management/managementGroups/$ManagementGroupId"
            Workload          = $Offer
        }
        if ($BillingScope) {
            $param.Add("BillingScope", ($BillingScope -replace "^/providers/Microsoft\.Billing"))
        }
        $subAlias = New-AzSubscriptionAlias @param

        $subId = $subAlias.SubscriptionId
    }

    Write-Host "- LZ Subscription created/updated!"

    #* Rename subscription display name if needed. This is not always working when using the subscription-alias deployment
    Rename-LzSubscription -SubscriptionName $SubscriptionName -SubscriptionId $subId

    #* Enable resource providers for subscription
    # Enable-LzResourceProviders -SubscriptionId $subId #* This is supposedly automatic in ARM/Bicep now

    return $subId
}

function Enable-LzSubscription {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]
        $SubscriptionId
    )

    $sub = Get-AzSubscription -SubscriptionId $SubscriptionId -ErrorAction SilentlyContinue
    if ($sub) {
        switch ($sub.State) {
            Enabled {
                Write-Host "Subscription [$SubscriptionId] in enabled state"
            }
            Default {
                Write-Warning "Subscription [$SubscriptionId] in [$($sub.State)] state, trying to enable it"
                $null = Enable-AzSubscription -Id $SubscriptionId -Confirm:$false
                do {
                    Write-Host "Waiting for subscription [$SubscriptionId] to be enabled"
                    $sub = Get-AzSubscription -SubscriptionId $SubscriptionId -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 20
                } while ($sub.State -ne "Enabled")

                #TODO: Azure seems to have multiple state files and they don't all update immediately which means that even though this part is completed and the sub is enabled, the next part may fail because the state it depends on hasn't updated yet. Maybe we should add some extra logic here?
            }
        }
    }
}

function Rename-LzSubscription {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        $SubscriptionName,
        
        [Parameter(Mandatory = $true)]
        $SubscriptionId
    )
    $sub = Get-AzSubscription -SubscriptionId $SubscriptionId -ErrorAction SilentlyContinue
    if ($sub) {
        #* Check sub name
        if ($sub.Name -eq $SubscriptionName) {
            Write-Host "- Subscription name for [$($sub.Id)] is already correct: [$($SubscriptionName)]"
        }
        else {
            Write-Host "- Renaming sub [$($sub.Id)] to [$($SubscriptionName)]"
            $null = Rename-AzSubscription -Id $sub.Id -SubscriptionName $SubscriptionName
            $sub.Name = $SubscriptionName
        }
    }
    else {
        throw "LZ Subscription [$SubscriptionId] not found"
    }
}

function Invoke-LzScripts {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]
        $Path,

        [Parameter(Mandatory)]
        [ValidateSet("Pre", "Post", "DecommissionPre", "DecommissionPost")]
        [string]
        $ScriptType,

        [Parameter(Mandatory)]
        [string]
        $ArchetypePath,

        [Parameter(Mandatory)]
        [hashtable]
        $LandingZoneConfig,

        [Parameter(Mandatory)]
        [string]
        $Environment,

        [Parameter(Mandatory = $false)]
        [hashtable]
        $DeploymentOutputs
    )

    $nErrors = 0

    $scriptDirs = @{
        Pre              = "pre-scripts"
        Post             = "post-scripts"
        DecommissionPre  = "decommission-pre-scripts"
        DecommissionPost = "decommission-post-scripts"
    }
    $scriptsDirName = $scriptDirs[$ScriptType]

    $scriptsPath = "$ArchetypePath/$scriptsDirName"

    $scripts = Get-ChildItem $scriptsPath -Filter "*.ps1" -ErrorAction Ignore

    Write-Host "- Processing $ScriptType scripts"
    #* Running scripts
    if ($scripts) {
        $defaultScriptParams = @{
            Path               = $Path
            LandingZoneConfig  = $LandingZoneConfig
            EnvironmentContent = $LandingZoneConfig.environments | Where-Object { $_.name -eq $Environment }
        }

        foreach ($script in $scripts) {
            $scriptRelativePath = Resolve-Path -Path $script.FullName -Relative
            Write-Host "----------------------------------------"
            Write-Host ">> Running script [$scriptRelativePath]"
            try {
                if ($ScriptType -in @("Pre", "DecommissionPre", "DecommissionPost")) {
                    & $script.FullName @defaultScriptParams 
                }
                elseif ($ScriptType -eq "Post") {
                    $outputs = $DeploymentOutputs | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
                    & $script.FullName @defaultScriptParams -DeploymentOutputs $outputs
                }
            }
            catch {
                Write-Warning "Error running script [$scriptRelativePath]`n$($_.Exception.Message)"
                $nErrors++
            }
            Write-Host ">> Successfully ran script [$scriptRelativePath]"
        }

        Write-Host "----------------------------------------"
    }
    else {
        Write-Host "- No $ScriptType scripts found"
    }

    if ($nErrors) {
        throw "$nErrors errors found during deployment!"
    }
}

function Enable-LzResourceProviders {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        $SubscriptionId
    )

    $sub = Get-AzSubscription -SubscriptionId $SubscriptionId -ErrorAction SilentlyContinue
    if ($sub) {
        #* Enable all resource providers
        $null = Set-AzContext -SubscriptionId $sub.Id
        Get-AzResourceProvider -ListAvailable | ForEach-Object -Parallel {
            $resourceProvider = $_
            if ($resourceProvider.RegistrationState -ne "Registered") {
                $null = Register-AzResourceProvider `
                    -ProviderNamespace $resourceProvider.ProviderNamespace `
                    -ErrorAction SilentlyContinue `
                    -WarningAction SilentlyContinue
                if (!$?) {
                    Write-Warning "xxx Failed to register [$($resourceProvider.ProviderNamespace)]!"
                }
                else {
                    Write-Verbose "+++ Successfully registered [$($resourceProvider.ProviderNamespace)]!"
                }
            }
        } -ThrottleLimit 20
    }
}

function New-LzDeployment {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $SubscriptionId,

        [Parameter(Mandatory)]
        [string]
        $Path,

        [Parameter(Mandatory)]
        [ValidateScript({ $_ | Test-Path -PathType Container })]
        [string]
        $ArchetypePath,

        [Parameter(Mandatory = $false)]
        [string]
        $ParameterFile,

        [Parameter(Mandatory)]
        [string]
        $Location,

        [Parameter(Mandatory)]
        [hashtable]
        $LandingZoneConfig,

        [Parameter(Mandatory)]
        [string]
        $Environment
    )

    #* Defaults
    $lzName = "$($LandingZoneConfig.repoName)-$($Environment)"

    #* Invoke Pre scripts
    $param = @{
        Path              = $Path
        ScriptType        = "Pre"
        ArchetypePath     = $ArchetypePath
        LandingZoneConfig = $LandingZoneConfig
        Environment       = $Environment
    }
    Invoke-LzScripts @param

    #* Run deployment
    $param = @{
        Name                  = $lzName
        Location              = $Location
        TemplateFile          = "$ArchetypePath/main.bicep"
        TemplateParameterFile = $ParameterFile
        WarningAction         = "SilentlyContinue"
        ErrorAction           = "Continue"
        Verbose               = $true
    }

    Write-Host "- Deploying resources for [$lzName]"
    $azContext = Get-AzContext
    if ($azContext.Subscription.Id -ne $SubscriptionId) {
        $azContext = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
    }
    $ret = New-AzSubscriptionDeployment @param
    if (!$ret -or $ret.ProvisioningState -ne "Succeeded") {
        throw "Failed to deploy resources for [$lzName]"
    }
    Write-Host "LZ [$lzName] base resources deployment $($ret.ProvisioningState)!"

    if ($ret.Outputs) {
        Write-Host "Produced outputs:"
        Write-Host $ret.OutputsString
        Write-Host "-----------------------------------"
    }

    #* Return outputs
    $ret.Outputs

    #* Invoke Post scripts
    $param = @{
        Path              = $Path
        ScriptType        = "Post"
        ArchetypePath     = $ArchetypePath
        LandingZoneConfig = $LandingZoneConfig
        Environment       = $Environment 
        DeploymentOutputs = $ret.Outputs
    }
    Invoke-LzScripts @param
}
