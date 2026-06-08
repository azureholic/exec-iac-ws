#requires -Version 7.0
<#
.SYNOPSIS
    Deploys a workload spoke (resource group, VNet, bi-directional hub peering)
    for either the test or prod environment.

.DESCRIPTION
    Creates (or updates) the workload resource group and deploys spoke.bicep
    into it using the Azure CLI. The Bicep template uses the AVM
    virtual-network module to provision the spoke VNet and both sides of the
    hub peering in one shot. The -Environment switch chooses which parameter
    file to use and which RG to target — the template itself is the same for
    both environments (one Bicep, two parameter files).

    Run from PowerShell 7+ with az CLI already logged in (`az login`) and the
    correct subscription selected (`az account set`).

.PARAMETER Environment
    Workload environment. test or prod. Defaults to test.

.PARAMETER ResourceGroupName
    Override the default RG name. If unset, defaults to rg-hotel-<Environment>.

.PARAMETER Location
    Azure region. Defaults to swedencentral (matches the hub).

.PARAMETER DeploymentName
    ARM deployment name. Defaults to spoke-<Environment>-<timestamp>.

.EXAMPLE
    ./Deploy-Spoke.ps1 -Environment test
    Provisions / updates the test spoke and its peering.

.EXAMPLE
    ./Deploy-Spoke.ps1 -Environment prod
    Provisions / updates the prod spoke and its peering.
#>

[CmdletBinding()]
param(
    [ValidateSet('test', 'prod')]
    [string]$Environment = 'test',
    [string]$ResourceGroupName,
    [string]$Location = 'swedencentral',
    [string]$DeploymentName
)

$ErrorActionPreference = 'Stop'

if (-not $ResourceGroupName) { $ResourceGroupName = "rg-hotel-$Environment" }
if (-not $DeploymentName)    { $DeploymentName    = "spoke-$Environment-$(Get-Date -Format 'yyyyMMddHHmmss')" }

$scriptRoot    = Split-Path -Parent $MyInvocation.MyCommand.Path
$templateFile  = Join-Path $scriptRoot 'spoke.bicep'
$parameterFile = Join-Path $scriptRoot "spoke.$Environment.bicepparam"

if (-not (Test-Path $templateFile))  { throw "Template file not found: $templateFile" }
if (-not (Test-Path $parameterFile)) { throw "Parameter file not found: $parameterFile" }

Write-Host "Environment      : $Environment"        -ForegroundColor Cyan
Write-Host "Resource group   : $ResourceGroupName"  -ForegroundColor Cyan
Write-Host "Parameter file   : $parameterFile"      -ForegroundColor Cyan
Write-Host "Deployment name  : $DeploymentName"     -ForegroundColor Cyan
Write-Host ''

Write-Host 'Using subscription:' -ForegroundColor Cyan
az account show --query '{name:name, id:id}' -o table

Write-Host "Ensuring resource group '$ResourceGroupName' exists in '$Location'..." -ForegroundColor Cyan
az group create --name $ResourceGroupName --location $Location --output none

Write-Host "Deploying spoke ($DeploymentName)..." -ForegroundColor Cyan
az deployment group create `
    --resource-group $ResourceGroupName `
    --name $DeploymentName `
    --template-file $templateFile `
    --parameters $parameterFile `
    --output table

Write-Host 'Verifying peerings on both sides...' -ForegroundColor Cyan

$spokeVnetName = az deployment group show `
    --resource-group $ResourceGroupName `
    --name $DeploymentName `
    --query 'properties.outputs.spokeVnetName.value' -o tsv

Write-Host "Spoke ($spokeVnetName) peerings:" -ForegroundColor Yellow
az network vnet peering list `
    --resource-group $ResourceGroupName `
    --vnet-name $spokeVnetName `
    --query '[].{name:name, state:peeringState, remoteAddressSpace:remoteAddressSpace.addressPrefixes}' `
    -o table

Write-Host 'Hub (vnet-hub) peerings:' -ForegroundColor Yellow
az network vnet peering list `
    --resource-group rg-platform `
    --vnet-name vnet-hub `
    --query '[].{name:name, state:peeringState, remoteAddressSpace:remoteAddressSpace.addressPrefixes}' `
    -o table

Write-Host 'Done.' -ForegroundColor Green
