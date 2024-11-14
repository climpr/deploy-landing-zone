#Requires -Modules @{ ModuleName="Az.ManagementPartner"; ModuleVersion="0.7.3" }

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]
    $PartnerId = "6100086"
)

#* Check Partner Id
$partner = Get-AzManagementPartner -ErrorAction SilentlyContinue
if (!$partner) {
    Write-Host "Setting PartnerID to [$partnerId]"
    $partner = New-AzManagementPartner -PartnerId $partnerId -ErrorAction Continue
}
elseif ($partner.PartnerId -ne $partnerId) {
    Write-Host "Updating PartnerID to [$partnerId]"
    $partner = Update-AzManagementPartner -PartnerId $partnerId -ErrorAction Continue
}
else {
    Write-Host "Partner [$($partner.PartnerName)][$partnerId]"
}
