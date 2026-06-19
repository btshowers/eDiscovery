param($Timer)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-TempDir {
    $t = [Environment]::GetEnvironmentVariable('TEMP')
    if ([string]::IsNullOrWhiteSpace($t)) { $t = [Environment]::GetEnvironmentVariable('TMP') }
    if ([string]::IsNullOrWhiteSpace($t)) { $t = '/tmp' }
    return $t
}

function Get-RequiredSetting {
    param([Parameter(Mandatory = $true)][string]$Name)

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Missing required app setting: $Name"
    }

    return $value
}

function Get-Token {
    param(
        [Parameter(Mandatory = $true)][string]$TenantId,
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$ClientSecret,
        [Parameter(Mandatory = $true)][string]$Scope
    )

    $tokenUri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $body = @{
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = $Scope
        grant_type    = 'client_credentials'
    }

    $resp = Invoke-RestMethod -Uri $tokenUri -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded'
    return $resp.access_token
}

function Invoke-GraphPagedGet {
    param(
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [Parameter(Mandatory = $true)][string]$Uri
    )

    $headers = @{ Authorization = "Bearer $AccessToken" }
    $items = @()
    $next = $Uri

    while ($next) {
        $resp = Invoke-RestMethod -Uri $next -Method Get -Headers $headers

        $valueProperty = $resp.PSObject.Properties['value']
        if ($null -ne $valueProperty -and $null -ne $valueProperty.Value) {
            $items += @($valueProperty.Value)
        }

        $nextLinkProperty = $resp.PSObject.Properties['@odata.nextLink']
        if ($null -ne $nextLinkProperty -and -not [string]::IsNullOrWhiteSpace([string]$nextLinkProperty.Value)) {
            $next = [string]$nextLinkProperty.Value
        }
        else {
            $next = $null
        }
    }

    return $items
}

function Get-StorageContext {
    $accountName = [Environment]::GetEnvironmentVariable('AzureWebJobsStorage__accountName')
    if ([string]::IsNullOrWhiteSpace($accountName)) {
        throw "Missing required app setting: AzureWebJobsStorage__accountName"
    }

    return [pscustomobject]@{
        accountName = $accountName
    }
}

function Get-ManagedIdentityToken {
    $resource = [Uri]::EscapeDataString('https://storage.azure.com/')

    $identityEndpoint = [Environment]::GetEnvironmentVariable('IDENTITY_ENDPOINT')
    $identityHeader = [Environment]::GetEnvironmentVariable('IDENTITY_HEADER')
    if (-not [string]::IsNullOrWhiteSpace($identityEndpoint) -and -not [string]::IsNullOrWhiteSpace($identityHeader)) {
        $uri = "${identityEndpoint}?resource=$resource&api-version=2019-08-01"
        $headers = @{
            'X-IDENTITY-HEADER' = $identityHeader
            Metadata            = 'true'
        }
        $resp = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
        return $resp.access_token
    }

    $msiEndpoint = [Environment]::GetEnvironmentVariable('MSI_ENDPOINT')
    $msiSecret = [Environment]::GetEnvironmentVariable('MSI_SECRET')
    if (-not [string]::IsNullOrWhiteSpace($msiEndpoint) -and -not [string]::IsNullOrWhiteSpace($msiSecret)) {
        $uri = "${msiEndpoint}?resource=$resource&api-version=2017-09-01"
        $headers = @{
            Secret   = $msiSecret
            Metadata = 'true'
        }
        $resp = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
        return $resp.access_token
    }

    throw 'Managed identity endpoint is not available in the function environment.'
}

function Get-HttpStatusCode {
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    if ($null -eq $ErrorRecord -or $null -eq $ErrorRecord.Exception) {
        return $null
    }

    $responseProperty = $ErrorRecord.Exception.PSObject.Properties['Response']
    if ($null -eq $responseProperty) {
        return $null
    }

    $resp = $responseProperty.Value
    if ($null -eq $resp) { return $null }

    $statusProperty = $resp.PSObject.Properties['StatusCode']
    if ($null -eq $statusProperty -or $null -eq $statusProperty.Value) {
        return $null
    }

    return [int]$statusProperty.Value
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

function Get-ResponseStatusCode {
    param([Parameter(Mandatory = $true)]$Response)

    if ($null -eq $Response) {
        return $null
    }

    try {
        $statusProp = $Response.PSObject.Properties['StatusCode']
        if ($null -ne $statusProp -and $null -ne $statusProp.Value) {
            return [int]$statusProp.Value
        }
    }
    catch {
    }

    try {
        $baseResponseProp = $Response.PSObject.Properties['BaseResponse']
        if ($null -ne $baseResponseProp -and $null -ne $baseResponseProp.Value) {
            $baseStatusProp = $baseResponseProp.Value.PSObject.Properties['StatusCode']
            if ($null -ne $baseStatusProp -and $null -ne $baseStatusProp.Value) {
                return [int]$baseStatusProp.Value
            }
        }
    }
    catch {
    }

    return $null
}

function Get-ResponseHeaderValue {
    param(
        [Parameter(Mandatory = $true)]$Response,
        [Parameter(Mandatory = $true)][string]$HeaderName
    )

    if ($null -eq $Response) {
        return $null
    }

    try {
        $headersProp = $Response.PSObject.Properties['Headers']
        if ($null -eq $headersProp -or $null -eq $headersProp.Value) {
            return $null
        }

        $headers = $headersProp.Value
        $value = $headers[$HeaderName]
        if ($null -eq $value) {
            return $null
        }

        return [string]$value
    }
    catch {
        return $null
    }
}

function Get-HttpContentSnippet {
    param(
        [Parameter(Mandatory = $true)]$HttpContent,
        [int]$MaxChars = 512
    )

    try {
        if ($null -eq $HttpContent) {
            return $null
        }

        $raw = $HttpContent.ReadAsStringAsync().GetAwaiter().GetResult()
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $null
        }

        if ($raw.Length -gt $MaxChars) {
            return $raw.Substring(0, $MaxChars)
        }

        return $raw
    }
    catch {
        return $null
    }
}

function Invoke-HttpDownloadToFile {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [Parameter(Mandatory = $true)][string]$OutFile
    )

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate

    $client = [System.Net.Http.HttpClient]::new($handler)
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Url)

    try {
        foreach ($k in $Headers.Keys) {
            $value = [string]$Headers[$k]
            if ([string]::IsNullOrWhiteSpace($value)) { continue }
            [void]$request.Headers.TryAddWithoutValidation([string]$k, $value)
        }

        $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()

        $statusCode = [int]$response.StatusCode
        $contentType = $null
        if ($null -ne $response.Content -and $null -ne $response.Content.Headers -and $null -ne $response.Content.Headers.ContentType) {
            $contentType = [string]$response.Content.Headers.ContentType.MediaType
        }

        $location = $null
        if ($null -ne $response.Headers -and $null -ne $response.Headers.Location) {
            $location = [string]$response.Headers.Location
        }

        $wwwAuthenticate = $null
        if ($null -ne $response.Headers) {
            $wwwAuthValues = @($response.Headers.WwwAuthenticate)
            if ($wwwAuthValues.Count -gt 0) {
                $wwwAuthenticate = ($wwwAuthValues | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join '; '
            }
        }

        $bodySnippet = $null
        if ($statusCode -ge 200 -and $statusCode -lt 300) {
            $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            try {
                $fileStream = [System.IO.File]::Open($OutFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                try {
                    $stream.CopyTo($fileStream)
                }
                finally {
                    $fileStream.Dispose()
                }
            }
            finally {
                if ($null -ne $stream) {
                    $stream.Dispose()
                }
            }
        }
        else {
            $bodySnippet = Get-HttpContentSnippet -HttpContent $response.Content -MaxChars 512
        }

        return [pscustomobject]@{
            StatusCode      = $statusCode
            ContentType     = $contentType
            Location        = $location
            WwwAuthenticate = $wwwAuthenticate
            BodySnippet     = $bodySnippet
        }
    }
    finally {
        $request.Dispose()
        $client.Dispose()
        $handler.Dispose()
    }
}

function Get-Aria2Executable {
    if ($script:aria2Executable -is [string] -and -not [string]::IsNullOrWhiteSpace($script:aria2Executable)) {
        return $script:aria2Executable
    }

    function Install-Aria2IfNeeded {
        param([string]$TargetPath)

        $autoInstall = [Environment]::GetEnvironmentVariable('ARIA2_AUTO_INSTALL')
        if ([string]::IsNullOrWhiteSpace($autoInstall) -or @('1', 'true', 'yes', 'on') -notcontains $autoInstall.Trim().ToLowerInvariant()) {
            return $null
        }

        if ([string]::IsNullOrWhiteSpace($TargetPath)) {
            $TargetPath = [Environment]::GetEnvironmentVariable('ARIA2C_PATH')
        }
        if ([string]::IsNullOrWhiteSpace($TargetPath)) {
            $TargetPath = '/tmp/aria2c'
        }

        if (Test-Path $TargetPath) {
            return $TargetPath
        }

        $downloadUrl = [Environment]::GetEnvironmentVariable('ARIA2_DOWNLOAD_URL')
        if ([string]::IsNullOrWhiteSpace($downloadUrl)) {
            $downloadUrl = 'https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-linux-gnu-64bit-build1.tar.gz'
        }

        $tmpRoot = Join-Path (Get-TempDir) ("aria2-install-{0}" -f ([Guid]::NewGuid().ToString()))
        $archivePath = Join-Path $tmpRoot 'aria2.tar.gz'
        $extractPath = Join-Path $tmpRoot 'extract'
        try {
            New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
            New-Item -ItemType Directory -Path $extractPath -Force | Out-Null

            Write-Host ("aria2c not found; downloading from {0}" -f $downloadUrl)
            Invoke-WebRequest -Uri $downloadUrl -OutFile $archivePath -MaximumRedirection 5 -ErrorAction Stop | Out-Null

            & tar -xzf $archivePath -C $extractPath
            if ($LASTEXITCODE -ne 0) {
                throw 'tar extraction failed for aria2 archive.'
            }

            $aria2File = Get-ChildItem -Path $extractPath -Recurse -File | Where-Object { $_.Name -eq 'aria2c' } | Select-Object -First 1
            if ($null -eq $aria2File) {
                throw 'aria2c binary not found in extracted archive.'
            }

            $targetDir = Split-Path -Parent $TargetPath
            if (-not (Test-Path $targetDir)) {
                New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
            }

            Copy-Item -Path $aria2File.FullName -Destination $TargetPath -Force
            & chmod +x $TargetPath
            if ($LASTEXITCODE -ne 0) {
                throw 'chmod +x failed for aria2c binary.'
            }

            Write-Host ("aria2c installed to {0}" -f $TargetPath)
            return $TargetPath
        }
        catch {
            Write-Warning ("Failed to auto-install aria2c: {0}" -f $_.Exception.Message)
            return $null
        }
        finally {
            if (Test-Path $tmpRoot) {
                Remove-Item -Path $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $configuredPath = [Environment]::GetEnvironmentVariable('ARIA2C_PATH')
    if (-not [string]::IsNullOrWhiteSpace($configuredPath)) {
        if (Test-Path $configuredPath) {
            $script:aria2Executable = $configuredPath
            return $script:aria2Executable
        }

        $installedPath = Install-Aria2IfNeeded -TargetPath $configuredPath
        if (-not [string]::IsNullOrWhiteSpace($installedPath) -and (Test-Path $installedPath)) {
            $script:aria2Executable = $installedPath
            return $script:aria2Executable
        }

        Write-Warning ("ARIA2C_PATH is set but file was not found: {0}" -f $configuredPath)
    }

    try {
        $cmd = Get-Command 'aria2c' -ErrorAction Stop
        if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
            $script:aria2Executable = [string]$cmd.Source
            return $script:aria2Executable
        }
    }
    catch {
    }

    $installedDefault = Install-Aria2IfNeeded -TargetPath '/tmp/aria2c'
    if (-not [string]::IsNullOrWhiteSpace($installedDefault) -and (Test-Path $installedDefault)) {
        $script:aria2Executable = $installedDefault
        return $script:aria2Executable
    }

    return $null
}

function Invoke-Aria2DownloadToFile {
    param(
        [Parameter(Mandatory = $true)][string]$Aria2Executable,
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [Parameter(Mandatory = $true)][string]$OutFile
    )

    $targetDir = Split-Path -Parent $OutFile
    $targetName = Split-Path -Leaf $OutFile

    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    $args = @(
        '--allow-overwrite=true'
        '--auto-file-renaming=false'
        '--continue=true'
        '--file-allocation=none'
        '--summary-interval=0'
        '--console-log-level=warn'
        '--max-tries=4'
        '--retry-wait=2'
        '--timeout=60'
        '--split=16'
        '--max-connection-per-server=16'
        '--min-split-size=8M'
        '--dir', $targetDir,
        '--out', $targetName
    )

    foreach ($k in $Headers.Keys) {
        $v = [string]$Headers[$k]
        if ([string]::IsNullOrWhiteSpace($v)) {
            continue
        }

        $args += @('--header', ("{0}: {1}" -f [string]$k, $v))
    }

    $args += $Url

    $output = @(& $Aria2Executable @args 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $tail = ($output | Select-Object -Last 12) -join "`n"
        throw ("aria2c failed with exit code {0}. Output: {1}" -f $exitCode, $tail)
    }

    if (-not (Test-Path $OutFile)) {
        throw 'aria2c reported success, but output file was not found.'
    }

    return [pscustomobject]@{
        StatusCode      = 200
        ContentType     = $null
        Location        = $null
        WwwAuthenticate = $null
        BodySnippet     = $null
    }
}

function Get-HttpErrorBody {
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    try {
        if ($null -eq $ErrorRecord -or $null -eq $ErrorRecord.Exception) {
            return $null
        }

        $response = $ErrorRecord.Exception.Response
        if ($null -eq $response) {
            return $null
        }

        $stream = $response.GetResponseStream()
        if ($null -eq $stream) {
            return $null
        }

        try {
            $reader = New-Object System.IO.StreamReader($stream)
            $body = $reader.ReadToEnd()
            if ([string]::IsNullOrWhiteSpace($body)) {
                return $null
            }
            return $body
        }
        finally {
            $stream.Close()
        }
    }
    catch {
        return $null
    }
}

function Get-HttpResponseHeader {
    param(
        [Parameter(Mandatory = $true)]$ErrorRecord,
        [Parameter(Mandatory = $true)][string]$HeaderName
    )

    try {
        if ($null -eq $ErrorRecord -or $null -eq $ErrorRecord.Exception -or $null -eq $ErrorRecord.Exception.Response) {
            return $null
        }

        $headers = $ErrorRecord.Exception.Response.Headers
        if ($null -eq $headers) {
            return $null
        }

        $value = $headers[$HeaderName]
        if ($null -eq $value) {
            return $null
        }

        return [string]$value
    }
    catch {
        return $null
    }
}

function Get-EncodedBlobName {
    param([Parameter(Mandatory = $true)][string]$BlobName)

    $parts = @($BlobName -split '/')
    $encoded = foreach ($part in $parts) {
        [Uri]::EscapeDataString($part)
    }

    return ($encoded -join '/')
}

function Get-ContainerUrl {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Container
    )

    return "https://$($Context.accountName).blob.core.windows.net/$([Uri]::EscapeDataString($Container))"
}

function Get-BlobUrl {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Container,
        [Parameter(Mandatory = $true)][string]$BlobName
    )

    $encodedBlobName = Get-EncodedBlobName -BlobName $BlobName
    return "$(Get-ContainerUrl -Context $Context -Container $Container)/$encodedBlobName"
}

function Invoke-StorageRequest {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$InFile,
        [string]$OutFile,
        [string]$ContentType,
        [hashtable]$ExtraHeaders
    )

    $token = Get-ManagedIdentityToken
    $headers = @{
        Authorization = "Bearer $token"
        'x-ms-version' = '2023-11-03'
        'x-ms-date' = [DateTime]::UtcNow.ToString('R')
    }

    if ($ExtraHeaders) {
        foreach ($k in $ExtraHeaders.Keys) {
            $headers[$k] = $ExtraHeaders[$k]
        }
    }

    $params = @{
        Method = $Method
        Uri = $Uri
        Headers = $headers
        ErrorAction = 'Stop'
    }

    if (-not [string]::IsNullOrWhiteSpace($InFile)) {
        $params['InFile'] = $InFile
        if (-not [string]::IsNullOrWhiteSpace($ContentType)) {
            $params['ContentType'] = $ContentType
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
        $params['OutFile'] = $OutFile
    }

    return Invoke-WebRequest @params
}

function Initialize-Container {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $uri = "$(Get-ContainerUrl -Context $Context -Container $Name)?restype=container"
    try {
        Invoke-StorageRequest -Context $Context -Method Put -Uri $uri | Out-Null
    }
    catch {
        $status = Get-HttpStatusCode -ErrorRecord $_
        if ($status -ne 409) {
            throw
        }
    }
}

function Read-BlobJsonOrDefault {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Container,
        [Parameter(Mandatory = $true)][string]$BlobName,
        [Parameter(Mandatory = $true)]$DefaultObject
    )

    $tmp = Join-Path (Get-TempDir) ("ediscovery-{0}.json" -f ([Guid]::NewGuid().ToString()))
    try {
        $uri = Get-BlobUrl -Context $Context -Container $Container -BlobName $BlobName
        Invoke-StorageRequest -Context $Context -Method Get -Uri $uri -OutFile $tmp | Out-Null
        $text = Get-Content -Path $tmp -Raw
        if ([string]::IsNullOrWhiteSpace($text)) {
            return $DefaultObject
        }

        return ($text | ConvertFrom-Json -Depth 100)
    }
    catch {
        $status = Get-HttpStatusCode -ErrorRecord $_
        if ($status -eq 404) {
            return $DefaultObject
        }
        throw
    }
    finally {
        if (Test-Path $tmp) {
            Remove-Item $tmp -Force
        }
    }
}

function Write-BlobJson {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Container,
        [Parameter(Mandatory = $true)][string]$BlobName,
        [Parameter(Mandatory = $true)]$Object
    )

    $tmp = Join-Path (Get-TempDir) ("ediscovery-{0}.json" -f ([Guid]::NewGuid().ToString()))
    try {
        $Object | ConvertTo-Json -Depth 100 | Set-Content -Path $tmp -Encoding UTF8
        $uri = Get-BlobUrl -Context $Context -Container $Container -BlobName $BlobName
        Invoke-StorageRequest -Context $Context -Method Put -Uri $uri -InFile $tmp -ContentType 'application/json; charset=utf-8' -ExtraHeaders @{ 'x-ms-blob-type' = 'BlockBlob' } | Out-Null
    }
    finally {
        if (Test-Path $tmp) {
            Remove-Item $tmp -Force
        }
    }
}

function Get-ConfiguredCaseNames {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$ConfigContainer,
        [Parameter(Mandatory = $true)][string]$ConfigBlob
    )

    $default = [pscustomobject]@{ cases = @() }
    $config = Read-BlobJsonOrDefault -Context $Context -Container $ConfigContainer -BlobName $ConfigBlob -DefaultObject $default

    $caseItems = @()
    if ($null -ne $config -and $null -ne $config.PSObject.Properties['cases']) {
        $caseItems = @($config.cases)
    }

    $names = @()
    foreach ($c in $caseItems) {
        if ($null -eq $c) { continue }

        $caseNameProperty = $c.PSObject.Properties['caseName']
        if ($null -eq $caseNameProperty) { continue }

        $enabled = $true
        $enabledProperty = $c.PSObject.Properties['enabled']
        if ($null -ne $enabledProperty) { $enabled = [bool]$enabledProperty.Value }

        $caseName = [string]$caseNameProperty.Value
        if ($enabled -and -not [string]::IsNullOrWhiteSpace($caseName)) {
            $names += $caseName.Trim()
        }
    }

    return $names
}

function Get-State {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$StateContainer,
        [Parameter(Mandatory = $true)][string]$StateBlob
    )

    $default = [pscustomobject]@{
        version    = 1
        operations = @{}
    }

    $state = Read-BlobJsonOrDefault -Context $Context -Container $StateContainer -BlobName $StateBlob -DefaultObject $default

    if ($null -eq $state.operations) {
        $state | Add-Member -NotePropertyName operations -NotePropertyValue @{} -Force
    }

    # Convert deserialized PSCustomObject state map to a mutable hashtable.
    if ($state.operations -isnot [System.Collections.IDictionary]) {
        $opsMap = @{}
        foreach ($p in $state.operations.PSObject.Properties) {
            $opsMap[$p.Name] = $p.Value
        }
        $state.operations = $opsMap
    }

    return $state
}

function Save-State {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$StateContainer,
        [Parameter(Mandatory = $true)][string]$StateBlob,
        [Parameter(Mandatory = $true)]$State
    )

    Write-BlobJson -Context $Context -Container $StateContainer -BlobName $StateBlob -Object $State
}

function Get-StateKey {
    param(
        [Parameter(Mandatory = $true)][string]$CaseId,
        [Parameter(Mandatory = $true)][string]$OperationId
    )

    return "$CaseId|$OperationId"
}

function Set-OperationState {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$CaseId,
        [Parameter(Mandatory = $true)][string]$CaseName,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][string]$Status,
        $Manifest,
        [string]$LastError
    )

    $key = Get-StateKey -CaseId $CaseId -OperationId $OperationId
    $entry = [ordered]@{
        caseId       = $CaseId
        caseName     = $CaseName
        operationId  = $OperationId
        status       = $Status
        updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    }

    if ($Status -eq 'Downloaded') {
        $entry.downloadedAtUtc = [DateTime]::UtcNow.ToString('o')
    }

    if ($Manifest) {
        $entry.manifest = $Manifest
    }

    if (-not [string]::IsNullOrWhiteSpace($LastError)) {
        $entry.lastError = $LastError
    }

    $State.operations[$key] = $entry
}

function Resolve-CaseMap {
    param(
        [Parameter(Mandatory = $true)][string]$GraphToken,
        [Parameter(Mandatory = $true)][string[]]$ConfiguredCaseNames
    )

    $caseLookup = @{}
    foreach ($name in $ConfiguredCaseNames) {
        $caseLookup[$name.ToLowerInvariant()] = $name
    }

    $allCasesUri = 'https://graph.microsoft.com/v1.0/security/cases/ediscoveryCases?$top=200'
    $allCases = Invoke-GraphPagedGet -AccessToken $GraphToken -Uri $allCasesUri

    $resolved = @{}
    foreach ($case in $allCases) {
        $displayName = [string]$case.displayName
        if ([string]::IsNullOrWhiteSpace($displayName)) { continue }

        $key = $displayName.Trim().ToLowerInvariant()
        if ($caseLookup.ContainsKey($key)) {
            $resolved[$caseLookup[$key]] = [string]$case.id
        }
    }

    return $resolved
}

function Get-CaseOperations {
    param(
        [Parameter(Mandatory = $true)][string]$GraphToken,
        [Parameter(Mandatory = $true)][string]$CaseId
    )

    $uri = "https://graph.microsoft.com/v1.0/security/cases/ediscoveryCases/$CaseId/operations?`$top=200"
    return Invoke-GraphPagedGet -AccessToken $GraphToken -Uri $uri
}

function Get-OperationDetail {
    param(
        [Parameter(Mandatory = $true)][string]$GraphToken,
        [Parameter(Mandatory = $true)][string]$CaseId,
        [Parameter(Mandatory = $true)][string]$OperationId
    )

    $uri = "https://graph.microsoft.com/v1.0/security/cases/ediscoveryCases/$CaseId/operations/$OperationId"
    $headers = @{ Authorization = "Bearer $GraphToken" }
    return Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
}

function Save-UrlToBlob {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Container,
        [Parameter(Mandatory = $true)][string]$BlobName,
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)]$DownloadTokens
    )

    $tmp = Join-Path (Get-TempDir) ("ediscovery-download-{0}" -f ([Guid]::NewGuid().ToString()))
    $downloadHost = $null
    try {
        $downloadHost = ([Uri]$Url).Host
    }
    catch {
        $downloadHost = 'unknown-host'
    }

    # Log download URL details for debugging (mask sensitive parts)
    $urlInfo = $Url
    if ($urlInfo.Length -gt 200) {
        $urlInfo = $urlInfo.Substring(0, 200) + "... [truncated]"
    }
    Write-Host ("Attempting to download from: {0}" -f $urlInfo)

    try {
        $downloaded = $false
        $aria2Executable = Get-Aria2Executable
        if (-not [string]::IsNullOrWhiteSpace($aria2Executable)) {
            Write-Host ("aria2c detected at: {0}" -f $aria2Executable)
        }
        $attempts = @()
        $attemptIndex = 0

        $anonymousAttempt = @{
            Name = 'anonymous'
            Scope = 'none'
            Audience = 'none'
            Roles = @()
            Headers = @{ 'X-AllowWithAADToken' = 'true' }
        }

        $tokenAttempts = @()
        foreach ($entry in $DownloadTokens) {
            if ($null -eq $entry) {
                continue
            }

            if ($entry -is [string]) {
                if ([string]::IsNullOrWhiteSpace($entry)) {
                    continue
                }

                $attemptIndex += 1
                $aud = Get-JwtAudience -Token $entry
                if ([string]::IsNullOrWhiteSpace($aud)) { $aud = 'unknown-aud' }

                $tokenAttempts += @{
                    Name = "bearer-token-$attemptIndex"
                    Scope = "token-$attemptIndex"
                    Audience = $aud
                    Roles = @()
                    Headers = @{
                        Authorization = "Bearer $entry"
                        'X-AllowWithAADToken' = 'true'
                    }
                }
                continue
            }

            if ([string]::IsNullOrWhiteSpace([string]$entry.Token)) {
                continue
            }

            $attemptIndex += 1
            $attemptName = [string]$entry.Scope
            if ([string]::IsNullOrWhiteSpace($attemptName)) {
                $attemptName = "bearer-token-$attemptIndex"
            }

            $attemptAudience = [string]$entry.Audience
            if ([string]::IsNullOrWhiteSpace($attemptAudience)) {
                $attemptAudience = Get-JwtAudience -Token $entry.Token
            }
            if ([string]::IsNullOrWhiteSpace($attemptAudience)) {
                $attemptAudience = 'unknown-aud'
            }

            $tokenAttempts += @{
                Name = "scope-$attemptIndex"
                Scope = $attemptName
                Audience = $attemptAudience
                Roles = @($entry.Roles)
                Headers = @{
                    Authorization = "Bearer $($entry.Token)"
                    'X-AllowWithAADToken' = 'true'
                }
            }
        }

        # Bearer token authentication is required for eDiscovery export downloads
        # Pre-signed URLs expire quickly (~24 hours) and may redirect to auth
        # Always try bearer tokens first, then anonymous as fallback
        $attempts += $tokenAttempts
        $attempts += $anonymousAttempt

        foreach ($attempt in $attempts) {
            try {
                if ($attempt.Scope -eq 'b26e684c-5068-4120-a679-64a5d2c909d9/.default' -and @($attempt.Roles).Count -eq 0) {
                    Write-Warning ("The eDiscovery token for scope '{0}' has no roles claim. Download endpoint may reject it with 'Token does not contain valid scope or role'." -f $attempt.Scope)
                }

                Write-Host ("Downloading export from host {0} using scope {1} (aud={2})." -f $downloadHost, $attempt.Scope, $attempt.Audience)

                $response = $null
                if (-not [string]::IsNullOrWhiteSpace($aria2Executable)) {
                    $response = Invoke-Aria2DownloadToFile -Aria2Executable $aria2Executable -Url $Url -Headers $attempt.Headers -OutFile $tmp
                }
                else {
                    $response = Invoke-HttpDownloadToFile -Url $Url -Headers $attempt.Headers -OutFile $tmp
                }
                $statusCode = [int]$response.StatusCode

                if ($statusCode -ge 200 -and $statusCode -lt 300) {
                    $fileSize = (Get-Item $tmp).Length
                    $contentType = [string]$response.ContentType

                    if ($fileSize -lt 100KB) {
                        $snippet = Get-Content $tmp -Raw -ErrorAction SilentlyContinue
                        if ($snippet -match '<!DOCTYPE|<html|<?xml|Sign in to your account|Account sign in' -or $snippet -match '^{.*"error') {
                            if ($snippet.Length -gt 256) { $snippet = $snippet.Substring(0, 256) }
                            Write-Warning ("Downloaded content appears to be an error/auth page (first 256 chars): $snippet")
                            continue
                        }
                        if (-not $contentType -or -not ($contentType -match 'zip|octet-stream|application/x-zip')) {
                            Write-Warning ("File size is small ($fileSize bytes) and Content-Type ($contentType) does not match zip. Trying next token.")
                            continue
                        }
                    }

                    Write-Host ("Successfully downloaded {0} bytes using scope {1}." -f $fileSize, $attempt.Scope)
                    $downloaded = $true
                    break
                }

                $locationHeader = [string]$response.Location
                $wwwAuthenticate = [string]$response.WwwAuthenticate
                $body = [string]$response.BodySnippet
                $isRedirect = @('301','302','303','307','308') -contains ([string]$statusCode)

                if (($statusCode -eq 401 -or $isRedirect) -and $attempt.Name -ne 'anonymous') {
                    if (-not [string]::IsNullOrWhiteSpace($locationHeader)) {
                        Write-Host ("Download attempt with scope {0} (aud={1}, host={2}) returned {3} redirect to: {4}" -f $attempt.Scope, $attempt.Audience, $downloadHost, $statusCode, $locationHeader)
                    }
                    elseif (-not [string]::IsNullOrWhiteSpace($wwwAuthenticate)) {
                        Write-Host ("Download attempt with scope {0} (aud={1}, host={2}) returned {3} with WWW-Authenticate: {4}" -f $attempt.Scope, $attempt.Audience, $downloadHost, $statusCode, $wwwAuthenticate)
                    }
                    elseif (-not [string]::IsNullOrWhiteSpace($body)) {
                        $snippet = $body
                        if ($snippet.Length -gt 256) { $snippet = $snippet.Substring(0, 256) }
                        Write-Host ("Download attempt with scope {0} (aud={1}, host={2}) returned {3} with body: {4}" -f $attempt.Scope, $attempt.Audience, $downloadHost, $statusCode, $snippet)
                    }
                    else {
                        Write-Host ("Download attempt with scope {0} (aud={1}, host={2}) returned {3}; trying next fallback." -f $attempt.Scope, $attempt.Audience, $downloadHost, $statusCode)
                    }

                    continue
                }

                if (-not [string]::IsNullOrWhiteSpace($locationHeader)) {
                    Write-Warning ("Download attempt failed with scope '{0}' (aud={1}): status={2}, redirect={3}" -f $attempt.Scope, $attempt.Audience, $statusCode, $locationHeader)
                }
                elseif (-not [string]::IsNullOrWhiteSpace($wwwAuthenticate)) {
                    Write-Warning ("Download attempt failed with scope '{0}' (aud={1}): status={2}, www-authenticate={3}" -f $attempt.Scope, $attempt.Audience, $statusCode, $wwwAuthenticate)
                }
                elseif (-not [string]::IsNullOrWhiteSpace($body)) {
                    $snippet = ($body -replace '\s+', ' ')
                    if ($snippet.Length -gt 300) { $snippet = $snippet.Substring(0, 300) }
                    Write-Warning ("Download attempt failed with scope '{0}' (aud={1}): status={2}, body={3}" -f $attempt.Scope, $attempt.Audience, $statusCode, $snippet)
                }
                else {
                    Write-Warning ("Download attempt failed with scope '{0}' (aud={1}): status={2}" -f $attempt.Scope, $attempt.Audience, $statusCode)
                }
            }
            catch {
                # 'Operation is not valid due to the current state of the object' can occur
                # when Invoke-WebRequest -OutFile -PassThru receives a non-readable response
                # body (e.g. GCC proxy returning empty 401). Treat as auth failure and continue.
                Write-Warning ("Download attempt failed with scope '{0}' (aud={1}): {2}" -f $attempt.Scope, $attempt.Audience, $_.Exception.Message)
                if (Test-Path $tmp) {
                    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
                }
            }
        }

        if (-not $downloaded) {
            throw "Failed to download export from $Url."
        }

        $blobUri = Get-BlobUrl -Context $Context -Container $Container -BlobName $BlobName
        Invoke-StorageRequest -Context $Context -Method Put -Uri $blobUri -InFile $tmp -ContentType 'application/octet-stream' -ExtraHeaders @{ 'x-ms-blob-type' = 'BlockBlob' } | Out-Null
    }
    finally {
        if (Test-Path $tmp) {
            Remove-Item $tmp -Force
        }
    }
}

function Get-SafeSegment {
    param([Parameter(Mandatory = $true)][string]$Value)

    $s = $Value
    foreach ($ch in @('<','>',':','"','/','\','|','?','*')) {
        $s = $s.Replace($ch, '_')
    }

    if ([string]::IsNullOrWhiteSpace($s)) {
        return 'unknown-case'
    }

    return $s.Trim()
}

Write-Host 'Starting eDiscovery export polling run.'

$tenantId = Get-RequiredSetting -Name 'TENANT_ID'
$clientId = Get-RequiredSetting -Name 'CLIENT_ID'
$clientSecret = Get-RequiredSetting -Name 'CLIENT_SECRET'

$graphScope = [Environment]::GetEnvironmentVariable('GRAPH_SCOPE')
if ([string]::IsNullOrWhiteSpace($graphScope)) { $graphScope = 'https://graph.microsoft.com/.default' }

$purviewScope = [Environment]::GetEnvironmentVariable('PURVIEW_SCOPE')
if ([string]::IsNullOrWhiteSpace($purviewScope)) { $purviewScope = 'https://api.purview.microsoft.com/.default' }

$purviewDownloadScope = [Environment]::GetEnvironmentVariable('PURVIEW_DOWNLOAD_SCOPE')
if ([string]::IsNullOrWhiteSpace($purviewDownloadScope)) { $purviewDownloadScope = 'https://api.security.microsoft.com/.default' }

$ediscoveryAppScope = [Environment]::GetEnvironmentVariable('EDISCOVERY_APP_SCOPE')
$exportDownloadScope = [Environment]::GetEnvironmentVariable('EXPORT_DOWNLOAD_SCOPE')

if ($exportDownloadScope -eq '00001111-aaaa-2222-bbbb-3333cccc4444/.default') {
    Write-Host 'EXPORT_DOWNLOAD_SCOPE is set to a legacy placeholder value; ignoring it. Leave it empty unless you have a tenant-specific scope.'
    $exportDownloadScope = $null
}

$configContainer = [Environment]::GetEnvironmentVariable('CONFIG_CONTAINER')
if ([string]::IsNullOrWhiteSpace($configContainer)) { $configContainer = 'ediscovery-config' }

$configBlob = [Environment]::GetEnvironmentVariable('CONFIG_BLOB_NAME')
if ([string]::IsNullOrWhiteSpace($configBlob)) { $configBlob = 'cases.json' }

$stateContainer = [Environment]::GetEnvironmentVariable('STATE_CONTAINER')
if ([string]::IsNullOrWhiteSpace($stateContainer)) { $stateContainer = 'ediscovery-state' }

$stateBlob = [Environment]::GetEnvironmentVariable('STATE_BLOB_NAME')
if ([string]::IsNullOrWhiteSpace($stateBlob)) { $stateBlob = 'state.json' }

$exportsContainer = [Environment]::GetEnvironmentVariable('EXPORTS_CONTAINER')
if ([string]::IsNullOrWhiteSpace($exportsContainer)) { $exportsContainer = 'exports' }

$storageContext = Get-StorageContext
Initialize-Container -Context $storageContext -Name $configContainer
Initialize-Container -Context $storageContext -Name $stateContainer
Initialize-Container -Context $storageContext -Name $exportsContainer

$caseNames = @(Get-ConfiguredCaseNames -Context $storageContext -ConfigContainer $configContainer -ConfigBlob $configBlob)
if (-not $caseNames -or $caseNames.Count -eq 0) {
    Write-Host "No enabled cases found in $configContainer/$configBlob"
    return
}

$graphToken = Get-Token -TenantId $tenantId -ClientId $clientId -ClientSecret $clientSecret -Scope $graphScope
$purviewToken = Get-Token -TenantId $tenantId -ClientId $clientId -ClientSecret $clientSecret -Scope $purviewScope

$script:downloadTokenEntries = @()

function Add-DownloadTokenEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Scope,
        [Parameter(Mandatory = $true)][string]$Token
    )

    if ([string]::IsNullOrWhiteSpace($Scope) -or [string]::IsNullOrWhiteSpace($Token)) {
        return
    }

    $aud = Get-JwtAudience -Token $Token
    if ([string]::IsNullOrWhiteSpace($aud)) {
        $aud = 'unknown-aud'
    }

    $roles = Get-JwtClaimValues -Token $Token -ClaimName 'roles'
    $scopes = Get-JwtClaimValues -Token $Token -ClaimName 'scp'
    $roleText = if (@($roles).Count -gt 0) { (@($roles) -join ',') } else { 'none' }
    $scopeText = if (@($scopes).Count -gt 0) { (@($scopes) -join ',') } else { 'none' }
    Write-Host ("Acquired token for scope '{0}' with aud '{1}'" -f $Scope, $aud)
    Write-Host ("Token claims for scope '{0}': roles={1}; scp={2}" -f $Scope, $roleText, $scopeText)

    $script:downloadTokenEntries += [pscustomobject]@{
        Scope    = $Scope
        Token    = $Token
        Audience = $aud
        Roles    = $roles
        Scopes   = $scopes
    }
}

Add-DownloadTokenEntry -Scope $graphScope -Token $graphToken
Add-DownloadTokenEntry -Scope $purviewScope -Token $purviewToken

$optionalScopes = @(
    [pscustomobject]@{ Name = 'EDISCOVERY_APP_SCOPE'; Scope = $ediscoveryAppScope; Warning = 'Unable to acquire eDiscovery app token for scope' }
    [pscustomobject]@{ Name = 'EXPORT_DOWNLOAD_SCOPE'; Scope = $exportDownloadScope; Warning = 'Unable to acquire export download token for scope' }
)

foreach ($optional in $optionalScopes) {
    if ([string]::IsNullOrWhiteSpace($optional.Scope)) {
        Write-Host ("{0} not set; skipping optional token acquisition." -f $optional.Name)
        continue
    }

    try {
        $tok = Get-Token -TenantId $tenantId -ClientId $clientId -ClientSecret $clientSecret -Scope $optional.Scope
        Add-DownloadTokenEntry -Scope $optional.Scope -Token $tok
    }
    catch {
        Write-Warning ("{0} '{1}'. Falling back to other download scopes. Error: {2}" -f $optional.Warning, $optional.Scope, $_.Exception.Message)
    }
}

if ($purviewDownloadScope -ne $purviewScope) {
    try {
        $purviewDownloadToken = Get-Token -TenantId $tenantId -ClientId $clientId -ClientSecret $clientSecret -Scope $purviewDownloadScope
        Add-DownloadTokenEntry -Scope $purviewDownloadScope -Token $purviewDownloadToken
    }
    catch {
        Write-Warning ("Unable to acquire Purview download token for scope '{0}'. Falling back to other download scopes. Error: {1}" -f $purviewDownloadScope, $_.Exception.Message)
    }
}

$downloadTokenEntries = @($downloadTokenEntries | Group-Object Scope | ForEach-Object { $_.Group[0] })
if ($downloadTokenEntries.Count -eq 0) {
    throw 'Unable to acquire any download tokens. Check app permissions/admin consent.'
}

$caseMap = Resolve-CaseMap -GraphToken $graphToken -ConfiguredCaseNames $caseNames
$unknown = @($caseNames | Where-Object { -not $caseMap.ContainsKey($_) })
if ($unknown.Count -gt 0) {
    Write-Warning ("Configured case names not found: {0}" -f ($unknown -join ', '))
}

if ($caseMap.Count -eq 0) {
    Write-Host 'No configured cases resolved to case IDs.'
    return
}

$state = Get-State -Context $storageContext -StateContainer $stateContainer -StateBlob $stateBlob

$exportActions = @('exportresult', 'contentexport')
$doneStatuses = @('succeeded', 'completed')

foreach ($caseName in $caseMap.Keys) {
    $caseId = $caseMap[$caseName]
    Write-Host "Checking case: $caseName ($caseId)"

    $ops = Get-CaseOperations -GraphToken $graphToken -CaseId $caseId
    foreach ($op in $ops) {
        $operationId = [string]$op.id
        if ([string]::IsNullOrWhiteSpace($operationId)) { continue }

        $action = ([string]$op.action).ToLowerInvariant()
        $status = ([string]$op.status).ToLowerInvariant()
        if (($exportActions -notcontains $action) -or ($doneStatuses -notcontains $status)) {
            continue
        }

        $key = Get-StateKey -CaseId $caseId -OperationId $operationId
        if ($state.operations.ContainsKey($key) -and $state.operations[$key].status -eq 'Downloaded') {
            Write-Host "Skipping already downloaded export: $operationId"
            continue
        }

        try {
            Set-OperationState -State $state -CaseId $caseId -CaseName $caseName -OperationId $operationId -Status 'InProgress'
            Save-State -Context $storageContext -StateContainer $stateContainer -StateBlob $stateBlob -State $state

            $detail = Get-OperationDetail -GraphToken $graphToken -CaseId $caseId -OperationId $operationId
            $exportMeta = @()
            if ($detail.exportFileMetadata) {
                $exportMeta = @($detail.exportFileMetadata)
            }
            elseif ($detail.additionalProperties -and $detail.additionalProperties.exportFileMetadata) {
                $exportMeta = @($detail.additionalProperties.exportFileMetadata)
            }

            if ($exportMeta.Count -eq 0) {
                Write-Host "No export files on operation $operationId"
                continue
            }

            $manifest = @()
            foreach ($file in $exportMeta) {
                if ([string]::IsNullOrWhiteSpace($file.downloadUrl) -or [string]::IsNullOrWhiteSpace($file.fileName)) {
                    continue
                }

                $blobName = "{0}/{1}/{2}" -f (Get-SafeSegment -Value $caseName), $operationId, $file.fileName
                Save-UrlToBlob -Context $storageContext -Container $exportsContainer -BlobName $blobName -Url $file.downloadUrl -DownloadTokens $downloadTokenEntries

                $manifest += [pscustomobject]@{
                    fileName = [string]$file.fileName
                    blobName = $blobName
                    size     = $file.size
                }
            }

            Set-OperationState -State $state -CaseId $caseId -CaseName $caseName -OperationId $operationId -Status 'Downloaded' -Manifest $manifest
            Save-State -Context $storageContext -StateContainer $stateContainer -StateBlob $stateBlob -State $state

            Write-Host "Downloaded operation $operationId with $($manifest.Count) file(s)."
        }
        catch {
            $msg = $_.Exception.Message
            Write-Error "Failed operation $operationId in case ${caseName}: $msg"
            Set-OperationState -State $state -CaseId $caseId -CaseName $caseName -OperationId $operationId -Status 'Failed' -LastError $msg
            Save-State -Context $storageContext -StateContainer $stateContainer -StateBlob $stateBlob -State $state
        }
    }
}

Write-Host 'eDiscovery export polling run complete.'
