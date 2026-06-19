param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [string]$Location = 'westus2',

    [Parameter(Mandatory = $true)]
    [string]$NamePrefix,

    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [string]$ClientId,

    [SecureString]$ClientSecret,

    [bool]$UseKeyVaultReference = $true,

    [string]$KeyVaultSecretName = 'purview-client-secret',

    [string]$TimerSchedule = '0 */30 * * * *',

    [bool]$Aria2AutoInstall = $true,

    [string]$Aria2cPath = '/tmp/aria2c',

    [string]$Aria2DownloadUrl = 'https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-linux-gnu-64bit-build1.tar.gz'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-AzCli {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [switch]$CaptureOutput
    )

    if ($CaptureOutput) {
        $output = & az @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "az $($Arguments -join ' ') failed with exit code $LASTEXITCODE`n$($output -join [Environment]::NewLine)"
        }
        return $output
    }

    & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

Write-Host 'Ensuring Azure CLI is available...'
Invoke-AzCli -Arguments @('version') | Out-Null

Write-Host "Setting subscription: $SubscriptionId"
Invoke-AzCli -Arguments @('account', 'set', '--subscription', $SubscriptionId)

Write-Host "Ensuring resource group exists: $ResourceGroupName"
Invoke-AzCli -Arguments @('group', 'create', '--name', $ResourceGroupName, '--location', $Location, '-o', 'none')

if (-not $ClientSecret) {
    $ClientSecret = Read-Host -Prompt 'Enter app client secret' -AsSecureString
}

$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ClientSecret)
try {
    $clientSecretPlain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}

$deploymentName = "edisc-infra-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

$paramsFile = Join-Path $env:TEMP ("edisc-infra-params-{0}.json" -f [Guid]::NewGuid().ToString())
try {
    $paramsObject = [ordered]@{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters = [ordered]@{
            location = @{ value = $Location }
            namePrefix = @{ value = $NamePrefix }
            tenantId = @{ value = $TenantId }
            clientId = @{ value = $ClientId }
            clientSecret = @{ value = $clientSecretPlain }
            useKeyVaultReference = @{ value = $UseKeyVaultReference }
            keyVaultSecretName = @{ value = $KeyVaultSecretName }
            timerSchedule = @{ value = $TimerSchedule }
            aria2AutoInstall = @{ value = $Aria2AutoInstall }
            aria2cPath = @{ value = $Aria2cPath }
            aria2DownloadUrl = @{ value = $Aria2DownloadUrl }
        }
    }

    $paramsObject | ConvertTo-Json -Depth 10 | Set-Content -Path $paramsFile -Encoding UTF8

    Write-Host 'Deploying Bicep template...'
    Invoke-AzCli -Arguments @(
        'deployment', 'group', 'create',
        '--name', $deploymentName,
        '--resource-group', $ResourceGroupName,
        '--template-file', './infra/main.bicep',
        '--parameters', "@$paramsFile",
        '-o', 'none'
    )
}
finally {
    if (Test-Path $paramsFile) {
        Remove-Item -Path $paramsFile -Force
    }
}

$clientSecretPlain = $null

$functionAppName = (Invoke-AzCli -CaptureOutput -Arguments @(
    'deployment', 'group', 'show',
    '--name', $deploymentName,
    '--resource-group', $ResourceGroupName,
    '--query', 'properties.outputs.functionAppName.value',
    '-o', 'tsv'
)) -join ''

$keyVaultName = (Invoke-AzCli -CaptureOutput -Arguments @(
    'deployment', 'group', 'show',
    '--name', $deploymentName,
    '--resource-group', $ResourceGroupName,
    '--query', 'properties.outputs.keyVaultName.value',
    '-o', 'tsv'
)) -join ''

$clientSecretSource = (Invoke-AzCli -CaptureOutput -Arguments @(
    'deployment', 'group', 'show',
    '--name', $deploymentName,
    '--resource-group', $ResourceGroupName,
    '--query', 'properties.outputs.clientSecretSource.value',
    '-o', 'tsv'
)) -join ''

Write-Host ''
Write-Host 'Infra deployment complete.'
Write-Host "Function App Name: $functionAppName"
if (-not [string]::IsNullOrWhiteSpace($keyVaultName)) {
    Write-Host "Key Vault Name: $keyVaultName"
}
Write-Host "CLIENT_SECRET source: $clientSecretSource"
Write-Host ''
Write-Host 'Next step: publish function code'
Write-Host "func azure functionapp publish $functionAppName"
