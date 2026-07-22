[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)][string]$KubeContext,
    [string]$Namespace = "kube-system",
    [string]$Deployment = "coredns",
    [int]$TimeoutSeconds = 300,
    [string]$EvidenceDirectory = "",
    [switch]$RequireReady,
    [switch]$CapacityApproved,
    [switch]$Execute
)

$ErrorActionPreference = "Stop"
if ($TimeoutSeconds -lt 30) { throw "TimeoutSeconds must be at least 30" }
if (-not $EvidenceDirectory) {
    $EvidenceDirectory = Join-Path $PSScriptRoot "..\docs\evidence\mandate-17\coredns-readiness"
}
New-Item -ItemType Directory -Force -Path $EvidenceDirectory | Out-Null

function Get-KubectlJson {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = kubectl --context $KubeContext @Arguments
    if ($LASTEXITCODE -ne 0) { throw "kubectl failed: $($Arguments -join ' ')" }
    return $output | ConvertFrom-Json
}

function Get-CoreDnsState {
    $deploymentData = Get-KubectlJson -Arguments @("-n", $Namespace, "get", "deployment", $Deployment, "-o", "json")
    $selector = @(
        $deploymentData.spec.selector.matchLabels.PSObject.Properties |
            Sort-Object Name |
            ForEach-Object { "$($_.Name)=$($_.Value)" }
    ) -join ","
    if (-not $selector) { throw "Deployment/$Deployment has no matchLabels selector" }

    $podData = Get-KubectlJson -Arguments @("-n", $Namespace, "get", "pods", "-l", $selector, "-o", "json")
    $nodeData = Get-KubectlJson -Arguments @("get", "nodes", "-o", "json")
    $nodes = @{}
    foreach ($node in $nodeData.items) { $nodes[$node.metadata.name] = $node }

    $placements = @($podData.items | ForEach-Object {
        $pod = $_
        $node = $nodes[$pod.spec.nodeName]
        $containers = @($pod.status.containerStatuses)
        [pscustomobject]@{
            pod = $pod.metadata.name
            node = $pod.spec.nodeName
            zone = $node.metadata.labels.'topology.kubernetes.io/zone'
            ready = ($containers.Count -gt 0 -and @($containers | Where-Object { -not $_.ready }).Count -eq 0)
            deleting = [bool]$pod.metadata.deletionTimestamp
            created = $pod.metadata.creationTimestamp
        }
    })
    $active = @($placements | Where-Object { -not $_.deleting })
    $desired = [int]$deploymentData.spec.replicas
    $available = [int]$deploymentData.status.availableReplicas
    $distinctNodes = @($active.node | Where-Object { $_ } | Sort-Object -Unique).Count
    $distinctZones = @($active.zone | Where-Object { $_ } | Sort-Object -Unique).Count
    $ready = (
        $desired -ge 2 -and
        $active.Count -eq $desired -and
        @($active | Where-Object { -not $_.ready }).Count -eq 0 -and
        $available -eq $desired -and
        $distinctNodes -ge 2 -and
        $distinctZones -ge 2
    )

    return [pscustomobject]@{
        timestamp = (Get-Date).ToUniversalTime().ToString("o")
        deployment = "$Namespace/$Deployment"
        desiredReplicas = $desired
        availableReplicas = $available
        distinctNodes = $distinctNodes
        distinctZones = $distinctZones
        readyForAzChaos = $ready
        placements = $placements
    }
}

function Write-State {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $State | ConvertTo-Json -Depth 10 |
        Out-File -Encoding utf8 (Join-Path $EvidenceDirectory $Name)
    $State.placements | Format-Table pod, ready, node, zone, deleting -AutoSize
    Write-Output (
        "CoreDNS ready={0}; replicas={1}/{2}; nodes={3}; zones={4}" -f
        $State.readyForAzChaos,
        $State.availableReplicas,
        $State.desiredReplicas,
        $State.distinctNodes,
        $State.distinctZones
    )
}

$before = Get-CoreDnsState
Write-State -State $before -Name "placement-before.json"
if ($before.readyForAzChaos) {
    Write-Output "CoreDNS already satisfies the two-node/two-zone readiness gate."
    return
}

if (-not $Execute -and -not $WhatIfPreference) {
    if ($RequireReady) { throw "CoreDNS is not ready for AZ chaos" }
    Write-Warning "Read-only preflight found CoreDNS placement drift. No Pod was changed."
    return
}
if ($Execute -and -not $CapacityApproved) {
    throw "Refusing CoreDNS rebalance until capacity is reviewed (-CapacityApproved)"
}
if ($before.desiredReplicas -lt 2 -or $before.availableReplicas -ne $before.desiredReplicas) {
    throw "Refusing rebalance unless every desired CoreDNS replica is available"
}
if (@($before.placements | Where-Object { $_.deleting -or -not $_.ready }).Count -gt 0) {
    throw "Refusing rebalance while a CoreDNS Pod is unready or terminating"
}

# Delete only the newest replica from the most crowded node. The script never
# retries automatically if the scheduler places the replacement incorrectly.
$candidate = $before.placements |
    Group-Object node |
    Sort-Object Count -Descending |
    Select-Object -First 1 -ExpandProperty Group |
    Sort-Object created -Descending |
    Select-Object -First 1
if (-not $candidate) { throw "No CoreDNS Pod is eligible for one-at-a-time rebalance" }

if (-not $PSCmdlet.ShouldProcess("$Namespace/pod/$($candidate.pod)", "delete one CoreDNS replica for scheduler rebalance")) {
    return
}
if (-not $Execute) { throw "Refusing live CoreDNS rebalance without -Execute" }

kubectl --context $KubeContext -n $Namespace delete pod $candidate.pod --wait=false
if ($LASTEXITCODE -ne 0) { throw "Failed to delete CoreDNS Pod $($candidate.pod)" }
kubectl --context $KubeContext -n $Namespace rollout status deployment $Deployment --timeout="${TimeoutSeconds}s"
if ($LASTEXITCODE -ne 0) { throw "CoreDNS rollout did not recover within ${TimeoutSeconds}s" }

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
do {
    $after = Get-CoreDnsState
    if ($after.readyForAzChaos) { break }
    Start-Sleep -Seconds 5
} while ((Get-Date) -lt $deadline)

Write-State -State $after -Name "placement-after.json"
if (-not $after.readyForAzChaos) {
    throw "CoreDNS recovered but is still not spread across two nodes and two zones; stop and review placement before any retry"
}
Write-Output "CoreDNS now satisfies the two-node/two-zone readiness gate."
