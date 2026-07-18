[CmdletBinding()]
param(
    [string]$KubeContext,
    [string[]]$ExcludedNamespaces = @(
        "kube-system",
        "kube-public",
        "kube-node-lease",
        "gatekeeper-system"
    )
)

$ErrorActionPreference = "Stop"

function Test-Property {
    param(
        [object]$Object,
        [string]$Name
    )

    return $null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]
}

function Get-PodSpec {
    param([object]$Item)

    switch ($Item.kind) {
        "Pod" { return $Item.spec }
        "CronJob" { return $Item.spec.jobTemplate.spec.template.spec }
        default { return $Item.spec.template.spec }
    }
}

function Test-FixedImage {
    param([string]$Image)

    if ($Image -match '^.+@sha256:[0-9A-Fa-f]{64}$') {
        return $true
    }

    return $Image -match '^[^@]+:[^/:@]+$' -and $Image -notmatch '(?i):latest$'
}

function Add-Violation {
    param(
        [System.Collections.Generic.List[object]]$Violations,
        [object]$Item,
        [string]$ContainerType,
        [object]$Container,
        [string]$Rule
    )

    $Violations.Add([pscustomobject]@{
        Namespace = $Item.metadata.namespace
        Kind = $Item.kind
        Workload = $Item.metadata.name
        ContainerType = $ContainerType
        Container = $Container.name
        Rule = $Rule
    })
}

$kubectlArgs = @()
if ($KubeContext) {
    $kubectlArgs += @("--context", $KubeContext)
}
$kubectlArgs += @(
    "get",
    "pods,deployments.apps,statefulsets.apps,daemonsets.apps,replicasets.apps,replicationcontrollers,jobs.batch,cronjobs.batch",
    "--all-namespaces",
    "-o",
    "json"
)

$rawInventory = & kubectl @kubectlArgs
if ($LASTEXITCODE -ne 0) {
    throw "kubectl inventory failed with exit code $LASTEXITCODE"
}

$inventory = $rawInventory -join "`n" | ConvertFrom-Json -Depth 100
$violations = [System.Collections.Generic.List[object]]::new()
$checkedWorkloads = 0
$checkedContainers = 0

foreach ($item in $inventory.items) {
    if ($item.metadata.namespace -in $ExcludedNamespaces) {
        continue
    }

    $checkedWorkloads++
    $podSpec = Get-PodSpec -Item $item
    $containerGroups = @(
        @{ Type = "container"; Items = @($podSpec.containers); RequireResources = $true },
        @{ Type = "initContainer"; Items = @($podSpec.initContainers); RequireResources = $true },
        @{ Type = "ephemeralContainer"; Items = @($podSpec.ephemeralContainers); RequireResources = $false }
    )

    foreach ($group in $containerGroups) {
        foreach ($container in $group.Items) {
            if ($null -eq $container) {
                continue
            }

            $checkedContainers++
            $containerSecurity = $container.securityContext
            $podSecurity = $podSpec.securityContext

            $runAsNonRoot = if (Test-Property $containerSecurity "runAsNonRoot") {
                $containerSecurity.runAsNonRoot
            }
            elseif (Test-Property $podSecurity "runAsNonRoot") {
                $podSecurity.runAsNonRoot
            }
            else {
                $false
            }

            if ($runAsNonRoot -ne $true) {
                Add-Violation $violations $item $group.Type $container "effective runAsNonRoot is not true"
            }

            $runAsUser = if (Test-Property $containerSecurity "runAsUser") {
                $containerSecurity.runAsUser
            }
            elseif (Test-Property $podSecurity "runAsUser") {
                $podSecurity.runAsUser
            }
            else {
                $null
            }

            if ($runAsUser -eq 0) {
                Add-Violation $violations $item $group.Type $container "effective runAsUser is 0"
            }

            $drops = if (Test-Property $containerSecurity.capabilities "drop") {
                @($containerSecurity.capabilities.drop)
            }
            else {
                @()
            }
            if ($drops -notcontains "ALL") {
                Add-Violation $violations $item $group.Type $container "capabilities.drop does not contain ALL"
            }

            $adds = if (Test-Property $containerSecurity.capabilities "add") {
                @($containerSecurity.capabilities.add)
            }
            else {
                @()
            }
            if ($adds.Count -gt 0) {
                Add-Violation $violations $item $group.Type $container "capabilities.add is not empty"
            }

            if (-not (Test-FixedImage -Image $container.image)) {
                Add-Violation $violations $item $group.Type $container "image is latest, untagged, or has an invalid digest"
            }

            if ($group.RequireResources) {
                $resources = $container.resources
                $hasResources =
                    (Test-Property $resources "requests") -and
                    (Test-Property $resources.requests "cpu") -and
                    (Test-Property $resources.requests "memory") -and
                    (Test-Property $resources "limits") -and
                    (Test-Property $resources.limits "cpu") -and
                    (Test-Property $resources.limits "memory")

                if (-not $hasResources) {
                    Add-Violation $violations $item $group.Type $container "CPU/memory requests or limits are missing"
                }
            }
        }
    }
}

if ($violations.Count -gt 0) {
    $violations | Sort-Object Namespace, Kind, Workload, ContainerType, Container, Rule | Format-Table -AutoSize
    throw "Runtime-hardening inventory failed: $($violations.Count) violation(s) across $checkedWorkloads workload objects."
}

Write-Output "PASS runtime-hardening inventory: $checkedWorkloads workload objects and $checkedContainers containers checked; zero violations."
