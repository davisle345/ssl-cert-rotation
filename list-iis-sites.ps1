<#
.SYNOPSIS
    Lists IIS sites and their running state. Handy before/after a cert rotation.
#>

Import-Module WebAdministration

# All sites with their current state
Get-Website | ForEach-Object {
    "{0,-40} {1}" -f $_.Name, $_.State
}

Write-Host ""
$sites = Get-Website | Where-Object { $_.Name -ne "Default Web Site" }
Write-Host ("Total sites (excluding Default Web Site): {0}" -f $sites.Count) -ForegroundColor Cyan
