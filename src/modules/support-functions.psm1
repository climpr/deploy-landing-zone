function Invoke-GitHubCliApiMethod {
    [CmdletBinding()]
    param (
        [string]
        $Uri,

        [string]
        $Method,

        [string]
        $Body
    )
    
    if ($Method -eq "GET") {
        $response = gh api $Uri `
            --method $Method `
            --header "Accept: application/vnd.github+json" `
            --header "X-GitHub-Api-Version: 2022-11-28" `
            --paginate `
            --slurp
    }
    else {
        $response = $Body | gh api $Uri `
            --method $Method `
            --header "Accept: application/vnd.github+json" `
            --header "X-GitHub-Api-Version: 2022-11-28" `
            --input -
    }
    
    if ($?) {
        return ($response | ConvertFrom-Json)
    }
    else {
        throw ($response | ConvertFrom-Json)
    }
}

function Join-HashTable {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [hashtable]
        $Hashtable1 = @{},
        
        [Parameter(Mandatory = $false)]
        [hashtable]
        $Hashtable2 = @{}
    )

    #* Null handling
    $Hashtable1 = $Hashtable1.Keys.Count -eq 0 ? @{} : $Hashtable1
    $Hashtable2 = $Hashtable2.Keys.Count -eq 0 ? @{} : $Hashtable2

    #* Needed for nested enumeration
    $hashtable1Clone = $Hashtable1.Clone()
    
    foreach ($key in $hashtable1Clone.Keys) {
        if ($key -in $hashtable2.Keys) {
            if ($hashtable1Clone[$key] -is [hashtable] -and $hashtable2[$key] -is [hashtable]) {
                $Hashtable2[$key] = Join-HashTable -Hashtable1 $hashtable1Clone[$key] -Hashtable2 $Hashtable2[$key]
            }
            elseif ($hashtable1Clone[$key] -is [array] -and $hashtable2[$key] -is [array]) {
                foreach ($item in $hashtable1Clone[$key]) {
                    if ($hashtable2[$key] -notcontains $item) {
                        $hashtable2[$key] += $item
                    }
                }
            }
        }
        else {
            $Hashtable2[$key] = $hashtable1Clone[$key]
        }
    }
    
    return $Hashtable2
}

function Join-Arrays {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [array]
        $Array1 = @(),
        
        [Parameter(Mandatory = $false)]
        [array]
        $Array2 = @()
    )

    foreach ($item in $Array1) {
        if ($Array2 -notcontains $item) {
            $Array2 += $item
        }
    }

    $Array2
}
