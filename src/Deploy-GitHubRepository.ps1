#Requires -Modules @{ ModuleName="Az.Accounts"; ModuleVersion="3.0.4" }
#Requires -Modules @{ ModuleName="Microsoft.Graph.Authentication"; ModuleVersion="2.24.0" }
#Requires -Modules @{ ModuleName="Microsoft.Graph.Applications"; ModuleVersion="2.24.0" }
#Requires -Modules @{ ModuleName="Microsoft.Graph.Groups"; ModuleVersion="2.24.0" }

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

Write-Debug "Deploy-GitHubRepository.ps1: Started"
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
Write-Debug "[$($lzDirectory.BaseName)] Found ($lzFile.Name) file."

#* Parse climprconfig.json
$climprConfigPath = (Test-Path -Path "$SolutionPath/climprconfig.json") ? "$SolutionPath/climprconfig.json" : "climprconfig.json"
$climprConfig = Get-Content -Path $climprConfigPath | ConvertFrom-Json -AsHashtable -Depth 10 -NoEnumerate

#* Declare climprconfig settings
$defaultRepositoryConfig = $climprConfig.lzManagement.gitWorkloadRepository

#* Parse Landing Zone configuration file
$lzConfig = Get-Content -Path $lzFile.FullName -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 10

#* MSGraph login
$token = Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com"
$secureAccessToken = $token.Token | ConvertTo-SecureString -AsPlainText -Force
Connect-MgGraph -AccessToken $secureAccessToken | Out-Null

#* Declare git variables
$org = $lzConfig.organization
$repo = $lzConfig.repoName
$defaultBranch = $lzConfig.defaultBranch ? $lzConfig.defaultBranch : "main"

#* MARK: Configure GitHub repository
Write-Host "Configure GitHub repository"

if (!$lzConfig.decommissioned) {
    ##################################
    ###* Configure GitHub repository
    ##################################
    #region

    #* Check if the repository already exists
    Write-Host "- Check if the repository already exists '$repo'"
    $repoInfo = gh repo view $org/$repo --json "name,isArchived" | ConvertFrom-Json
    if ($repoInfo) {
        Write-Host "- Found GitHub repository'$repo'"
    }

    if ($repoInfo) {
        if ($repoInfo.isArchived) {
            Write-Host "- Unarchiving repository"
            gh repo unarchive $org/$repo --yes
        }
    }
    else {
        if ($lzConfig.repoTemplate) {
            Write-Host "- Creating repository [$repo] from template [$($lzConfig.repoTemplate)]"
            gh repo create $org/$repo `
                --template $lzConfig.repoTemplate `
                --private `
                --description ($lzConfig.repoDescription ? $lzConfig.repoDescription : 'Automatically created by Climpr.')
        }
        else {
            Write-Host "- Creating blank repository [$repo]"
            gh repo create $org/$repo `
                --add-readme `
                --private `
                --description ($lzConfig.repoDescription ? $lzConfig.repoDescription : 'Automatically created by Climpr.')
        }
    }

    #endregion

    ##################################
    ###* MARK: Configure default team
    ##################################
    #region
    Write-Host "Configure default team"

    $defaultTeamConfig = $defaultRepositoryConfig.defaultTeam

    if ($defaultTeamConfig.enabled) {
        #* Calculate names
        $lzTeamName = $defaultTeamConfig.teamNamePrefix + ($defaultTeamConfig.teamNameIncludeLzName ? $repo : "") + $defaultTeamConfig.teamNameSuffix
        $lzGroupName = $defaultTeamConfig.lzGroupNamePrefix + ($defaultTeamConfig.lzGroupNameIncludeLzName ? $repo : "") + $defaultTeamConfig.lzGroupNameSuffix
        $description = $defaultTeamConfig.descriptionPrefix + ($defaultTeamConfig.descriptionIncludeLzName ? $repo : "") + $defaultTeamConfig.descriptionSuffix
        $lzTeamSlug = $lzTeamName.replace(" ", "-").ToLower()
        
        #* Create Github Team
        try {
            $body = @{
                name        = $lzTeamName
                description = $description
            }

            Invoke-GitHubCliApiMethod -Method "PUT" -Uri "/orgs/$org/teams" -Body ($body | ConvertTo-Json) | Out-Null
            Write-Host "- Created GitHub team [$lzTeamName]." 
        }
        catch {
            Write-Error "Failed to create GitHub team [$lzTeamName]. GitHub Api response: $($_.Exception)" 
        }

        if ($defaultTeamConfig.syncWithEntraId) {
            #* Create Entra Id group
            $group = Get-MgGroup -Filter "DisplayName eq '$lzGroupName.'"

            if (!$group) {
                Write-Host "- [$lzGroupName] not found in Entra Id. Adding..."
                $group = New-MgGroup `
                    -DisplayName $lzGroupName `
                    -MailNickname "NotSet" `
                    -MailEnabled:$false `
                    -SecurityEnabled:$true `
                    -Description $description
        
                Write-Host "- Created $lzGroupName."
            }
            else {
                Write-Host "- Group [$lzGroupName] already exists."
            }

            #TODO: Unsure if this is still required. Needs testing. 
            # #* Grant 'User' role assignment to 'GitHub Application' over AD group
            
            # $entraSyncGroupId = "c3629460-0f4b-4a5d-9da5-6be011f495f5"
            # $entraSyncGroupId = "9c63c4bf-1ed3-4fc1-90b1-37f574d24772"
            # $userRoleAssignmentId = "8d17fe88-c0ca-4903-ae2a-a51098998bc2"

            # $role = Get-MgGroupAppRoleAssignment -GroupId $group.Id | Where-Object { 
            #     $_.ResourceId -eq $entraSyncGroupId -and $_.AppRoleId -eq $userRoleAssignmentId
            # }

            # if (!$role) {
            #     $params = @{                                                            
            #         principalId = $group.Id                                             
            #         resourceId  = $entraSyncGroupId
            #         appRoleId   = $userRoleAssignmentId
            #     }
        
            #     $role = New-MgGroupAppRoleAssignment -GroupId $group.Id -BodyParameter $params
            #     Write-Host "- Role [$($role.AppRoleId)] over [$($role.PrincipalDisplayName)] granted to [$($role.ResourceDisplayName)]"
            # }
            # else {
            #     Write-Host "- Role [$($role.AppRoleId)] over [$($role.PrincipalDisplayName)] was already granted to [$($role.ResourceDisplayName)]"
            # }

            #* Link Github team to AD group
            Write-Host "- Checking if $lzTeamSlug is already associated with its group..."
            $groupMappings = Invoke-GitHubCliApiMethod -Method "GET" -Uri "/orgs/$org/teams/$lzTeamSlug/team-sync/group-mappings" | Select-Object -ExpandProperty "groups"
            $groupIsMapped = $groupMappings | Where-Object { $_.group_name -like $lzGroupName }
            
            if (!$groupIsMapped) {
                #* Get all groups synced from the idp (Entra Id)
                $idpGroups = Invoke-GitHubCliApiMethod -Method "GET" -Uri "/orgs/$org/team-sync/groups" | Select-Object -ExpandProperty "groups"
                $idpGroupInfo = $idpGroups | Where-Object { $_.group_name -like $lzGroupName }
                
                #* Map AD group to Github team
                if ($idpGroupInfo) {
                    try {
                        $body = @{
                            groups = @($idpGroupInfo)
                        }

                        Invoke-GitHubCliApiMethod -Method "PATCH" -Uri "/orgs/$org/teams/$lzTeamSlug/team-sync/group-mappings" -Body ($body | ConvertTo-Json) | Out-Null 
                        Write-Host "- Linked Entra Id group [$lzGroupName] to GitHub team [$lzTeamSlug]." 
                    }
                    catch {
                        Write-Error "Failed to link Entra Id group [$lzGroupName] to GitHub team [$lzTeamSlug]. GitHub Api response: $($_.Exception)" 
                    }
                }
                else {
                    Write-Error "Failed to find Entra Id group [$lzGroupName] in the list of synced groups in GitHub."
                }
            }
        }
    }

    #endregion

    #* MARK: Repository permissions

    Write-Host "Configure repository permissions"

    ##################################
    ###* Calculate desired permissions
    ##################################
    #region
    Write-Host "- Calculate desired permissions"
    
    #* Table for converting GitHub roles to permissions
    $roleToPermissionTable = @{
        "read"     = "pull"
        "triage"   = "triage"
        "write"    = "push"
        "maintain" = "maintain"
        "admin"    = "admin"
    }

    #* Merge desired default permissions and lzconfig permissions
    $accessList = Join-HashTable -Hashtable1 $defaultRepositoryConfig.access -Hashtable2 $lzConfig.access

    #* Add default team assignment
    $defaultTeamConfig = $defaultRepositoryConfig.defaultTeam
    if ($defaultTeamConfig.enabled) {
        $accessList["teams"][$defaultTeamConfig.permission] += $lzTeamSlug
    }
    
    #* Print result
    Write-Host "- Desired access table"
    Write-Host ($accessList | ConvertTo-Json -Depth 2)

    #* Create lists of explicit permissions (permissions granted through climprconfig or lzconfig)
    #* Teams
    $explicitTeamsPermissions = @()
    foreach ($permission in $accessList["teams"].Keys) {
        foreach ($slug in $accessList["teams"][$permission]) {
            $explicitTeamsPermissions += "$slug/$permission"
        }
    }

    #* Collaborators
    $explicitCollaboratorPermissions = @()
    foreach ($permission in $accessList["collaborators"].Keys) {
        foreach ($slug in $accessList["collaborators"][$permission]) {
            $explicitCollaboratorPermissions += "$slug/$permission"
        }
    }

    #* Get current permissions
    $currentTeamsPermissions = @()
    $currentTeams = Invoke-GitHubCliApiMethod -Method "GET" -Uri "/repos/$org/$repo/teams"
    foreach ($team in $currentTeams) {
        $currentTeamsPermissions += "$($team.slug)/$($team.permission)"
    }

    $currentCollaboratorPermissions = @()
    $currentCollaborators = Invoke-GitHubCliApiMethod -Method "GET" -Uri "/repos/$org/$repo/collaborators"
    foreach ($collaborator in $currentCollaborators) {
        $permission = $roleToPermissionTable[$collaborator.role_name]
        $currentCollaboratorPermissions += "$($collaborator.login)/$permission"
    }

    #* Get all organization roles
    $orgRoles = Invoke-GitHubCliApiMethod -Method "GET" -Uri "/orgs/$org/organization-roles" | Where-Object { $_.base_role } | Select-Object -ExpandProperty roles

    #* Create lists of implicit permissions (permissions granted through other mechanisms)
    #* Teams
    $implicitTeamsPermissions = @()

    #* Add Organization role members to the list of desired roles
    foreach ($orgRole in $orgRoles) {
        $orgRoleTeams = Invoke-GitHubCliApiMethod -Method "GET" -Uri "/orgs/$org/organization-roles/$($orgRole.id)/teams"
        foreach ($orgRoleTeam in $orgRoleTeams) {
            $slug = $orgRoleTeam.slug
            $permission = $roleToPermissionTable[$orgRole.base_role]
            $implicitTeamsPermissions += "$slug/$permission"
        }
    }

    #* Collaborators
    $implicitCollaboratorPermissions = @()

    #* Add members from explicit teams permissions
    foreach ($entry in $explicitTeamsPermissions) {
        $teamSlug = $entry.Split("/")[0]
        $permission = $entry.Split("/")[1]
        $members = Invoke-GitHubCliApiMethod -Method "GET" -Uri "/orgs/$org/teams/$teamSlug/members"
        foreach ($member in $members) {
            $implicitCollaboratorPermissions += "$($member.login)/$permission"
        }
    }

    #* Add Organization admins to the list of implicit permissions
    $orgAdmins = Invoke-GitHubCliApiMethod -Method "GET" -Uri "/orgs/$org/members?role=admin"
    foreach ($orgAdmin in $orgAdmins) {
        $slug = $orgAdmin.login
        $permission = $roleToPermissionTable["admin"]
        $implicitCollaboratorPermissions += "$slug/$permission"
    }
    
    #* Add Organization role members to the list of implicit permissions
    foreach ($orgRole in $orgRoles) {
        $orgRoleUsers = Invoke-GitHubCliApiMethod -Method "GET" -Uri "/orgs/$org/organization-roles/$($orgRole.id)/users"
        foreach ($orgRoleUser in $orgRoleUsers) {
            $slug = $orgRoleUser.login
            $permission = $roleToPermissionTable[$orgRole.base_role]
            $implicitCollaboratorPermissions += "$slug/$permission"
        }
    }

    #* Add base role to the list of implicit permissions
    $baseRole = Invoke-GitHubCliApiMethod -Method "GET" -Uri "/orgs/$org"
    $basePermission = $roleToPermissionTable[$baseRole.default_repository_permission]
    foreach ($collaborator in $currentCollaborators) {
        $slug = $collaborator.login
        $implicitCollaboratorPermissions += "$slug/$basePermission"
    }

    #endregion

    ##################################
    ###* Assign team permissions
    ##################################
    #region
    Write-Host "- Assign team permissions"

    #* Assign missing team permissions
    foreach ($entry in $explicitTeamsPermissions) {
        $slug = $entry.Split("/")[0]
        $permission = $entry.Split("/")[1]
        if ($entry -notin $currentTeamsPermissions) {
            try {
                $body = @{
                    permission = $permission
                }

                Invoke-GitHubCliApiMethod -Method "PUT" -Uri "/orgs/$org/teams/$slug/repos/$org/$repo" -Body ($body | ConvertTo-Json) | Out-Null
                Write-Host "  - Assigned [$permission] permission for team [$slug] on repository [$org/$repo]." 
            }
            catch {
                Write-Error "Failed to assign [$permission] permission for team [$slug] on repository [$org/$repo]. GitHub Api response: $($_.Exception)" 
            }
        }
    }

    #endregion

    ##################################
    ###* Assign collaborator permissions
    ##################################
    #region
    Write-Host "- Assign collaborator permissions"

    #* Assign missing collaborator permissions
    foreach ($entry in $explicitCollaboratorPermissions) {
        $slug = $entry.Split("/")[0]
        $permission = $entry.Split("/")[1]
        if ($entry -notin $currentCollaboratorPermissions) {
            try {
                $body = @{
                    permission = $permission
                }

                Invoke-GitHubCliApiMethod  -Method "PUT" -Uri "/repos/$org/$repo/collaborators/$slug" -Body ($body | ConvertTo-Json) | Out-Null
                Write-Host "  - Assigned [$permission] permission for collaborator [$slug] on repository [$org/$repo]." 
            }
            catch {
                Write-Error "Unable to assign [$permission] permission for collaborator [$slug] on repository [$org/$repo]. GitHub Api response: $($_.Exception)" 
            }
        }
    }

    #endregion

    ##################################
    ###* Remove team permissions
    ##################################
    #region
    Write-Host "- Remove team permissions"

    #* Remove invalid teams
    foreach ($entry in $currentTeamsPermissions) {
        $slug = $entry.Split("/")[0]
        $permission = $entry.Split("/")[1]
        if ($entry -notin ($explicitTeamsPermissions + $implicitTeamsPermissions)) {
            try {
                Invoke-GitHubCliApiMethod -Method "DELETE" -Uri "/orgs/$org/teams/$slug/repos/$org/$repo" | Out-Null
                Write-Host "  - Removed [$permission] permission for team [$slug] on repository [$org/$repo]." 
            }
            catch {
                Write-Error "Unable to remove [$permission] permission for team [$slug] on repository [$org/$repo]. GitHub Api response: $($_.Exception)" 
            }
        }
    }

    #endregion

    ##################################
    ###* Remove collaborator permissions
    ##################################
    #region
    Write-Host "- Remove collaborator permissions"
    
    #* Remove invalid collaborators
    foreach ($entry in $currentCollaboratorPermissions) {
        $slug = $entry.Split("/")[0]
        $permission = $entry.Split("/")[1]
        if ($entry -notin ($explicitCollaboratorPermissions + $implicitCollaboratorPermissions)) {
            try {
                Invoke-GitHubCliApiMethod -Method "DELETE" -Uri "/repos/$org/$repo/collaborators/$slug" | Out-Null
                Write-Host "  - Removed [$permission] permission for collaborator [$slug] on repository [$org/$repo]." 
            }
            catch {
                Write-Error "Unable to remove [$permission] permission for collaborator [$slug] on repository [$org/$repo]. GitHub Api response: $($_.Exception)" 
            }
        }
    }

    #endregion

    ##################################
    ###* MARK: Set Repository Configuration
    ##################################
    #region
    Write-Host "Set Repository Configuration"

    $body = @{
        default_branch         = $defaultBranch
        allow_squash_merge     = $true ## default: true
        allow_merge_commit     = $false ## default: true
        allow_rebase_merge     = $false ## default: true
        delete_branch_on_merge = $true ## default: false
        # name                           = ""
        # description                    = ""
        # homepage                       = ""
        # private                        = bool ## default: false
        # visibility                     = ""
        # security_and_analysis          = object or null
        # has_issues                     = $true ## default: true
        # has_discussions                = $true ## default: false
        # has_projects                   = $true ## default: true
        # has_wiki                       = bool ## default: true
        # is_template                    = bool ## default: false
        # allow_auto_merge               = bool ## default: false
        # allow_update_branch            = bool ## default: false
        # use_squash_pr_title_as_default = bool ## default: false
        # squash_merge_commit_title      = oneOf("PR_TITLE", "COMMIT_OR_PR_TITLE")
        # squash_merge_commit_message    = oneOf("PR_BODY", "COMMIT_MESSAGES", "BLANK")
        # merge_commit_title             = oneOf("PR_TITLE", "MERGE_MESSAGE")
        # merge_commit_message           = oneOf("PR_BODY", "PR_TITLE", "BLANK")
        # archived                       = bool ## default: false
        # allow_forking                  = bool ## default: false
        # web_commit_signoff_required    = bool ## default: false
    }

    try {
        Invoke-GitHubCliApiMethod -Method "PATCH" -Uri "/repos/$org/$repo" -Body ($body | ConvertTo-Json) | Out-Null
        Write-Host "GitHub repository settings applied." 
    }
    catch {
        Write-Error "Unable to apply GitHub repository settings. GitHub Api response: $($_.Exception)"
    }

    #endregion

    ##################################
    ###* MARK: Set OIDC Hardening
    ##################################
    #region
    Write-Host "Set OIDC Hardening"

    $body = @{
        use_default        = $false
        include_claim_keys = @(
            "repo"
            "context"
            "ref"
            "workflow"
        )
    }

    try {
        Invoke-GitHubCliApiMethod -Method "PUT" -Uri "/repos/$org/$repo/actions/oidc/customization/sub" -Body ($body | ConvertTo-Json) | Out-Null
        Write-Host "- OIDC hardening applied on repository [$org/$repo]." 
    }
    catch {
        Write-Error "Failed to apply OIDC hardening on repository [$org/$repo]. GitHub Api response: $($_.Exception)" 
    }

    #endregion

    ##################################
    ###* MARK: Set branch protection rule for the default branch
    ##################################
    #region
    Write-Host "Set branch protection rule for the default branch [$defaultBranch]."

    #* Determine configuration source
    $config = $null
    if ($null -ne $lzConfig.branchProtection) {
        Write-Host "- Branch protection rule property determined by Landing Zone configuration file."
        $config = $lzConfig.branchProtection
    }
    elseif ($null -ne $defaultRepositoryConfig.branchProtection) {
        Write-Host "- Branch protection rule property determined by climprconfig file. Property unset in Landing Zone configuration file."
        $config = $defaultRepositoryConfig.branchProtection
    }
    else {
        Write-Host "- Skipping. Branch protection rule property unset or set to 'null' in both Landing Zone configuration file and climprconfig file."
    }

    #* Configure setting
    if ("ignore" -eq $config) {
        Write-Host "- Skipping. Branch protection rule property is 'ignore'."
    }
    elseif ("default" -eq $config) {
        Write-Host "- Branch protection rule property is 'default'. Default settings for GitHub is to not implement any branch protection rules."
        #* Check if there is already a branch protection rule enabled for the default branch
        $currentBranchProtection = Invoke-GitHubCliApiMethod -Method "GET" -Uri "/repos/$org/$repo/branches/$defaultBranch/protection" -ErrorAction Ignore 2>$null
        if ($currentBranchProtection) {
            #* Delete branch protection rule for default branch
            try {
                Invoke-GitHubCliApiMethod -Method "DELETE" -Uri "/repos/$org/$repo/branches/$defaultBranch/protection" | Out-Null
                Write-Host "- Deleted branch protection rule on branch [$defaultBranch] on repository [$org/$repo]." 
            }
            catch {
                Write-Error "Failed to delete branch protection rule on branch [$defaultBranch] on repository [$org/$repo]. GitHub Api response: $($_.Exception)" 
            }
        }
        else {
            Write-Host "- No branch protection rule found for [$defaultBranch] on repository [$org/$repo]." 
        }
    }
    elseif ($null -ne $config) {
        Write-Host "- Branch protection rule property is: $($config | ConvertTo-Json -Depth 10)"
        try {
            Invoke-GitHubCliApiMethod -Method "PUT" -Uri "/repos/$org/$repo/branches/$defaultBranch/protection" -Body ($body | ConvertTo-Json) | Out-Null
            Write-Host "- Branch protection enabled on branch [$defaultBranch] on repository [$org/$repo]." 
        }
        catch {
            Write-Error "Failed to enable branch protection on branch [$defaultBranch] on repository [$org/$repo]. GitHub Api response: $($_.Exception)" 
        }
    }

    #endregion

    ##################################
    ###* MARK: Set CODEOWNERS file
    ##################################
    #region
    Write-Host "Set CODEOWNERS file for default branch [$defaultBranch]"

    #* Determine configuration source
    $config = $null
    if ($null -ne $lzConfig.codeOwners) {
        Write-Host "- CODEOWNERS file property determined by Landing Zone configuration file."
        $config = $lzConfig.codeOwners
    }
    elseif ($null -ne $defaultRepositoryConfig.codeOwners) {
        Write-Host "- CODEOWNERS file property determined by climprconfig file. Property unset in Landing Zone configuration file."
        $config = $defaultRepositoryConfig.codeOwners
    }
    else {
        Write-Host "- Skipping. CODEOWNERS file property unset or set to 'null' in both Landing Zone configuration file and climprconfig file."
    }

    #* Configure setting
    if ("ignore" -eq $config) {
        Write-Host "- Skipping. CODEOWNERS file property is 'ignore'."
    }
    elseif ("default" -eq $config) {
        Write-Host "- CODEOWNERS file property is 'default'. Default settings for GitHub is to not implement any CODEOWNERS file."

        #* Check if CODEOWNERS file already exists in the default branch
        $ghFile = Invoke-GitHubCliApiMethod -Method "GET" -Uri "/repos/$org/$repo/contents/.github/CODEOWNERS" -ErrorAction Ignore 2>$null
        
        #* Delete file
        if ($ghFile) {
            try {
                $body = @{
                    message = "[skip ci] Delete CODEOWNERS file"
                    sha     = $ghFile.sha
                }
                Invoke-GitHubCliApiMethod -Method "DELETE" -Uri "/repos/$org/$repo/contents/.github/CODEOWNERS" -Body ($body | ConvertTo-Json) | Out-Null
            }
            catch {
                Write-Error "Unable to delete CODEOWNERS file on default branch [$defaultBranch]. GitHub Api response: $($_.Exception)"
            }
        }
        else {
            Write-Host "- No CODEOWNERS file found on default branch [$defaultBranch]."
        }
    }
    elseif ($null -ne $config) {
        Write-Host "- CODEOWNERS file is: `"$($config | ConvertTo-Json -Depth 10)`""
        $body = @{}
        $update = $true
    
        #* Get content
        $content = $lzConfig.codeOwners | Out-String
    
        #* Check if CODEOWNERS file already exists
        $ghFile = Invoke-GitHubCliApiMethod -Method "GET" -Uri "/repos/$org/$repo/contents/.github/CODEOWNERS" -ErrorAction Ignore 2>$null
        if ($ghFile) {
            $currentContent = Invoke-RestMethod -Uri $ghFile.download_url
            $body += @{ sha = $ghFile.sha }
            $update = $content -cne $currentContent
        }

        #* Update file
        if ($update) {
            try {
                $body += @{
                    message = "[skip ci] Update CODEOWNERS file"
                    content = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($content))
                }

                Invoke-GitHubCliApiMethod -Method "PUT" -Uri "/repos/$org/$repo/contents/.github/CODEOWNERS" -Body ($body | ConvertTo-Json) | Out-Null
                Write-Host "- CODEOWNERS file created/updated on default branch [$defaultBranch]."
            }
            catch {
                Write-Error "Unable to create/update CODEOWNERS file on default branch [$defaultBranch]. GitHub Api response: $($_.Exception)"
            }
        }
        else {
            Write-Host "- CODEOWNERS file already up to date on default branch [$defaultBranch]."
        }
    }

    #endregion

    ##################################
    ###* MARK: Processing environments
    ##################################
    #region
    Write-Host "Processing environments"

    #* Create Environments
    foreach ($environment in $lzConfig.environments) {
        $environmentName = $environment.name

        if ($environment.decommissioned) {
            Write-Host "[$environmentName] Skipping. Environment decommissioned."
            continue
        }

        ##################################
        ###* MARK: Create environment
        ##################################
        #region
        Write-Host "Create environment with protection rules: $($environmentName)"

        #* Determine configuration source
        $config = $null
        if ($null -ne $environment.runProtection) {
            Write-Host "- Protection rule property determined by Landing Zone configuration file."
            $config = $environment.runProtection
        }
        elseif ($null -ne $defaultRepositoryConfig.runProtection) {
            Write-Host "- Run protection property determined by climprconfig file. Property unset in Landing Zone configuration file."
            $config = $defaultRepositoryConfig.runProtection
        }
        else {
            Write-Host "- Skipping. Run protection property unset or set to 'null' in both Landing Zone configuration file and climprconfig file."
        }

        #* Check if environment exists
        $currentEnvironment = Invoke-GitHubCliApiMethod -Method "GET" -Uri "/repos/$org/$repo/environments/$environmentName" -ErrorAction Ignore 2>$null
        if (!$currentEnvironment -and ($null -eq $config -or $config -eq "ignore")) {
            $config = "default"
            Write-Host "- Environment not found. Creating environment once with default settings."
        }
        
        #* Calculate configuration
        $configure = $false
        if ("ignore" -eq $config ) {
            Write-Host "- Skipping. Run protection property is 'ignore'."
        }
        elseif ("default" -eq $config) {
            $config = @{
                reviewers                = $null
                wait_timer               = 0
                deployment_branch_policy = $null
                prevent_self_review      = $false
            }
            Write-Host "- Run protection property is 'default'. Default settings for GitHub is: $($config | ConvertTo-Json -Depth 10)."
            $configure = $true
        }
        elseif ($null -ne $config) {
            Write-Host "- Run protection property is: $($config | ConvertTo-Json -Depth 10)"
            $configure = $true
        }

        #* Configure setting
        if ($configure) {
            try {
                Invoke-GitHubCliApiMethod -Method "PUT" -Uri "/repos/$org/$repo/environments/$environmentName" -Body ($config | ConvertTo-Json) | Out-Null
                Write-Host "- Run protection settings configured on environment [$environmentName] on repository [$org/$repo]." 
            }
            catch {
                Write-Error "Failed to configure run protection settings on environment [$environmentName] on repository [$org/$repo]. GitHub Api response: $($_.Exception)" 
            }
        }
        
        #* Store config for next step
        $protectionRulesConfig = $config

        #endregion

        ##################################
        ###* MARK: Set environment branch policy patterns
        ##################################
        #region
        Write-Host "Set environment branch policy patterns: $($environmentName)"

        #* Determine configuration source
        $config = $null
        if ($protectionRulesConfig.deployment_branch_policy.custom_branch_policies -ne $true) {
            Write-Host "- Skipping. Branch policy patterns can only be applied when the environment protection rule deployment_branch_policy.custom_branch_policies is set to 'true'."
        }
        elseif ($null -ne $environment.runProtection) {
            Write-Host "- Branch policy patterns property determined by Landing Zone configuration file."
            $config = $environment.runProtection
        }
        elseif ($null -ne $defaultRepositoryConfig.runProtection) {
            Write-Host "- Branch policy patterns property determined by climprconfig file. Property unset in Landing Zone configuration file."
            $config = $defaultRepositoryConfig.runProtection
        }
        else {
            Write-Host "- Skipping. Branch policy patterns property unset or set to 'null' in both Landing Zone configuration file and climprconfig file."
        }

        #* Calculate configuration
        $configure = $false
        switch ($config) {
            $null {}
            "ignore" {
                Write-Host "- Skipping. Branch policy patterns property is 'ignore'."
            }
            "default" {
                Write-Host "- Branch policy patterns property is 'default'. Default settings for GitHub is to not implement any branch policy patterns."
                $config = @()
                $configure = $true
            }
            default {
                Write-Host "- Branch policy patterns property is: $($config | ConvertTo-Json -Depth 10)"
                $configure = $true
            }
        }

        #* Configure setting
        if ($configure) {
            #* Remove patterns not present in the desired configuration
            $currentPatterns = Invoke-GitHubCliApiMethod -Method "GET" -Uri "/repos/$org/$repo/environments/$environmentName/deployment-branch-policies" -ErrorAction Ignore 2>$null
            foreach ($pattern in $currentPatterns.branch_policies) {
                $shallExists = $branchPolicyPatterns | Where-Object { $_.name -eq $pattern.name -and $_.type -eq $pattern.type }
                if (!$shallExists) {
                    try {
                        Invoke-GitHubCliApiMethod -Method "DELETE" -Uri "/repos/$org/$repo/environments/$environmentName/deployment-branch-policies/$($pattern.id)" | Out-Null
                        Write-Host "- [$environmentName] Deleted branch policy pattern [$($pattern.name)]."
                    }
                    catch {
                        Write-Error "Failed to delete branch policy pattern [$($pattern.name)] on environment [$environmentName] on repository [$org/$repo]. GitHub Api response: $($_.Exception)"
                    }
                }
            }

            #* Create or update patterns
            foreach ($pattern in $branchPolicyPatterns) {
                $body = @{
                    name = $pattern.name
                    type = $pattern.type ? $pattern.type : "branch"
                }

                try {
                    Invoke-GitHubCliApiMethod -Method "POST" -Uri "/repos/$org/$repo/environments/$environmentName/deployment-branch-policies" -Body ($body | ConvertTo-Json) | Out-Null
                    Write-Host "- [$environmentName] Created branch policy pattern [$($pattern.name)]." 
                }
                catch {
                    Write-Error "Failed to create branch policy pattern [$($pattern.name)] enabled on environment [$environmentName] on repository [$org/$repo]. GitHub Api response: $($_.Exception)" 
                }
            }
        }

        #endregion
    }

    #endregion
}
else {
    Write-Host "- Skipping. Landing Zone is decommissioned."
}
