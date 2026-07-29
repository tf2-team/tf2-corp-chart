[CmdletBinding()]
param(
    [ValidateSet("Measure", "GenerateConfiguration")][string]$Mode = "Measure",
    [Parameter(Mandatory)][ValidateSet("1a-to-1b", "1b-to-1a")][string]$Direction,
    [Parameter(Mandatory)][ValidatePattern("^[a-z0-9][a-z0-9-]{5,62}$")][string]$RunId,
    [Parameter(Mandatory)][ValidatePattern("^[0-9A-Za-z._/-]{7,128}$")][string]$SourceRevision,
    [ValidatePattern("^[0-9A-Fa-f]{40}$")][string]$DeployedRevision = "",
    [string]$Namespace = "techx-corp-prod",
    [string]$BaselinePath = "",
    [string]$GeneratedValuesPath = "",
    [string]$EvidencePath = "",
    [ValidateRange(300,300)][int]$SoakSeconds = 300,
    [ValidateRange(30,30)][int]$SampleIntervalSeconds = 30
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot "mandate21-evidence.psm1") -Force
$zones = if ($Direction -eq "1a-to-1b") { @("us-east-1a", "us-east-1b") } else { @("us-east-1b", "us-east-1a") }
$lostAz, $survivingAz = $zones
if ([string]::IsNullOrWhiteSpace($BaselinePath)) { $BaselinePath = Join-Path $PSScriptRoot "../evidence/mandate21/capacity-$Direction-baseline.json" }
if ([string]::IsNullOrWhiteSpace($GeneratedValuesPath)) { $GeneratedValuesPath = Join-Path $PSScriptRoot "../evidence/mandate21/values-capacity-probe-$Direction-enable.yaml" }
if ([string]::IsNullOrWhiteSpace($EvidencePath)) { $EvidencePath = Join-Path $PSScriptRoot "../evidence/mandate21/capacity-$Direction-evidence.json" }

function Invoke-KubeJson {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $output = & kubectl @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "kubectl read failed: $($Arguments -join ' ')" }
    try { return (($output -join "`n") | ConvertFrom-Json -Depth 100) }
    catch { throw "kubectl returned invalid JSON." }
}
function Convert-CpuMilli([string]$Value) {
    if ($Value -match '^(\d+)m$') { return [int64]$Matches[1] }
    if ($Value -match '^\d+(\.\d+)?$') { return [int64]([math]::Ceiling([double]$Value * 1000)) }
    throw "Unsupported CPU quantity."
}
function Convert-MemoryBytes([string]$Value) {
    if ($Value -match '^(\d+)(Ki|Mi|Gi)$') {
        $factor = @{ Ki = 1KB; Mi = 1MB; Gi = 1GB }[$Matches[2]]
        return [int64]$Matches[1] * [int64]$factor
    }
    if ($Value -match '^\d+$') { return [int64]$Value }
    throw "Unsupported memory quantity."
}
function Test-ReadyCondition($Conditions) {
    return @($Conditions | Where-Object { $_.type -eq "Ready" -and $_.status -eq "True" }).Count -eq 1
}
function Get-NodeClaimEvidence {
    $claims = Invoke-KubeJson @("get", "nodeclaims", "-o", "json")
    return @($claims.items | ForEach-Object { [pscustomobject]@{ name = $_.metadata.name; uid = $_.metadata.uid; createdAt = $_.metadata.creationTimestamp; availabilityZone = $_.metadata.labels.'topology.kubernetes.io/zone'; nodeName = $_.status.nodeName; ready = Test-ReadyCondition $_.status.conditions } })
}
function Ensure-Parent([string]$Path) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
}

if ($Mode -eq "GenerateConfiguration") {
    $nodes = Invoke-KubeJson @("get", "nodes", "-o", "json")
    $lostNodes = @($nodes.items | Where-Object { $_.metadata.labels.'topology.kubernetes.io/zone' -eq $lostAz -and (Test-ReadyCondition $_.status.conditions) })
    if ($lostNodes.Count -eq 0) { throw "No Ready nodes found in lost AZ $lostAz." }
    $lostNames = @($lostNodes | ForEach-Object { $_.metadata.name })
    $pods = Invoke-KubeJson @("get", "pods", "-A", "-o", "json")
    $lostPods = @($pods.items | Where-Object { $lostNames -contains $_.spec.nodeName -and $_.status.phase -eq "Running" })
    if ($lostPods.Count -eq 0) { throw "No Running pod load found in lost AZ $lostAz." }
    [int64]$cpu = 0; [int64]$memory = 0
    foreach ($pod in $lostPods) { foreach ($container in @($pod.spec.containers)) { $requests = $container.resources.requests; if ($null -ne $requests.cpu) { $cpu += Convert-CpuMilli ([string]$requests.cpu) }; if ($null -ne $requests.memory) { $memory += Convert-MemoryBytes ([string]$requests.memory) } } }
    $requestedCpu = [int64][math]::Ceiling($cpu * 1.2)
    $requestedMemory = [int64][math]::Ceiling($memory * 1.2)
    $replicas = [math]::Max(2, $lostPods.Count)
    $cpuPerPod = [int64][math]::Ceiling($requestedCpu / $replicas)
    $memoryMiPerPod = [int64][math]::Ceiling(($requestedMemory / $replicas) / 1MB)
    $requestedMemory = $memoryMiPerPod * $replicas * 1MB
    $baselineAt = (Get-Date).ToUniversalTime()
    $baseline = [ordered]@{ schemaVersion = 2; runId = $RunId; evidenceId = "$RunId-capacity"; sourceRevision = $SourceRevision; direction = $Direction; lostAz = $lostAz; survivingAz = $survivingAz; baselineAt = $baselineAt.ToString("o"); baselineNodeClaims = @(Get-NodeClaimEvidence); lostLoad = [ordered]@{ pods = $lostPods.Count; cpuMilli = $cpu; memoryBytes = $memory }; requestedLoad = [ordered]@{ replicas = $replicas; cpuMilli = $requestedCpu; memoryBytes = $requestedMemory; headroomPercent = 20 } }
    Ensure-Parent $BaselinePath; Ensure-Parent $GeneratedValuesPath
    $baseline | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $BaselinePath -Encoding utf8
    $values = @("# Generated evidence input; review, commit through Git, and let Argo reconcile.", "capacityProbe:", "  enabled: true", "  runId: `"$RunId`"", "  evidenceId: `"$RunId-capacity`"", "  sourceRevision: `"$SourceRevision`"", "  targetZone: `"$survivingAz`"", "  replicas: $replicas", "  resources:", "    requests:", "      cpu: `"$($cpuPerPod)m`"", "      memory: `"$($memoryMiPerPod)Mi`"", "    limits:", "      cpu: `"$($cpuPerPod)m`"", "      memory: `"$($memoryMiPerPod)Mi`"", "", "# Change trail: @hungxqt - 2026-07-29 - Generated a reviewed GitOps capacity-probe input for $Direction.")
    $values | Set-Content -LiteralPath $GeneratedValuesPath -Encoding utf8
    Write-Host "Generated baseline and reviewed values input only; no cluster mutation performed."
    exit 0
}

if ([string]::IsNullOrWhiteSpace($DeployedRevision)) { throw "Measure mode requires DeployedRevision from Argo after the approved Git commit." }
if (-not (Test-Path -LiteralPath $BaselinePath -PathType Leaf)) { throw "Baseline evidence is missing." }
$baseline = Get-Content -Raw -LiteralPath $BaselinePath | ConvertFrom-Json -Depth 100
if ($baseline.runId -ne $RunId -or $baseline.direction -ne $Direction -or $baseline.sourceRevision -ne $SourceRevision -or $baseline.survivingAz -ne $survivingAz) { throw "Baseline does not match the requested run contract." }
$argo = Invoke-KubeJson @("-n", "argocd", "get", "application", "techx-corp", "-o", "json")
if ($argo.status.sync.status -ne "Synced" -or $argo.status.health.status -ne "Healthy" -or $argo.status.sync.revision -ne $DeployedRevision) { throw "Argo application is not Synced/Healthy at the approved source revision." }
$observedClaims = @(Get-NodeClaimEvidence)
$baselineIds = @($baseline.baselineNodeClaims | ForEach-Object { [string]$_.uid })
$baselineAt = [datetime]$baseline.baselineAt
$newSurvivingNodeNames = @($observedClaims | Where-Object { $baselineIds -notcontains [string]$_.uid -and [datetime]$_.createdAt -gt $baselineAt -and $_.availabilityZone -eq $survivingAz -and [bool]$_.ready } | ForEach-Object { [string]$_.nodeName } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
$samples = @()
$sampleCount = [int]($SoakSeconds / $SampleIntervalSeconds) + 1
for ($index = 0; $index -lt $sampleCount; $index++) {
    if ($index -gt 0) { Start-Sleep -Seconds $SampleIntervalSeconds }
    $deployment = Invoke-KubeJson @("-n", $Namespace, "get", "deployment", "capacity-probe", "-o", "json")
    if ($deployment.metadata.labels.'mandate21.techx.io/run-id' -ne $RunId -or $deployment.metadata.labels.'mandate21.techx.io/source-revision' -ne $SourceRevision) { throw "Live capacity probe labels do not match the approved run." }
    $pods = Invoke-KubeJson @("-n", $Namespace, "get", "pods", "-l", "app.kubernetes.io/name=capacity-probe,mandate21.techx.io/run-id=$RunId", "-o", "json")
    $readyPods = @($pods.items | Where-Object { $_.status.phase -eq "Running" -and (Test-ReadyCondition $_.status.conditions) -and $_.spec.nodeName })
    [int64]$readyCpu = 0; [int64]$readyMemory = 0
    foreach ($pod in $readyPods) { foreach ($container in @($pod.spec.containers)) { $readyCpu += Convert-CpuMilli ([string]$container.resources.requests.cpu); $readyMemory += Convert-MemoryBytes ([string]$container.resources.requests.memory) } }
    $samples += [pscustomobject]@{ timestamp = (Get-Date).ToUniversalTime().ToString("o"); desiredReplicas = [int]$deployment.spec.replicas; readyReplicas = $readyPods.Count; readyCpuMilli = $readyCpu; readyMemoryBytes = $readyMemory; readyNodeNames = @($readyPods | ForEach-Object { [string]$_.spec.nodeName } | Select-Object -Unique) }
}
$snapshot = [pscustomobject]@{ baselineAt = $baseline.baselineAt; baselineNodeClaims = @($baseline.baselineNodeClaims); observedNodeClaims = $observedClaims; survivingAz = $survivingAz; requestedLoad = $baseline.requestedLoad; soakSeconds = $SoakSeconds; sampleIntervalSeconds = $SampleIntervalSeconds; samples = $samples }
$evaluation = Test-CapacityProbeSnapshot -Snapshot $snapshot
$evidence = [ordered]@{ schemaVersion = 2; runId = $RunId; evidenceId = $baseline.evidenceId; sourceRevision = $SourceRevision; deployedRevision = $DeployedRevision; argoRevision = $argo.status.sync.revision; direction = $Direction; lostAz = $lostAz; survivingAz = $survivingAz; baselineAt = $baseline.baselineAt; completedAt = (Get-Date).ToUniversalTime().ToString("o"); baselineNodeClaims = $baseline.baselineNodeClaims; newNodeClaims = $evaluation.newNodeClaims; requestedLoad = $baseline.requestedLoad; samples = $samples; status = $evaluation.status; checks = $evaluation.checks }
Ensure-Parent $EvidencePath
$evidence | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $EvidencePath -Encoding utf8
Write-Host "Capacity evidence: $EvidencePath ($($evaluation.status))"
if ($evaluation.status -ne "PASS") { exit 1 }

# Change trail: @hungxqt - 2026-07-29 - Generate GitOps probe inputs and measure revision-bound Karpenter capacity without direct mutation.