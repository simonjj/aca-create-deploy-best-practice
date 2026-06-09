<#
.SYNOPSIS
  Builds the app, pushes to ACR by digest, and rolls a new Container App revision.
  No Bicep involved.

.PARAMETER ResourceGroup
  Target resource group. Defaults to $env:RG.

.PARAMETER AppName
  Container App logical name. Defaults to $env:APP or 'api'.

.PARAMETER Tag
  Image tag. Defaults to $env:TAG, then to git short SHA, then to a UTC timestamp.

.PARAMETER Context
  Docker build context. Defaults to src/<AppName>.

.EXAMPLE
  $env:RG = 'rg-aca-demo'; ./scripts/deploy-app.ps1
#>

[CmdletBinding()]
param(
    [string]$ResourceGroup = $env:RG,
    [string]$AppName       = ($env:APP ?? 'api'),
    [string]$Tag           = $env:TAG,
    [string]$Context
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ResourceGroup)) {
    throw "ResourceGroup is required. Pass -ResourceGroup or set `$env:RG."
}

if ([string]::IsNullOrWhiteSpace($Context)) {
    $Context = "src/$AppName"
}

if ([string]::IsNullOrWhiteSpace($Tag)) {
    $sha = git rev-parse --short HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($sha)) {
        $Tag = $sha
    } else {
        $Tag = (Get-Date -AsUTC -Format 'yyyyMMdd-HHmmss')
    }
}

$acrServer = az containerapp show -g $ResourceGroup -n $AppName `
                --query "properties.configuration.registries[0].server" -o tsv 2>$null
if ([string]::IsNullOrWhiteSpace($acrServer)) {
    throw "Could not discover ACR from Container App $AppName. Run deploy-infra.ps1 first."
}
$acrName = $acrServer.Split('.')[0]

Write-Host "Building & pushing ${AppName}:$Tag to $acrName ..."
az acr build -r $acrName -t "${AppName}:$Tag" $Context | Out-Null
if ($LASTEXITCODE -ne 0) { throw "az acr build failed" }

$digest = az acr repository show -n $acrName --image "${AppName}:$Tag" --query "digest" -o tsv
if ([string]::IsNullOrWhiteSpace($digest)) { throw "Could not resolve image digest" }

$ref = "$acrServer/$AppName@$digest"
Write-Host "Image digest reference: $ref"

Write-Host "Rolling new revision ..."
az containerapp update `
    -g $ResourceGroup -n $AppName `
    --image $ref `
    --revision-suffix "sha-$Tag" `
    --output table
if ($LASTEXITCODE -ne 0) { throw "az containerapp update failed" }

$fqdn = az containerapp show -g $ResourceGroup -n $AppName `
            --query properties.configuration.ingress.fqdn -o tsv
Write-Host "App live at: https://$fqdn" -ForegroundColor Green
