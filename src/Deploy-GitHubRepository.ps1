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

#* Find existing Git repository if any
$repoInfo = gh repo view $org/$repo --json "name,isArchived" | ConvertFrom-Json
if ($repoInfo) {
    Write-Host "Found GitHub repo '$repo'"
}

#* Process creation
if (!$lzConfig.decommissioned) {
    ##################################
    ###* Process Git Repo
    ##################################
    #region
    Write-Host "Process Git Repo"

    if ($repoInfo) {
        if ($repoInfo.isArchived) {
            Write-Host "Unarchiving repository"
            gh repo unarchive $org/$repo --yes
        }
    }
    else {
        if ($lzConfig.repoTemplate) {
            Write-Host "Creating repo [$repo] from template [$($lzConfig.repoTemplate)]"
            gh repo create $org/$repo `
                --template $lzConfig.repoTemplate `
                --private `
                --description ($lzConfig.repoDescription ? $lzConfig.repoDescription : 'Automatically created by Climpr.')
        }
        else {
            Write-Host "Creating blank repo [$repo]"
            gh repo create $org/$repo `
                --add-readme `
                --private `
                --description ($lzConfig.repoDescription ? $lzConfig.repoDescription : 'Automatically created by Climpr.')
        }
    }

    #endregion

    ##################################
    ###* Create default team
    ##################################
    #region
    Write-Host "Create default team"

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
            Write-Host "Created GitHub team [$lzTeamName]." 
        }
        catch {
            Write-Error "Failed to create GitHub team [$lzTeamName]. GitHub Api response: $($_.Exception)" 
        }

        if ($defaultTeamConfig.syncWithEntraId) {
            #* Create Entra Id group
            $group = Get-MgGroup -Filter "DisplayName eq '$lzGroupName.'"

            if (!$group) {
                Write-Host "[$lzGroupName] not found in Entra Id. Adding..."
                $group = New-MgGroup `
                    -DisplayName $lzGroupName `
                    -MailNickname "NotSet" `
                    -MailEnabled:$false `
                    -SecurityEnabled:$true `
                    -Description $description
        
                Write-Host "Created $lzGroupName."
            }
            else {
                Write-Host "Group [$lzGroupName] already exists."
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
            #     Write-Host "Role [$($role.AppRoleId)] over [$($role.PrincipalDisplayName)] granted to [$($role.ResourceDisplayName)]"
            # }
            # else {
            #     Write-Host "Role [$($role.AppRoleId)] over [$($role.PrincipalDisplayName)] was already granted to [$($role.ResourceDisplayName)]"
            # }

            #* Link Github team to AD group
            Write-Host "Checking if $lzTeamSlug is already associated with its group..."
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
                        Write-Host "Linked Entra Id group [$lzGroupName] to GitHub team [$lzTeamSlug]." 
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

    ##################################
    ###* Calculate permissions
    ##################################
    #region
    Write-Host "Calculate permissions"
    
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
    Write-Host "Desired access table"
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
    Write-Host "Assign team permissions"

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
                Write-Host "Assigned [$permission] permission for team [$slug] on repository [$org/$repo]." 
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
    Write-Host "Assign collaborator permissions"

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
                Write-Host "Assigned [$permission] permission for collaborator [$slug] on repository [$org/$repo]." 
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
    Write-Host "Remove team permissions"

    #* Remove invalid teams
    foreach ($entry in $currentTeamsPermissions) {
        $slug = $entry.Split("/")[0]
        $permission = $entry.Split("/")[1]
        if ($entry -notin ($explicitTeamsPermissions + $implicitTeamsPermissions)) {
            try {
                Invoke-GitHubCliApiMethod -Method "DELETE" -Uri "/orgs/$org/teams/$slug/repos/$org/$repo" | Out-Null
                Write-Host "Removed [$permission] permission for team [$slug] on repository [$org/$repo]." 
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
    Write-Host "Remove collaborator permissions"
    
    #* Remove invalid collaborators
    foreach ($entry in $currentCollaboratorPermissions) {
        $slug = $entry.Split("/")[0]
        $permission = $entry.Split("/")[1]
        if ($entry -notin ($explicitCollaboratorPermissions + $implicitCollaboratorPermissions)) {
            try {
                Invoke-GitHubCliApiMethod -Method "DELETE" -Uri "/repos/$org/$repo/collaborators/$slug" | Out-Null
                Write-Host "Removed [$permission] permission for collaborator [$slug] on repository [$org/$repo]." 
            }
            catch {
                Write-Error "Unable to remove [$permission] permission for collaborator [$slug] on repository [$org/$repo]. GitHub Api response: $($_.Exception)" 
            }
        }
    }

    #endregion

    ##################################
    ###* Set Repo Configuration
    ##################################
    #region
    Write-Host "Set Repo Configuration"

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
    ###* Set OIDC Hardening
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
        Write-Host "OIDC hardening applied on repository [$org/$repo]." 
    }
    catch {
        Write-Error "Failed to apply OIDC hardening on repository [$org/$repo]. GitHub Api response: $($_.Exception)" 
    }

    #endregion

    ##################################
    ###* Set Branch Protection
    ##################################
    #region
    Write-Host "Set Branch Protection"

    #* Get default branchProtection configuration
    $branchProtection = $defaultRepositoryConfig.branchProtection
    $body = Join-HashTable -Hashtable1 $branchProtection -Hashtable2 $lzConfig.branchProtection

    if ($body -and $body.Count -eq 0) {
        #* No branch protection settings specified in the Landing Zone configuration file
        Write-Host "No branch protection setting specified for the default branch in the Landing Zone configuration file." 

        #* Check if there is already a branch protection rule enabled for the default branch
        $currentBranchProtection = Invoke-GitHubCliApiMethod -Method "GET" -Uri "/repos/$org/$repo/branches/$defaultBranch/protection" -ErrorAction Ignore 2>$null
        if ($currentBranchProtection) {
            #* Delete branch protection rule for default branch
            try {
                Invoke-GitHubCliApiMethod -Method "DELETE" -Uri "/repos/$org/$repo/branches/$defaultBranch/protection" | Out-Null
                Write-Host "Deleted branch protection rule on branch [$defaultBranch] on repository [$org/$repo]." 
            }
            catch {
                Write-Error "Failed to delete branch protection rule on branch [$defaultBranch] on repository [$org/$repo]. GitHub Api response: $($_.Exception)" 
            }
        }
        else {
            Write-Host "No branch protection rule found for [$defaultBranch] on repository [$org/$repo]." 
        }
    }
    else {
        #* Enable branch protection rule for default branch
        try {
            Invoke-GitHubCliApiMethod -Method "PUT" -Uri "/repos/$org/$repo/branches/$defaultBranch/protection" -Body ($body | ConvertTo-Json) | Out-Null
            Write-Host "Branch protection enabled on branch [$defaultBranch] on repository [$org/$repo]." 
        }
        catch {
            Write-Error "Failed to enable branch protection on branch [$defaultBranch] on repository [$org/$repo]. GitHub Api response: $($_.Exception)" 
        }
    }

    #endregion

    ##################################
    ###* Update CODEOWNERS file
    ##################################
    #region
    Write-Host "Update Code Owners file"

    if ($lzConfig.codeOwners) {
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
                Write-Host "[$defaultBranch] CODEOWNERS file created/updated."
            }
            catch {
                Write-Error "[$defaultBranch] Unable to create/update CODEOWNERS file. GitHub Api response: $($_.Exception)"
            }
        }
        else {
            Write-Host "[$defaultBranch] CODEOWNERS file already up to date."
        }
    }

    #endregion

    ##################################
    ###* Processing environments
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
        ###* Create environment
        ##################################
        #region
        Write-Host "Create environment: $($environmentName)"

        #* Get default runProtection configuration
        $githubDefaults = @{
            reviewers                = $null
            wait_timer               = 0
            deployment_branch_policy = $null
            prevent_self_review      = $false
        }
        $runProtection = Join-HashTable -Hashtable1 $githubDefaults -Hashtable2 $defaultRepositoryConfig.runProtection
        $body = Join-HashTable -Hashtable1 $runProtection -Hashtable2 $environment.runProtection

        try {
            Invoke-GitHubCliApiMethod -Method "PUT" -Uri "/repos/$org/$repo/environments/$environmentName" -Body ($body | ConvertTo-Json) | Out-Null
            Write-Host "Run protection settings configured on environment [$environmentName] on repository [$org/$repo]." 
        }
        catch {
            Write-Error "Failed to configure run protection settings on environment [$environmentName] on repository [$org/$repo]. GitHub Api response: $($_.Exception)" 
        }

        #endregion

        ##################################
        ###* Create environment branch policy patterns
        ##################################
        #region
        Write-Host "Create environment branch policy patterns: $($environmentName)"

        #* Get default branchPolicyPatterns configuration
        $branchPolicyPatterns = $defaultRepositoryConfig.branchPolicyPatterns
        $branchPolicyPatterns = Join-Arrays -Array1 $branchPolicyPatterns -Array2 $environment.branchPolicyPatterns

        #* Remove patterns not present in Landing Zone config file
        $currentPatterns = Invoke-GitHubCliApiMethod -Method "GET" -Uri "/repos/$org/$repo/environments/$environmentName/deployment-branch-policies"
        foreach ($pattern in $currentPatterns.branch_policies) {
            $shallExists = $branchPolicyPatterns | Where-Object { $_.name -eq $pattern.name -and $_.type -eq $pattern.type }
            if (!$shallExists) {
                try {
                    Invoke-GitHubCliApiMethod -Method "DELETE" -Uri "/repos/$org/$repo/environments/$environmentName/deployment-branch-policies/$($pattern.id)" | Out-Null
                    Write-Host "[$environmentName] environment branch policy pattern [$($pattern.name)] deleted."
                }
                catch {
                    Write-Error "Failed to delete [$environmentName] environment branch policy pattern [$($pattern.name)]."
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
                Write-Host "Environment branch policy pattern [$($pattern.name)] enabled on environment [$environmentName] on repository [$org/$repo]." 
            }
            catch {
                Write-Error "Failed to enable environment branch policy pattern [$($pattern.name)] enabled on environment [$environmentName] on repository [$org/$repo]. GitHub Api response: $($_.Exception)" 
            }
        }

        #endregion
    }

    #endregion
}
else {
    Write-Host "Skipping. Landing Zone is decommissioned."
}
