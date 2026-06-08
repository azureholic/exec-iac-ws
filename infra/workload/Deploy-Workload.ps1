#requires -Version 7.0
<#
.SYNOPSIS
    Deploys the hotel-booking workload (compute, data, identity, observability)
    into the test or prod spoke.

.DESCRIPTION
    Wraps `az deployment group` to deploy infra/workload/main.bicep against the
    chosen workload resource group. The same Bicep template covers both
    environments; the -Environment switch selects which parameter file to use
    (workload.test.bicepparam vs workload.prod.bicepparam) and which RG to
    target. There are no environmentName-based if-branches in the template —
    every difference between test and prod is a parameter value.

    Runs preflight before every deployment, regardless of environment:

      1. Compiles main.bicep + the selected param file to catch syntax/lint issues.
      2. Reads the live container app images (if the env already exists) and
         passes them through as parameters so re-deploying does not revert the
         API or web revisions back to the placeholder image. Real image rollout
         is owned by Deploy-Images.ps1.
      3. Runs `az deployment group what-if` and prints the change set.
      4. Runs `az deployment group validate` to surface ARM-side errors
         (permissions, quota, AVM module shape, etc.).
      5. Prompts before calling `az deployment group create`. Pass -WhatIfOnly
         to stop after preflight.

    The script assumes the spoke (rg-hotel-<env> + vnet-hotel-<env> + the ACA
    and PE subnets) already exists — deploy it with infra/Deploy-Spoke.ps1
    -Environment <env> first.

    Requires PowerShell 7+, Azure CLI logged in (`az login`), and the correct
    subscription selected (`az account set --subscription <id>`).

.PARAMETER Environment
    Workload environment. test or prod. Defaults to test.

.PARAMETER ResourceGroupName
    Override the default RG name. If unset, defaults to rg-hotel-<Environment>.

.PARAMETER Location
    Azure region. Defaults to swedencentral.

.PARAMETER TemplateFile
    Bicep template. Defaults to ./main.bicep next to this script.

.PARAMETER ParameterFile
    Override the parameter file. If unset, defaults to ./workload.<Environment>.bicepparam.

.PARAMETER DeploymentName
    ARM deployment name. Defaults to workload-<Environment>-<timestamp>.

.PARAMETER WhatIfOnly
    Stop after preflight (what-if + validate). No resources are created or changed.

.EXAMPLE
    ./Deploy-Workload.ps1 -Environment test -WhatIfOnly
    Runs the full preflight against rg-hotel-test and prints the change set.

.EXAMPLE
    ./Deploy-Workload.ps1 -Environment prod
    Runs preflight, prompts, then deploys prod.
#>

[CmdletBinding()]
param(
    [ValidateSet('test', 'prod')]
    [string]$Environment = 'test',
    [string]$ResourceGroupName,
    [string]$Location = 'swedencentral',
    [string]$TemplateFile,
    [string]$ParameterFile,
    [string]$DeploymentName,
    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $TemplateFile)      { $TemplateFile      = Join-Path $scriptRoot 'main.bicep' }
if (-not $ParameterFile)     { $ParameterFile     = Join-Path $scriptRoot "workload.$Environment.bicepparam" }
if (-not $ResourceGroupName) { $ResourceGroupName = "rg-hotel-$Environment" }
if (-not $DeploymentName)    { $DeploymentName    = "workload-$Environment-$(Get-Date -Format 'yyyyMMddHHmmss')" }

if (-not (Test-Path $TemplateFile))  { throw "Template file not found: $TemplateFile" }
if (-not (Test-Path $ParameterFile)) { throw "Parameter file not found: $ParameterFile" }

Write-Host "Environment      : $Environment"        -ForegroundColor Cyan
Write-Host "Resource group   : $ResourceGroupName"  -ForegroundColor Cyan
Write-Host "Template file    : $TemplateFile"       -ForegroundColor Cyan
Write-Host "Parameter file   : $ParameterFile"      -ForegroundColor Cyan
Write-Host "Deployment name  : $DeploymentName"     -ForegroundColor Cyan
Write-Host ''

Write-Host 'Using subscription:' -ForegroundColor Cyan
az account show --query '{name:name, id:id, tenant:tenantId}' -o table

Write-Host "Ensuring resource group '$ResourceGroupName' exists in '$Location'..." -ForegroundColor Cyan
az group create --name $ResourceGroupName --location $Location --output none

Write-Host "Compiling Bicep ($TemplateFile)..." -ForegroundColor Cyan
az bicep build --file $TemplateFile --stdout | Out-Null
az bicep build-params --file $ParameterFile --stdout | Out-Null
Write-Host '  ...clean.' -ForegroundColor Green

# -----------------------------------------------------------------------------
# Discover live container app images so a re-deploy does not revert revisions
# back to the placeholder image (Deploy-Images.ps1 owns image rollout).
# Naming matches the CAF scheme baked into main.bicep:
#   ca-hotelapi-<env>-swc-001  /  ca-hotelweb-<env>-swc-001
# -----------------------------------------------------------------------------
$apiAppName = "ca-hotelapi-$Environment-swc-001"
$webAppName = "ca-hotelweb-$Environment-swc-001"

$liveApiImage = $null
$liveWebImage = $null
$existingRg = az group exists --name $ResourceGroupName | ConvertFrom-Json
if ($existingRg) {
    Write-Host 'Reading live container app images (if any)...' -ForegroundColor Cyan
    $liveApiImage = az containerapp show -g $ResourceGroupName -n $apiAppName --query 'properties.template.containers[0].image' -o tsv 2>$null
    if ($LASTEXITCODE -ne 0) { $liveApiImage = $null }
    $liveWebImage = az containerapp show -g $ResourceGroupName -n $webAppName --query 'properties.template.containers[0].image' -o tsv 2>$null
    if ($LASTEXITCODE -ne 0) { $liveWebImage = $null }
    if ($liveApiImage) { Write-Host "  api image : $liveApiImage" -ForegroundColor Yellow } else { Write-Host '  api image : (not deployed yet — will use param default)' -ForegroundColor Yellow }
    if ($liveWebImage) { Write-Host "  web image : $liveWebImage" -ForegroundColor Yellow } else { Write-Host '  web image : (not deployed yet — will use param default)' -ForegroundColor Yellow }
}

# Build the inline-override list. Strings are passed via --parameters key=value
# AFTER the .bicepparam file, which lets ARM override the file's value for just
# those keys.
$inlineParams = @()
if ($liveApiImage) { $inlineParams += "apiContainerImage=$liveApiImage" }
if ($liveWebImage) { $inlineParams += "webContainerImage=$liveWebImage" }

Write-Host "Running what-if against '$ResourceGroupName' ..." -ForegroundColor Cyan
$whatIfArgs = @(
    'deployment', 'group', 'what-if',
    '--resource-group', $ResourceGroupName,
    '--template-file', $TemplateFile,
    '--parameters', $ParameterFile
)
if ($inlineParams.Count -gt 0) {
    $whatIfArgs += '--parameters'
    $whatIfArgs += $inlineParams
}
az @whatIfArgs

Write-Host 'Running ARM validate (permission + schema check) ...' -ForegroundColor Cyan
$validateArgs = @(
    'deployment', 'group', 'validate',
    '--resource-group', $ResourceGroupName,
    '--name', "$DeploymentName-validate",
    '--template-file', $TemplateFile,
    '--parameters', $ParameterFile
)
if ($inlineParams.Count -gt 0) {
    $validateArgs += '--parameters'
    $validateArgs += $inlineParams
}
$validateJson = az @validateArgs --output json
$validate = $validateJson | ConvertFrom-Json
if ($validate.error) {
    Write-Error "Validation failed: $($validate.error | ConvertTo-Json -Depth 10)"
    exit 1
}
Write-Host "  ...validation passed (provisioningState=$($validate.properties.provisioningState))." -ForegroundColor Green

if ($WhatIfOnly) {
    Write-Host 'Preflight complete. -WhatIfOnly was specified — stopping before deployment.' -ForegroundColor Yellow
    exit 0
}

$answer = Read-Host "Proceed with deployment to '$ResourceGroupName' ($Environment)? [y/N]"
if ($answer -ne 'y' -and $answer -ne 'Y') {
    Write-Host 'Aborted by user.' -ForegroundColor Yellow
    exit 0
}

Write-Host "Deploying workload ($DeploymentName)..." -ForegroundColor Cyan
$createArgs = @(
    'deployment', 'group', 'create',
    '--resource-group', $ResourceGroupName,
    '--name', $DeploymentName,
    '--template-file', $TemplateFile,
    '--parameters', $ParameterFile
)
if ($inlineParams.Count -gt 0) {
    $createArgs += '--parameters'
    $createArgs += $inlineParams
}
$createArgs += '--output'
$createArgs += 'table'
az @createArgs

Write-Host 'Done.' -ForegroundColor Green
