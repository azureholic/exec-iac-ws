<#
.SYNOPSIS
    Builds the StayBright container images in ACR and rolls them out to the
    workload's container apps.

.DESCRIPTION
    Reads the latest successful workload deployment outputs from the spoke
    resource group (no hard-coded resource names), computes the short Git
    SHA, builds the .NET API and the React/nginx frontend with `az acr
    build` (server-side, so no local Docker daemon is required), tags each
    image with `:latest` and `:<sha>`, and updates each container app to
    the SHA-tagged image.

    Idempotent: re-running with the same Git SHA produces the same image
    tag, so `az containerapp update` does not roll a new revision.

.PARAMETER ResourceGroupName
    The spoke resource group that holds the workload deployment.

.PARAMETER DeploymentName
    Optional explicit deployment name. When omitted, the script picks the
    most recent successful deployment in the resource group.

.PARAMETER ImageTag
    Optional override for the immutable image tag (defaults to the short
    Git SHA of the current HEAD).

.EXAMPLE
    ./Deploy-Images.ps1 -ResourceGroupName rg-hotel-test

.EXAMPLE
    # Re-deploy when the Dockerfile changed but the Git SHA didn't.
    ./Deploy-Images.ps1 -ResourceGroupName rg-hotel-test -Force
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$DeploymentName,

    [Parameter(Mandatory = $false)]
    [string]$ImageTag,

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$InformationPreference  = 'Continue'

# Force UTF-8 + disable colour so the az CLI's build-log streamer doesn't
# crash on non-ASCII glyphs (e.g. vite's '✓') under Windows cp1252.
$env:PYTHONIOENCODING = 'utf-8'
$env:NO_COLOR         = '1'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ---------------------------------------------------------------------------
# Locate repo root + service folders (relative to this script).
# ---------------------------------------------------------------------------
$repoRoot     = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$backendPath  = Join-Path $repoRoot 'workload-app\backend\HotelBooking.Api'
$frontendPath = Join-Path $repoRoot 'workload-app\frontend'

foreach ($p in @($backendPath, $frontendPath)) {
    if (-not (Test-Path (Join-Path $p 'Dockerfile'))) {
        throw "Dockerfile not found at '$p'."
    }
}

# ---------------------------------------------------------------------------
# Resolve image tag: explicit > git short SHA.
# ---------------------------------------------------------------------------
if (-not $ImageTag) {
    Push-Location $repoRoot
    try {
        $ImageTag = (& git rev-parse --short HEAD 2>$null).Trim()
    } finally {
        Pop-Location
    }
    if (-not $ImageTag) {
        throw "Could not derive an image tag from git. Pass -ImageTag explicitly."
    }
}
Write-Information "Image tag: $ImageTag"

# ---------------------------------------------------------------------------
# Pick the deployment to read outputs from.
# ---------------------------------------------------------------------------
if (-not $DeploymentName) {
    Write-Information "Resolving latest successful deployment in '$ResourceGroupName'..."
    $DeploymentName = az deployment group list `
        --resource-group $ResourceGroupName `
        --query "sort_by([?properties.provisioningState=='Succeeded'], &properties.timestamp)[-1].name" `
        --output tsv
    if (-not $DeploymentName) {
        throw "No succeeded deployments found in resource group '$ResourceGroupName'."
    }
}
Write-Information "Using deployment: $DeploymentName"

# ---------------------------------------------------------------------------
# Pull the outputs we need (fail loud if any are missing).
# ---------------------------------------------------------------------------
$outputsJson = az deployment group show `
    --resource-group $ResourceGroupName `
    --name $DeploymentName `
    --query properties.outputs `
    --output json
if ($LASTEXITCODE -ne 0 -or -not $outputsJson) {
    throw "Failed to read outputs from deployment '$DeploymentName'."
}
$outputs = $outputsJson | ConvertFrom-Json

function Get-OutputValue {
    param([Parameter(Mandatory)][string]$Name)
    $prop = $outputs.PSObject.Properties[$Name]
    if (-not $prop -or -not $prop.Value -or -not $prop.Value.value) {
        throw "Deployment output '$Name' is missing."
    }
    return $prop.Value.value
}

$registryName    = Get-OutputValue 'containerRegistryName'
$registryServer  = Get-OutputValue 'containerRegistryLoginServer'
$apiAppName      = Get-OutputValue 'apiContainerAppName'
$webAppName      = Get-OutputValue 'webContainerAppName'

Write-Information "Registry        : $registryServer ($registryName)"
Write-Information "API app         : $apiAppName"
Write-Information "Web app         : $webAppName"

# ---------------------------------------------------------------------------
# Image coordinates.
# ---------------------------------------------------------------------------
$apiRepo  = 'hotelapi'
$webRepo  = 'hotelweb'
$apiImage = "$registryServer/${apiRepo}:$ImageTag"
$webImage = "$registryServer/${webRepo}:$ImageTag"

# ---------------------------------------------------------------------------
# Build both images server-side in ACR. `--image` may be passed twice to
# tag the same artifact with `:<sha>` AND `:latest`.
# ---------------------------------------------------------------------------
function Invoke-AcrBuild {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$ContextPath,
        [Parameter(Mandatory)][string]$DockerfilePath,
        [Parameter(Mandatory)][string]$Tag
    )
    Write-Information ""
    Write-Information "=== az acr build: ${Repo}:${Tag} ==="
    az acr build `
        --registry $registryName `
        --image "${Repo}:${Tag}" `
        --image "${Repo}:latest" `
        --file $DockerfilePath `
        $ContextPath
    $buildExit = $LASTEXITCODE
    if ($buildExit -ne 0) {
        # The local CLI log streamer crashes on non-ASCII glyphs (e.g. vite's
        # '✓') under Windows cp1252 even when the server-side build succeeds.
        # Verify via the ACR task-run feed; if the most-recent run for this
        # repo+tag is Succeeded, the image is in the registry and we continue.
        Write-Warning "az acr build exited $buildExit; verifying server-side build status..."
        $runStatus = az acr task list-runs `
            --registry $registryName `
            --top 10 `
            --query "[?outputImages[?repository=='${Repo}' && tag=='${Tag}']] | [0].status" `
            --output tsv
        if ($runStatus -ne 'Succeeded') {
            throw "az acr build failed for ${Repo}:${Tag} (latest matching run status: '${runStatus}')."
        }
        Write-Warning "Server-side ACR run reports Succeeded — local CLI crash is cosmetic; continuing."
    }
}

Invoke-AcrBuild -Repo $apiRepo `
    -ContextPath $backendPath `
    -DockerfilePath (Join-Path $backendPath 'Dockerfile') `
    -Tag $ImageTag

Invoke-AcrBuild -Repo $webRepo `
    -ContextPath $frontendPath `
    -DockerfilePath (Join-Path $frontendPath 'Dockerfile') `
    -Tag $ImageTag

# ---------------------------------------------------------------------------
# Make sure the API container app's ingress target port matches the .NET
# runtime (8080). Idempotent: az containerapp ingress update is a no-op
# when the port is already correct.
# ---------------------------------------------------------------------------
$apiIngress = az containerapp show `
    --resource-group $ResourceGroupName `
    --name $apiAppName `
    --query '{port:properties.configuration.ingress.targetPort, insecure:properties.configuration.ingress.allowInsecure}' `
    --output json | ConvertFrom-Json
if ($apiIngress.port -ne 8080 -or -not $apiIngress.insecure) {
    Write-Information ""
    Write-Information "API ingress port=$($apiIngress.port) allowInsecure=$($apiIngress.insecure); aligning to 8080 + allow-insecure..."
    # allow-insecure is required because nginx in the web container app talks
    # to the API over plain HTTP on the in-env FQDN. The internal-only ingress
    # otherwise 301-redirects HTTP to HTTPS, which the reverse proxy can't follow.
    az containerapp ingress update `
        --resource-group $ResourceGroupName `
        --name $apiAppName `
        --target-port 8080 `
        --allow-insecure `
        --output none
    if ($LASTEXITCODE -ne 0) { throw "Failed to update API ingress." }
} else {
    Write-Information "API ingress already 8080 + allow-insecure (skip)."
}

# ---------------------------------------------------------------------------
# Roll out each app to the new image. `az containerapp update --image`
# only creates a new revision when the image string actually changes,
# so re-running with the same SHA is a no-op.
# ---------------------------------------------------------------------------
function Update-AppImage {
    param(
        [Parameter(Mandatory)][string]$AppName,
        [Parameter(Mandatory)][string]$NewImage,
        [switch]$Force
    )
    $currentImage = az containerapp show `
        --resource-group $ResourceGroupName `
        --name $AppName `
        --query 'properties.template.containers[0].image' `
        --output tsv
    if ($currentImage -eq $NewImage -and -not $Force) {
        Write-Information "$AppName already on $NewImage (skip)."
        return
    }
    Write-Information ""
    if ($Force) {
        # `-Force` is used to roll out a same-tag rebuild (e.g. Dockerfile
        # changed but Git SHA didn't). A revision-suffix forces a new revision
        # so the platform picks up the new image digest.
        $suffix = "r$(Get-Date -Format 'yyMMddHHmmss')"
        Write-Information "=== az containerapp update: $AppName -> $NewImage (force, suffix=$suffix) ==="
        az containerapp update `
            --resource-group $ResourceGroupName `
            --name $AppName `
            --image $NewImage `
            --revision-suffix $suffix `
            --output none
    } else {
        Write-Information "=== az containerapp update: $AppName -> $NewImage ==="
        az containerapp update `
            --resource-group $ResourceGroupName `
            --name $AppName `
            --image $NewImage `
            --output none
    }
    if ($LASTEXITCODE -ne 0) { throw "Failed to update $AppName." }
}

Update-AppImage -AppName $apiAppName -NewImage $apiImage -Force:$Force
Update-AppImage -AppName $webAppName -NewImage $webImage -Force:$Force

Write-Information ""
Write-Information "Done. Tag '$ImageTag' rolled out to '$apiAppName' and '$webAppName'."
