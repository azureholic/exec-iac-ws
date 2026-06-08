#requires -Version 7.0
<#
.SYNOPSIS
    Bootstraps GitHub Actions OIDC federation to Azure, per workload
    environment, end-to-end and idempotently. No app registrations, no client
    secrets, no portal clicks.

.DESCRIPTION
    Per environment (test, prod by default) this script:

      1. Creates (or reuses) a dedicated user-assigned managed identity in the
         workload resource group, named id-github-<WorkloadName>-<env>-<loc>-001.
      2. Assigns the deploy identity:
           - Owner on the workload RG
           - Network Contributor on the hub RG (needed because AVM's
             virtualNetwork module creates the remote peering via a nested
             deployment in the hub RG, which requires deployments/write
             at RG scope)
           - AcrPush on the workload container registry
           - (prod only) AcrPull on the *test* container registry so
             `az acr import` can copy the digest from test → prod
             without a rebuild (build-once-promote-everywhere).
         az role assignment create is naturally idempotent — re-running on the
         same scope+principal+role returns success without duplicating.
      3. Creates or updates a federated credential whose subject is exactly
           repo:<owner>/<repo>:environment:<env>
         Update is preferred over delete-then-create so the FC's object ID is
         preserved. The credential body is passed as JSON over stdin to avoid
         PowerShell quoting tricks on the subject string.
      4. Creates the matching GitHub Environment (gh api PUT). prod gets a
         required-reviewer protection rule; test stays unprotected.
      5. Publishes the four environment variables the workflows consume —
         AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID,
         AZURE_RESOURCE_GROUP — as gh variables (not secrets; they are not
         sensitive and may show up in logs).

    A second run is a clean no-op.

.PARAMETER WorkloadName
    Short workload name used in the deploy identity name and to derive the
    default workload RG (rg-<WorkloadName>-<env>). Defaults to hotel.

.PARAMETER Environment
    One or more environments to wire up. Defaults to test, prod.

.PARAMETER Location
    Azure region for the managed identity. Defaults to swedencentral.

.PARAMETER HubResourceGroup
    Resource group containing the hub VNet. Defaults to rg-platform.

.PARAMETER HubVnetName
    Hub VNet name (the resource scoped for Network Contributor). Defaults to
    vnet-hub.

.PARAMETER AcrResourceGroup
    Resource group containing the workload ACR. Defaults to the workload RG
    for the current environment.

.PARAMETER AcrName
    ACR name. If unset, the script looks for the single ACR in
    AcrResourceGroup and uses it.

.PARAMETER RepoOwner
    GitHub repo owner. If unset, inferred from gh repo view on the current
    working directory.

.PARAMETER RepoName
    GitHub repo name. If unset, inferred from gh repo view.

.PARAMETER ProdReviewerLogin
    GitHub login of the required reviewer on the prod environment. If unset,
    defaults to the authenticated gh user (gh api user). Can be a user or a
    team handle in the form org/team-slug.

.EXAMPLE
    ./Bootstrap-GitHubOidc.ps1
    Wires up the test and prod deploy identities with defaults inferred from
    the current az / gh context.

.EXAMPLE
    ./Bootstrap-GitHubOidc.ps1 -Environment test
    Only re-bootstraps the test environment.
#>

[CmdletBinding()]
param(
    [string]$WorkloadName = 'hotel',

    [ValidateSet('test', 'prod')]
    [string[]]$Environment = @('test', 'prod'),

    [string]$Location = 'swedencentral',

    [string]$HubResourceGroup = 'rg-platform',
    [string]$HubVnetName      = 'vnet-hub',

    [string]$AcrResourceGroup,
    [string]$AcrName,

    [string]$RepoOwner,
    [string]$RepoName,

    [string]$ProdReviewerLogin
)

$ErrorActionPreference = 'Stop'

function Invoke-AzJson {
    param([Parameter(Mandatory)][string[]]$Args)
    $raw = & az @Args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az $($Args -join ' ') failed: $raw" }
    if (-not $raw) { return $null }
    return ($raw | ConvertFrom-Json -Depth 20)
}

function Invoke-GhJson {
    param([Parameter(Mandatory)][string[]]$Args)
    $raw = & gh @Args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "gh $($Args -join ' ') failed: $raw" }
    if (-not $raw) { return $null }
    return ($raw | ConvertFrom-Json -Depth 20)
}

# ---------- Resolve subscription / tenant ----------

$account = Invoke-AzJson @('account', 'show', '-o', 'json')
$subscriptionId = $account.id
$tenantId       = $account.tenantId
Write-Host "Subscription : $($account.name) ($subscriptionId)" -ForegroundColor Cyan
Write-Host "Tenant       : $tenantId" -ForegroundColor Cyan

# ---------- Resolve repo owner / name ----------

if (-not $RepoOwner -or -not $RepoName) {
    $repo = Invoke-GhJson @('repo', 'view', '--json', 'owner,name')
    if (-not $RepoOwner) { $RepoOwner = $repo.owner.login }
    if (-not $RepoName)  { $RepoName  = $repo.name }
}
$repoFull = "$RepoOwner/$RepoName"
Write-Host "Repository   : $repoFull" -ForegroundColor Cyan

# ---------- Resolve reviewer for prod ----------

if (-not $ProdReviewerLogin) {
    $me = Invoke-GhJson @('api', 'user')
    $ProdReviewerLogin = $me.login
}
Write-Host "Prod reviewer: $ProdReviewerLogin" -ForegroundColor Cyan

# Resolve reviewer (user or team) to the numeric id required by the protection-rule API.
function Resolve-Reviewer {
    param([Parameter(Mandatory)][string]$Login)

    if ($Login -match '^(?<org>[^/]+)/(?<team>[^/]+)$') {
        $team = Invoke-GhJson @('api', "orgs/$($Matches.org)/teams/$($Matches.team)")
        return [pscustomobject]@{ Type = 'Team'; Id = $team.id }
    }

    $user = Invoke-GhJson @('api', "users/$Login")
    return [pscustomobject]@{ Type = 'User'; Id = $user.id }
}

$reviewer = Resolve-Reviewer -Login $ProdReviewerLogin
Write-Host "Reviewer id  : $($reviewer.Type) $($reviewer.Id)" -ForegroundColor Cyan
Write-Host ''

# ---------- Per-environment loop ----------

foreach ($env in $Environment) {
    Write-Host "=== Environment: $env ===" -ForegroundColor Green

    $workloadRg = "rg-$WorkloadName-$env"
    $rgScope    = "/subscriptions/$subscriptionId/resourceGroups/$workloadRg"

    # Resolve ACR (lookup if not supplied). Use loop-locals with distinct
    # names from the script parameters — PowerShell variable scope is
    # case-insensitive, so $acrName and $AcrName are the same slot.
    $resolvedAcrRg = if ($AcrResourceGroup) { $AcrResourceGroup } else { $workloadRg }
    $resolvedAcrName = $AcrName
    if (-not $resolvedAcrName) {
        $acrList = Invoke-AzJson @('acr', 'list', '-g', $resolvedAcrRg, '-o', 'json')
        if (-not $acrList -or $acrList.Count -eq 0) {
            throw "No ACR found in resource group '$resolvedAcrRg' for environment '$env'."
        }
        if ($acrList.Count -gt 1) {
            throw "Multiple ACRs found in '$resolvedAcrRg'. Pass -AcrName explicitly."
        }
        $resolvedAcrName = $acrList[0].name
    }
    $acrId = (Invoke-AzJson @('acr', 'show', '-n', $resolvedAcrName, '-g', $resolvedAcrRg, '--query', 'id', '-o', 'json'))

    # Resolve hub vnet + hub RG resource ids. Network Contributor is scoped to
    # the hub RG (not just the vnet) because the AVM virtualNetwork module
    # creates the *remote* peering through a nested deployment in the hub RG,
    # which needs Microsoft.Resources/deployments/write at RG scope.
    $hubVnetId = (Invoke-AzJson @('network', 'vnet', 'show', '-g', $HubResourceGroup, '-n', $HubVnetName, '--query', 'id', '-o', 'json'))
    $hubRgId   = (Invoke-AzJson @('group',   'show', '-n', $HubResourceGroup, '--query', 'id', '-o', 'json'))

    Write-Host "  Workload RG  : $workloadRg"
    Write-Host "  Hub RG       : $hubRgId"
    Write-Host "  Hub VNet     : $hubVnetId"
    Write-Host "  ACR          : $resolvedAcrName ($resolvedAcrRg)"

    # 1. Managed identity ------------------------------------------------------
    $identityName = "id-github-$WorkloadName-$env-$Location-001"
    Write-Host "  - identity   : $identityName"

    $existingIdentity = & az identity show -n $identityName -g $workloadRg -o json 2>$null
    if ($LASTEXITCODE -eq 0 -and $existingIdentity) {
        $identity = $existingIdentity | ConvertFrom-Json
    }
    else {
        $identity = Invoke-AzJson @('identity', 'create', '-n', $identityName, '-g', $workloadRg, '-l', $Location, '-o', 'json')
    }
    $principalId = $identity.principalId
    $clientId    = $identity.clientId
    Write-Host "    principalId: $principalId"
    Write-Host "    clientId   : $clientId"

    # MI principalId takes a moment to propagate to AAD on first create. Poll
    # so the first role assignment doesn't race ahead of the principal.
    for ($i = 0; $i -lt 30; $i++) {
        & az ad sp show --id $principalId -o none 2>$null
        if ($LASTEXITCODE -eq 0) { break }
        Start-Sleep -Seconds 2
    }

    # 2. Role assignments ------------------------------------------------------
    $roleAssignments = @(
        @{ Role = 'Owner';               Scope = $rgScope; Label = "Owner on $workloadRg" }
        @{ Role = 'Network Contributor'; Scope = $hubRgId; Label = "Network Contributor on $HubResourceGroup" }
        @{ Role = 'AcrPush';             Scope = $acrId;   Label = "AcrPush on $resolvedAcrName" }
    )
    foreach ($ra in $roleAssignments) {
        Write-Host "  - role       : $($ra.Label)"
        & az role assignment create `
            --assignee-object-id $principalId `
            --assignee-principal-type ServicePrincipal `
            --role $ra.Role `
            --scope $ra.Scope `
            --output none 2>&1 | Out-Null
        # az returns non-zero when the assignment already exists; that's the
        # idempotent path. Re-check by listing.
        $existing = Invoke-AzJson @(
            'role', 'assignment', 'list',
            '--assignee', $principalId,
            '--role', $ra.Role,
            '--scope', $ra.Scope,
            '-o', 'json'
        )
        if (-not $existing -or $existing.Count -eq 0) {
            throw "Failed to ensure role assignment '$($ra.Role)' on $($ra.Scope) for $principalId."
        }
    }

    # 2b. Cross-env AcrPull on the test ACR for the prod identity ------------
    # `az acr import` (build-once-promote-everywhere) is run by the prod
    # identity but pulls the manifest from the *test* registry. Without
    # AcrPull on the source the import fails with HTTP 401 UNAUTHORIZED.
    if ($env -eq 'prod') {
        $testWorkloadRg = "rg-$WorkloadName-test"
        $testAcrList = & az acr list -g $testWorkloadRg -o json 2>$null | ConvertFrom-Json
        if ($testAcrList -and $testAcrList.Count -ge 1) {
            $testAcrId = $testAcrList[0].id
            Write-Host "  - role       : AcrPull on $($testAcrList[0].name) (test ACR, import source)"
            & az role assignment create `
                --assignee-object-id $principalId `
                --assignee-principal-type ServicePrincipal `
                --role AcrPull `
                --scope $testAcrId `
                --output none 2>&1 | Out-Null
            $existingPull = Invoke-AzJson @(
                'role', 'assignment', 'list',
                '--assignee', $principalId,
                '--role', 'AcrPull',
                '--scope', $testAcrId,
                '-o', 'json'
            )
            if (-not $existingPull -or $existingPull.Count -eq 0) {
                throw "Failed to ensure AcrPull on test ACR ($testAcrId) for $principalId."
            }
        }
        else {
            Write-Host "  - role       : (skipped) no test ACR in $testWorkloadRg yet; re-run bootstrap after test is deployed." -ForegroundColor Yellow
        }
    }

    # 3. Federated credential --------------------------------------------------
    # Subject is built from variables, never hand-typed — one wrong character
    # surfaces only inside the workflow run as AADSTS70021. Update over delete
    # so the FC's object ID survives a re-run.
    $fcName    = "gh-$WorkloadName-$env"
    $fcSubject = "repo:$repoFull`:environment:$env"
    Write-Host "  - fed cred   : $fcName"
    Write-Host "    subject    : $fcSubject"

    $existingFc = & az identity federated-credential show `
        --identity-name $identityName `
        --resource-group $workloadRg `
        --name $fcName -o json 2>$null
    $fcVerb = if ($LASTEXITCODE -eq 0 -and $existingFc) { 'update' } else { 'create' }

    & az identity federated-credential $fcVerb `
        --identity-name $identityName `
        --resource-group $workloadRg `
        --name $fcName `
        --issuer 'https://token.actions.githubusercontent.com' `
        --subject $fcSubject `
        --audiences 'api://AzureADTokenExchange' `
        --output none
    if ($LASTEXITCODE -ne 0) {
        throw "Federated credential $fcVerb failed for $fcName."
    }

    # 4. GitHub Environment ----------------------------------------------------
    Write-Host "  - gh env     : $env"

    $envBody = [ordered]@{}
    if ($env -eq 'prod') {
        $envBody.wait_timer = 0
        $envBody.reviewers = @(@{ type = $reviewer.Type; id = $reviewer.Id })
        $envBody.deployment_branch_policy = $null
    }
    else {
        # No protection rules. Explicit nulls ensure a re-run wipes any drift.
        $envBody.wait_timer = 0
        $envBody.reviewers  = @()
        $envBody.deployment_branch_policy = $null
    }
    $envBodyJson = $envBody | ConvertTo-Json -Compress -Depth 5

    $envBodyJson | & gh api `
        --method PUT `
        -H 'Accept: application/vnd.github+json' `
        "repos/$repoFull/environments/$env" `
        --input - `
        --silent
    if ($LASTEXITCODE -ne 0) { throw "Failed to upsert GitHub environment '$env'." }

    # 5. GitHub environment variables -----------------------------------------
    $vars = [ordered]@{
        AZURE_CLIENT_ID       = $clientId
        AZURE_TENANT_ID       = $tenantId
        AZURE_SUBSCRIPTION_ID = $subscriptionId
        AZURE_RESOURCE_GROUP  = $workloadRg
    }
    foreach ($name in $vars.Keys) {
        Write-Host "  - var        : $name"
        & gh variable set $name `
            --env $env `
            --repo $repoFull `
            --body $vars[$name] | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Failed to set $name on env '$env'." }
    }

    Write-Host ''
}

Write-Host '=== Verification ===' -ForegroundColor Green
foreach ($env in $Environment) {
    $workloadRg   = "rg-$WorkloadName-$env"
    $identityName = "id-github-$WorkloadName-$env-$Location-001"

    Write-Host ""
    Write-Host "[$env] federated credentials on $identityName" -ForegroundColor Yellow
    az identity federated-credential list `
        --identity-name $identityName `
        --resource-group $workloadRg `
        --query '[].{name:name, subject:subject, issuer:issuer}' -o table

    Write-Host "[$env] environment variables" -ForegroundColor Yellow
    gh variable list --env $env --repo $repoFull

    Write-Host "[$env] protection rules" -ForegroundColor Yellow
    gh api "repos/$repoFull/environments/$env" `
        --jq '{name:.name, protection_rules:[.protection_rules[]|{type:.type, reviewers:(.reviewers|length // 0), wait_timer:(.wait_timer // 0)}]}'
}

Write-Host ''
Write-Host 'Done. Re-running this script is a clean no-op.' -ForegroundColor Green
