param(
    [string]$StorageConnectionString,

    [string]$StorageAccountName,

    [Parameter(Mandatory = $true)]
    [string[]]$CaseNames,

    [string]$ConfigContainer = "ediscovery-config",

    [string]$ConfigBlobName = "cases.json"
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($StorageConnectionString) -and [string]::IsNullOrWhiteSpace($StorageAccountName)) {
    throw "Provide either -StorageConnectionString or -StorageAccountName."
}

function Invoke-AzCli {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

if (-not (Get-Module -ListAvailable -Name Az.Storage)) {
    Write-Host "Az.Storage module not found. Installing..."
    Install-Module Az.Storage -Scope CurrentUser -Force
}

Import-Module Az.Storage

$config = [ordered]@{ cases = @() }
foreach ($name in $CaseNames) {
    $config.cases += [ordered]@{
        caseName = $name
        enabled  = $true
    }
}

$tmp = Join-Path $env:TEMP ("cases-{0}.json" -f [Guid]::NewGuid().ToString())
try {
    $config | ConvertTo-Json -Depth 50 | Set-Content -Path $tmp -Encoding UTF8

    if (-not [string]::IsNullOrWhiteSpace($StorageConnectionString)) {
        $context = New-AzStorageContext -ConnectionString $StorageConnectionString
        $container = Get-AzStorageContainer -Context $context -Name $ConfigContainer -ErrorAction SilentlyContinue
        if (-not $container) {
            $container = New-AzStorageContainer -Name $ConfigContainer -Context $context
        }

        Set-AzStorageBlobContent -Context $context -Container $ConfigContainer -Blob $ConfigBlobName -File $tmp -Force | Out-Null
    }
    else {
        Write-Host "Using Azure CLI login auth for storage account: $StorageAccountName"
        Invoke-AzCli -Arguments @(
            'storage', 'container', 'create',
            '--name', $ConfigContainer,
            '--account-name', $StorageAccountName,
            '--auth-mode', 'login',
            '--output', 'none'
        )

        Invoke-AzCli -Arguments @(
            'storage', 'blob', 'upload',
            '--account-name', $StorageAccountName,
            '--container-name', $ConfigContainer,
            '--name', $ConfigBlobName,
            '--file', $tmp,
            '--auth-mode', 'login',
            '--overwrite', 'true',
            '--output', 'none'
        )
    }

    Write-Host "Uploaded config blob: $ConfigContainer/$ConfigBlobName"
}
finally {
    if (Test-Path $tmp) {
        Remove-Item $tmp -Force
    }
}
