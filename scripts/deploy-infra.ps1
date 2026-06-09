<#
.SYNOPSIS
  Deploys the ACA infrastructure while preserving the currently-deployed container image.

.DESCRIPTION
  Resolves the image currently running on the target Container App BEFORE invoking Bicep,
  so an infra-only redeploy doesn't flip the running app back to the bootstrap (hello-world)
  image. Falls back to a bootstrap image on first deploy.

.PARAMETER ResourceGroup
  Target resource group. Defaults to $env:RG.

.PARAMETER AppName
  Container App logical name. Defaults to $env:APP or 'api'.

.PARAMETER Location
  Azure region (only used if the resource group does not yet exist).

.PARAMETER BootstrapImage
  Image used on the very first deploy when no Container App exists yet.

.PARAMETER ParamFile
  Bicep parameters file.

.EXAMPLE
  $env:RG = 'rg-aca-demo'; ./scripts/deploy-infra.ps1
#>

[CmdletBinding()]
param(
    [string]$ResourceGroup  = $env:RG,
    [string]$AppName        = ($env:APP ?? 'api'),
    [string]$Location       = ($env:LOCATION ?? 'eastus2'),
    [string]$BootstrapImage = ($env:BOOTSTRAP_IMAGE ?? 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'),
    [string]$ParamFile      = ($env:PARAM_FILE ?? 'infra/main.bicepparam')
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ResourceGroup)) {
    throw "ResourceGroup is required. Pass -ResourceGroup or set `$env:RG."
}

# Ensure RG exists
az group show -n $ResourceGroup *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Creating resource group $ResourceGroup in $Location ..."
    az group create -n $ResourceGroup -l $Location | Out-Null
}

Write-Host "Resolving current image for $AppName in $ResourceGroup ..."
$image = az containerapp show -g $ResourceGroup -n $AppName `
            --query "properties.template.containers[0].image" -o tsv 2>$null

if ([string]::IsNullOrWhiteSpace($image)) {
    $image = $BootstrapImage
    Write-Host "  No existing app found. Using bootstrap image: $image"
} else {
    Write-Host "  Preserving current image: $image"
}

Write-Host "Running what-if ..."
az deployment group what-if `
    --resource-group $ResourceGroup `
    --template-file infra/main.bicep `
    --parameters $ParamFile `
    --parameters appName=$AppName image=$image
if ($LASTEXITCODE -ne 0) { throw "what-if failed" }

# Use --no-wait + manual polling so a stuck ARM call can be bounded by a real
# wall-clock timeout and retried, instead of `az` hanging indefinitely.
$deployTimeoutSeconds = if ($env:DEPLOY_TIMEOUT_SECONDS) { [int]$env:DEPLOY_TIMEOUT_SECONDS } else { 1500 }
$retries = if ($env:RETRIES) { [int]$env:RETRIES } else { 2 }

function Invoke-Deployment {
    param([int]$Attempt)

    $name = "aca-infra-$Attempt-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
    Write-Host "Deploy attempt $Attempt of $retries (deployment name: $name) ..."

    az deployment group create `
        --name $name `
        --resource-group $ResourceGroup `
        --template-file infra/main.bicep `
        --parameters $ParamFile `
        --parameters appName=$AppName image=$image `
        --no-wait `
        --output none
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Failed to start deployment (rc=$LASTEXITCODE)"
        return 1
    }

    $start = Get-Date
    while ($true) {
        $state = az deployment group show -g $ResourceGroup -n $name `
                    --query "properties.provisioningState" -o tsv 2>$null
        if ([string]::IsNullOrWhiteSpace($state)) { $state = 'Unknown' }

        switch ($state) {
            'Succeeded' {
                Write-Host "Deployment succeeded."
                return 0
            }
            { $_ -in 'Failed','Canceled' } {
                Write-Warning "Deployment $state. Error details:"
                az deployment group show -g $ResourceGroup -n $name `
                    --query "properties.error" -o json
                return 1
            }
        }

        $elapsed = ((Get-Date) - $start).TotalSeconds
        if ($elapsed -gt $deployTimeoutSeconds) {
            Write-Warning "Deployment exceeded $deployTimeoutSeconds s wall-clock timeout; cancelling ..."
            az deployment group cancel -g $ResourceGroup -n $name 2>$null | Out-Null
            return 124
        }
        Write-Host "." -NoNewline
        Start-Sleep -Seconds 15
    }
}

$attempt = 1
while ($true) {
    $rc = Invoke-Deployment -Attempt $attempt
    if ($rc -eq 0) { break }
    if ($attempt -ge $retries) {
        throw "Deployment failed after $attempt attempts."
    }
    $attempt++
    Write-Host "Retrying in 30s ..."
    Start-Sleep -Seconds 30
}

Write-Host "Done." -ForegroundColor Green
