[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)][string]$KubeContext,
    [Parameter(Mandatory = $true)][string]$Zone,
    [string]$Namespace = "techx-corp-prod",
    [int]$HoldSeconds = 300,
    [string]$EvidenceDirectory = "",
    [switch]$CapacityApproved,
    [switch]$Execute
)

$ErrorActionPreference = "Stop"
if (-not $Execute) { throw "Refusing live AZ chaos without -Execute" }
if (-not $CapacityApproved) { throw "Refusing AZ chaos until surviving-zone capacity is reviewed (-CapacityApproved)" }
$targetWorkloads = @(
    "ad", "cart", "checkout", "currency", "email", "frontend",
    "frontend-proxy", "image-provider", "payment", "product-catalog",
    "product-reviews", "quote", "recommendation", "shipping"
)
if (-not $EvidenceDirectory) {
    $EvidenceDirectory = Join-Path $PSScriptRoot "..\docs\evidence\mandate-17\az-$Zone"
}
New-Item -ItemType Directory -Force -Path $EvidenceDirectory | Out-Null

$nodeData = kubectl --context $KubeContext get nodes -o json | ConvertFrom-Json
$zoneNodes = @($nodeData.items | Where-Object { $_.metadata.labels.'topology.kubernetes.io/zone' -eq $Zone })
$otherNodes = @($nodeData.items | Where-Object {
    $_.metadata.labels.'topology.kubernetes.io/zone' -ne $Zone -and
    ($_.status.conditions | Where-Object { $_.type -eq "Ready" -and $_.status -eq "True" })
})
if ($zoneNodes.Count -eq 0) { throw "No nodes found in zone $Zone" }
if ($otherNodes.Count -eq 0) { throw "No recovery nodes remain outside zone $Zone" }
$nodeNames = @($zoneNodes.metadata.name)

$nodeData | ConvertTo-Json -Depth 20 | Out-File -Encoding utf8 (Join-Path $EvidenceDirectory "nodes-before.json")
kubectl --context $KubeContext top nodes 2>&1 |
    Out-File -Encoding utf8 (Join-Path $EvidenceDirectory "node-usage-before.txt")
kubectl --context $KubeContext -n $Namespace get pods -o wide |
    Out-File -Encoding utf8 (Join-Path $EvidenceDirectory "pods-before.txt")

$cordoned = @()
try {
    foreach ($node in $nodeNames) {
        if ($PSCmdlet.ShouldProcess($node, "cordon for AZ chaos")) {
            kubectl --context $KubeContext cordon $node
            if ($LASTEXITCODE -ne 0) { throw "Failed to cordon $node" }
            $cordoned += $node
        }
    }

    $podData = kubectl --context $KubeContext -n $Namespace get pods -o json | ConvertFrom-Json
    $podNames = @($podData.items | Where-Object {
        $_.spec.nodeName -in $nodeNames -and
        $_.metadata.ownerReferences.kind -contains "ReplicaSet" -and
        $_.metadata.labels.'opentelemetry.io/name' -in $targetWorkloads
    } | ForEach-Object { $_.metadata.name })
    if ($podNames.Count -eq 0) { throw "No Deployment-owned application pods found in zone $Zone" }

    if ($PSCmdlet.ShouldProcess(($podNames -join ','), "delete application pods simultaneously")) {
        kubectl --context $KubeContext -n $Namespace delete pod @podNames --wait=false
        if ($LASTEXITCODE -ne 0) { throw "Failed to delete AZ application pods" }
    }

    Start-Sleep -Seconds $HoldSeconds
    kubectl --context $KubeContext -n $Namespace get pods -o wide |
        Out-File -Encoding utf8 (Join-Path $EvidenceDirectory "pods-fault-window.txt")
}
finally {
    foreach ($node in $cordoned) {
        kubectl --context $KubeContext uncordon $node
    }
    kubectl --context $KubeContext -n $Namespace get pods -o wide |
        Out-File -Encoding utf8 (Join-Path $EvidenceDirectory "pods-after-restore.txt")
}
