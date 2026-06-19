[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [string]$ClientId,

    [Parameter(Mandatory = $false)]
    [string]$ClientSecret = $env:EDISCOVERY_CLIENT_SECRET,

    [Parameter(Mandatory = $false)]
    [string]$PurviewScope = 'b26e684c-5068-4120-a679-64a5d2c909d9/.default',

    [Parameter(Mandatory = $false)]
    [string]$ExpectedAudience = 'b26e684c-5068-4120-a679-64a5d2c909d9',

    [Parameter(Mandatory = $false)]
    [string]$RequiredRole = 'eDiscovery.Download.Read'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-NotBlank {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "Missing required value: $Name"
    }
}

function Get-JwtPayload {
    param([Parameter(Mandatory = $true)][string]$Token)

    try {
        $parts = $Token.Split('.')
        if ($parts.Count -lt 2) { return $null }

        $payload = $parts[1].Replace('-', '+').Replace('_', '/')
        $mod = $payload.Length % 4
        if ($mod -eq 2) { $payload += '==' }
        elseif ($mod -eq 3) { $payload += '=' }
        elseif ($mod -eq 1) { return $null }

        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
        return ($json | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Get-Token {
    param(
        [Parameter(Mandatory = $true)][string]$Tenant,
        [Parameter(Mandatory = $true)][string]$Client,
        [Parameter(Mandatory = $true)][string]$Secret,
        [Parameter(Mandatory = $true)][string]$Scope
    )

    $tokenUri = "https://login.microsoftonline.com/$Tenant/oauth2/v2.0/token"
    $body = @{
        client_id     = $Client
        client_secret = $Secret
        scope         = $Scope
        grant_type    = 'client_credentials'
    }

    $response = Invoke-RestMethod -Method Post -Uri $tokenUri -Body $body -ContentType 'application/x-www-form-urlencoded'
    if ([string]::IsNullOrWhiteSpace($response.access_token)) {
        throw "Token endpoint response did not include access_token for scope '$Scope'."
    }

    return [string]$response.access_token
}

Assert-NotBlank -Name 'TenantId' -Value $TenantId
Assert-NotBlank -Name 'ClientId' -Value $ClientId
Assert-NotBlank -Name 'ClientSecret' -Value $ClientSecret
Assert-NotBlank -Name 'PurviewScope' -Value $PurviewScope
Assert-NotBlank -Name 'RequiredRole' -Value $RequiredRole

Write-Host ("Requesting token with scope: {0}" -f $PurviewScope)
$token = Get-Token -Tenant $TenantId -Client $ClientId -Secret $ClientSecret -Scope $PurviewScope

$payload = Get-JwtPayload -Token $token
if ($null -eq $payload) {
    Write-Error 'Could not decode JWT payload from token.'
    exit 2
}

$aud = [string]$payload.aud
$roles = @()
if ($null -ne $payload.roles) {
    if ($payload.roles -is [string]) {
        $roles = @([string]$payload.roles)
    }
    else {
        $roles = @($payload.roles)
    }
}

$hasRequiredRole = $roles -contains $RequiredRole
$audMatches = $true
if (-not [string]::IsNullOrWhiteSpace($ExpectedAudience)) {
    $audMatches = ($aud -eq $ExpectedAudience)
}

$roleList = if ($roles.Count -gt 0) { $roles -join ',' } else { 'none' }

Write-Host ("Token audience: {0}" -f $aud)
Write-Host ("Token roles: {0}" -f $roleList)
Write-Host ("Required role '{0}' present: {1}" -f $RequiredRole, $hasRequiredRole)
if (-not [string]::IsNullOrWhiteSpace($ExpectedAudience)) {
    Write-Host ("Expected audience '{0}' match: {1}" -f $ExpectedAudience, $audMatches)
}

if (-not $hasRequiredRole) {
    Write-Error ("Missing required role '{0}'. Grant application permission and admin consent for MicrosoftPurviewEDiscovery." -f $RequiredRole)
    exit 1
}

if (-not $audMatches) {
    Write-Error ("Unexpected token audience '{0}'. Expected '{1}'." -f $aud, $ExpectedAudience)
    exit 1
}

Write-Host 'PASS: Purview token includes the required role and expected audience.'
exit 0
