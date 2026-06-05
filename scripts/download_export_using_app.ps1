[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$TenantId,
    [Parameter(Mandatory = $true)]
    [string]$AppId,
    [Parameter(Mandatory = $true)]
    [string]$AppSecret,
    [Parameter(Mandatory = $true)]
    [string]$CaseId,
    [Parameter(Mandatory = $true)]
    [string]$ExportId,
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [string]$GraphScope = 'https://graph.microsoft.com/.default',
    [string]$EdiscoveryAppScope = '',
    [string]$ExportScope = '',
    [string]$PurviewScope = 'https://api.purview.microsoft.com/.default',
    [string]$SecurityScope = 'https://api.security.microsoft.com/.default'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

    $resp = Invoke-RestMethod -Uri $tokenUri -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded'
    return $resp.access_token
}

function Get-JwtAudience {
    param([Parameter(Mandatory = $true)][string]$Token)

    if ([string]::IsNullOrWhiteSpace($Token)) {
        return $null
    }

    try {
        $parts = $Token.Split('.')
        if ($parts.Count -lt 2) {
            return $null
        }

        $payload = $parts[1].Replace('-', '+').Replace('_', '/')
        $mod4 = $payload.Length % 4
        if ($mod4 -eq 2) { $payload += '==' }
        elseif ($mod4 -eq 3) { $payload += '=' }
        elseif ($mod4 -eq 1) { return $null }

        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
        $obj = $json | ConvertFrom-Json
        return [string]$obj.aud
    }
    catch {
        return $null
    }
}

function Get-JwtClaimValues {
    param(
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$ClaimName
    )

    if ([string]::IsNullOrWhiteSpace($Token)) {
        return @()
    }

    try {
        $parts = $Token.Split('.')
        if ($parts.Count -lt 2) {
            return @()
        }

        $payload = $parts[1].Replace('-', '+').Replace('_', '/')
        $mod4 = $payload.Length % 4
        if ($mod4 -eq 2) { $payload += '==' }
        elseif ($mod4 -eq 3) { $payload += '=' }
        elseif ($mod4 -eq 1) { return @() }

        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
        $obj = $json | ConvertFrom-Json
        $value = $obj.$ClaimName

        if ($null -eq $value) {
            return @()
        }

        if ($value -is [string]) {
            if ([string]::IsNullOrWhiteSpace($value)) {
                return @()
            }

            return @($value)
        }

        return @($value)
    }
    catch {
        return @()
    }
}

function Get-ResponseBodyText {
    param([Parameter(Mandatory = $true)]$Response)

    try {
        if ($null -ne $Response.Content) {
            return [string]$Response.Content
        }
    }
    catch {
        return $null
    }

    return $null
}

if (-not (Test-Path -Path $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

Write-Host 'Getting Graph token...'
$graphToken = Get-Token -Tenant $TenantId -Client $AppId -Secret $AppSecret -Scope $GraphScope

$downloadTokens = @()
$downloadScopes = @($EdiscoveryAppScope, $ExportScope, $SecurityScope, $PurviewScope, $GraphScope)

foreach ($scope in $downloadScopes) {
    if ([string]::IsNullOrWhiteSpace($scope)) {
        continue
    }

    try {
        Write-Host "Getting download token for scope: $scope"
        $token = Get-Token -Tenant $TenantId -Client $AppId -Secret $AppSecret -Scope $scope
        if (-not [string]::IsNullOrWhiteSpace($token)) {
            $aud = Get-JwtAudience -Token $token
            if ([string]::IsNullOrWhiteSpace($aud)) {
                $aud = 'unknown-aud'
            }
            $roles = Get-JwtClaimValues -Token $token -ClaimName 'roles'
            $scopes = Get-JwtClaimValues -Token $token -ClaimName 'scp'
            $roleText = if (@($roles).Count -gt 0) { (@($roles) -join ',') } else { 'none' }
            $scopeText = if (@($scopes).Count -gt 0) { (@($scopes) -join ',') } else { 'none' }
            Write-Host ("Acquired token for scope '{0}' with aud '{1}'" -f $scope, $aud)
            Write-Host ("Token claims for scope '{0}': roles={1}; scp={2}" -f $scope, $roleText, $scopeText)
            $downloadTokens += [pscustomobject]@{
                Scope = $scope
                Token = $token
                Audience = $aud
                Roles = $roles
                Scopes = $scopes
            }
        }
    }
    catch {
        Write-Warning ("Could not get token for scope '{0}': {1}" -f $scope, $_.Exception.Message)
    }
}

if ($downloadTokens.Count -eq 0) {
    throw 'Unable to acquire any download tokens. Check app permissions/admin consent.'
}

$uri = "https://graph.microsoft.com/v1.0/security/cases/ediscoveryCases/$CaseId/operations/$ExportId"
$headers = @{ Authorization = "Bearer $graphToken" }

Write-Host "Fetching export metadata: $uri"
$export = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers

$files = @()
if ($export.exportFileMetadata) {
    $files = @($export.exportFileMetadata)
}
elseif ($export.additionalProperties -and $export.additionalProperties.exportFileMetadata) {
    $files = @($export.additionalProperties.exportFileMetadata)
}

if ($files.Count -eq 0) {
    throw 'Export metadata found, but no files were returned in exportFileMetadata.'
}

foreach ($file in $files) {
    if ([string]::IsNullOrWhiteSpace($file.downloadUrl) -or [string]::IsNullOrWhiteSpace($file.fileName)) {
        continue
    }

    $target = Join-Path $Path $file.fileName
    Write-Host "Downloading $($file.fileName) to $target"

    $downloaded = $false
    foreach ($entry in $downloadTokens) {
        if ($entry.Scope -eq $EdiscoveryAppScope -and (@($entry.Roles).Count -eq 0)) {
            Write-Warning ("The eDiscovery token for scope '{0}' has no roles claim. The download endpoint is explicitly rejecting it with 'Token does not contain valid scope or role'." -f $entry.Scope)
        }

        try {
            Write-Host ("Trying download with scope: {0} (aud={1})" -f $entry.Scope, $entry.Audience)
            $response = Invoke-WebRequest -Uri $file.downloadUrl -Headers @{
                Authorization        = "Bearer $($entry.Token)"
                'X-AllowWithAADToken' = 'true'
            } -MaximumRedirection 0 -SkipHttpErrorCheck

            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
                $contentBytes = $response.RawContentStream
                if ($null -ne $contentBytes) {
                    $contentBytes.Position = 0
                    $fileStream = [System.IO.File]::Open($target, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                    try {
                        $contentBytes.CopyTo($fileStream)
                    }
                    finally {
                        $fileStream.Dispose()
                    }
                }
                else {
                    Set-Content -Path $target -Value ($response.Content) -NoNewline
                }

                $downloaded = $true
                break
            }

            $status = $response.StatusCode
            $location = [string]$response.Headers['Location']
            $wwwAuth = [string]$response.Headers['WWW-Authenticate']
            $body = Get-ResponseBodyText -Response $response

            if (-not [string]::IsNullOrWhiteSpace($location)) {
                Write-Warning ("Download attempt failed with scope '{0}' (aud={1}): status={2}, redirect={3}" -f $entry.Scope, $entry.Audience, $status, $location)
            }
            elseif (-not [string]::IsNullOrWhiteSpace($wwwAuth)) {
                Write-Warning ("Download attempt failed with scope '{0}' (aud={1}): status={2}, www-authenticate={3}" -f $entry.Scope, $entry.Audience, $status, $wwwAuth)
            }
            elseif (-not [string]::IsNullOrWhiteSpace($body)) {
                Write-Warning ("Download attempt failed with scope '{0}' (aud={1}): status={2}, body={3}" -f $entry.Scope, $entry.Audience, $status, ($body -replace '\s+', ' ').Substring(0, [Math]::Min(300, $body.Length)))
            }
            else {
                Write-Warning ("Download attempt failed with scope '{0}' (aud={1}): status={2}" -f $entry.Scope, $entry.Audience, $status)
            }
        }
        catch {
            Write-Warning ("Download attempt failed with scope '{0}' (aud={1}): {2}" -f $entry.Scope, $entry.Audience, $_.Exception.Message)
        }
    }

    if (-not $downloaded) {
        throw "Failed to download $($file.fileName) with all available scopes."
    }

    $size = (Get-Item $target).Length
    Write-Host "Downloaded $($file.fileName): $size bytes"
}

Write-Host 'Download script completed.'
