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

Write-Host "Deploying ..."
az deployment group create `
    --resource-group $ResourceGroup `
    --template-file infra/main.bicep `
    --parameters $ParamFile `
    --parameters appName=$AppName image=$image `
    --output table
if ($LASTEXITCODE -ne 0) { throw "deployment failed" }

Write-Host "Done." -ForegroundColor Green
