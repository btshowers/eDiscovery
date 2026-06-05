# Test download of an export file to diagnose truncation issue

$ErrorActionPreference = 'Stop'

# Read state to get download details
$state = Get-Content state.json | ConvertFrom-Json
$op = $state.operations["ed1501b2-f391-47c3-b2eb-da1b929e6cc3|850e3a8428444d6094f7d9a3b849c732"]

Write-Host "Operation Status: $($op.status)"
Write-Host "Expected Files:"
$op.manifest | ForEach-Object {
    Write-Host "  - $($_.fileName): $($_.size) bytes"
}

# Get eDiscovery API token
$tenantId = [Environment]::GetEnvironmentVariable("TENANT_ID")
$clientId = [Environment]::GetEnvironmentVariable("CLIENT_ID") 
$clientSecret = [Environment]::GetEnvironmentVariable("CLIENT_SECRET")

if (-not $tenantId -or -not $clientId -or -not $clientSecret) {
    Write-Error "Missing TENANT_ID, CLIENT_ID, or CLIENT_SECRET environment variables"
    exit 1
}

Write-Host "`nGetting authentication tokens..."

# Get Graph token for API calls
$tokenUri = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
$body = @{
    client_id     = $clientId
    client_secret = $clientSecret
    scope         = 'https://graph.microsoft.com/.default'
    grant_type    = 'client_credentials'
}

$tokenResp = Invoke-RestMethod -Uri $tokenUri -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded'
$graphToken = $tokenResp.access_token

# Get case operations
$caseId = "ed1501b2-f391-47c3-b2eb-da1b929e6cc3"
$opId = "850e3a8428444d6094f7d9a3b849c732"

$opUri = "https://graph.microsoft.com/v1.0/security/cases/ediscoveryCases('$caseId')/operations('$opId')"
Write-Host "Fetching operation details from: $opUri"

$headers = @{ Authorization = "Bearer $graphToken" }
$opResp = Invoke-RestMethod -Uri $opUri -Method Get -Headers $headers

Write-Host "`nOperation Type: $($opResp.'@odata.type')"
Write-Host "Operation Status: $($opResp.status)"

# Get export file metadata if available
if ($opResp.exportFileMetadata) {
    Write-Host "`nExport File URLs:"
    $opResp.exportFileMetadata | ForEach-Object {
        Write-Host "  File: $($_.displayName)"
        Write-Host "    Size: $($_.sizeInBytes) bytes"
        Write-Host "    Download URL: $($_.downloadUrl -replace '([?&])[^&]*$', '$1...') (truncated)"
    }
    
    # Test download the first file
    if ($opResp.exportFileMetadata.Count -gt 0) {
        $firstFile = $opResp.exportFileMetadata[0]
        $downloadUrl = $firstFile.downloadUrl
        
        Write-Host "`nTesting download of: $($firstFile.displayName)"
        Write-Host "Expected size: $($firstFile.sizeInBytes) bytes"
        
        $testFile = Join-Path $env:TEMP "test-export-$(Get-Random).zip"
        
        try {
            Write-Host "Attempting anonymous download..."
            $response = Invoke-WebRequest -Uri $downloadUrl -OutFile $testFile -PassThru
            
            $downloadedSize = (Get-Item $testFile).Length
            $contentType = $response.Headers['Content-Type']
            $statusCode = $response.StatusCode
            
            Write-Host "Status Code: $statusCode"
            Write-Host "Content-Type: $contentType"
            Write-Host "Downloaded Size: $downloadedSize bytes"
            
            if ($downloadedSize -lt 100KB) {
                Write-Host "`nFile content preview (first 500 bytes):"
                $content = Get-Content $testFile -Raw -ErrorAction SilentlyContinue
                if ($content) {
                    Write-Host $content.Substring(0, [Math]::Min(500, $content.Length))
                } else {
                    Write-Host "(Unable to read as text)"
                }
            }
            
            Write-Host "`nDownload test complete."
        }
        catch {
            Write-Host "Download failed: $_"
            Write-Host "Exception: $($_.Exception | ConvertTo-Json)"
        }
        finally {
            if (Test-Path $testFile) {
                Remove-Item $testFile -Force
                Write-Host "Cleaned up test file"
            }
        }
    }
} else {
    Write-Host "No exportFileMetadata found in operation response"
    Write-Host "Response: $($opResp | ConvertTo-Json -Depth 5)"
}
