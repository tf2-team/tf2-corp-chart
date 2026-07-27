[CmdletBinding()]
param(
    [string]$ContractPath = (Join-Path $PSScriptRoot "mandate21-fis-contract.json"),
    [string]$EvidenceDirectory = (Join-Path $PSScriptRoot "../evidence/mandate21"),
    [switch]$Execute,
    [switch]$CapacityApproved,
    [switch]$CostApproved,
    [switch]$DurabilityApproved,
    [switch]$ChangeApproved,
    [string]$ConfirmationToken = "",
    [string]$ReconcilerPath = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-Text {
    param([Parameter(Mandatory)][string]$File, [Parameter(Mandatory)][string[]]$Arguments)
    $output = & $File @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "$File $($Arguments -join ' ') failed:`n$($output -join "`n")"
    }
    return ($output -join "`n")
}

function Invoke-Json {
    param([Parameter(Mandatory)][string]$File, [Parameter(Mandatory)][string[]]$Arguments)
    return (Invoke-Text -File $File -Arguments $Arguments | ConvertFrom-Json -Depth 100)
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "PRECHECK FAILED: $Message" }
    Write-Host "[PASS] $Message"
}

function Get-IntProperty {
    param([object]$Object, [string]$Name)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return 0 }
    return [int]$property.Value
}

function Save-Snapshot {
    param([string]$Name, [string]$Namespace)
    $path = Join-Path $script:RunDirectory $Name
    $content = [ordered]@{
        capturedAt = (Get-Date).ToUniversalTime().ToString("o")
        nodes = Invoke-Json kubectl @("get", "nodes", "-o", "json")
        pods = Invoke-Json kubectl @("-n", $Namespace, "get", "pods", "-o", "json")
        deployments = Invoke-Json kubectl @("-n", $Namespace, "get", "deployments", "-o", "json")
        events = Invoke-Json kubectl @("-n", $Namespace, "get", "events", "-o", "json")
        argoApplications = Invoke-Json kubectl @("-n", "argocd", "get", "applications", "-o", "json")
    }
    $content | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $path -Encoding utf8
}

function Get-NodeZoneMap {
    $nodes = Invoke-Json kubectl @("get", "nodes", "-o", "json")
    $map = @{}
    foreach ($node in $nodes.items) {
        $ready = @($node.status.conditions | Where-Object { $_.type -eq "Ready" -and $_.status -eq "True" }).Count -gt 0
        if ($ready) {
            $map[$node.metadata.name] = $node.metadata.labels.'topology.kubernetes.io/zone'
        }
    }
    return $map
}

function Get-DeploymentPlacement {
    param([string]$Namespace, [string]$Name, [hashtable]$NodeZones)
    $deployment = Invoke-Json kubectl @("-n", $Namespace, "get", "deployment", $Name, "-o", "json")
    $pods = Invoke-Json kubectl @("-n", $Namespace, "get", "pods", "-o", "json")
    $selector = $deployment.spec.selector.matchLabels
    $matching = @($pods.items | Where-Object {
        $pod = $_
        $ok = $true
        foreach ($property in $selector.PSObject.Properties) {
            $podLabel = $pod.metadata.labels.PSObject.Properties[$property.Name]
            if ($null -eq $podLabel -or [string]$podLabel.Value -ne [string]$property.Value) {
                $ok = $false
                break
            }
        }
        $ok -and $pod.status.phase -eq "Running" -and
            @($pod.status.conditions | Where-Object { $_.type -eq "Ready" -and $_.status -eq "True" }).Count -gt 0
    })
    $zones = @{}
    foreach ($pod in $matching) {
        $zone = $NodeZones[$pod.spec.nodeName]
        if (-not $zones.ContainsKey($zone)) { $zones[$zone] = 0 }
        $zones[$zone]++
    }
    return [pscustomobject]@{
        Namespace = $Namespace
        Name = $Name
        Desired = [int]$deployment.spec.replicas
        Available = Get-IntProperty $deployment.status "availableReplicas"
        ReadyPods = $matching.Count
        Zones = $zones
    }
}

function Assert-TwoAzDeployment {
    param([string]$Namespace, [string]$Name, [hashtable]$NodeZones, [switch]$CheckSkew)
    $placement = Get-DeploymentPlacement -Namespace $Namespace -Name $Name -NodeZones $NodeZones
    Assert-True ($placement.Desired -ge 2 -and $placement.Available -eq $placement.Desired) "$Namespace/$Name has >=2 desired replicas and all are Available"
    Assert-True ($placement.Zones.Keys.Count -ge 2) "$Namespace/$Name has Ready replicas in both AZs"
    if ($CheckSkew) {
        $counts = @($placement.Zones.Values)
        Assert-True ((($counts | Measure-Object -Maximum).Maximum - ($counts | Measure-Object -Minimum).Minimum) -le 1) "$Namespace/$Name baseline AZ skew is <=1"
    }
    return $placement
}

function Assert-FisTemplate {
    param([string]$Region, [string]$Zone, [string]$TemplateId, [bool]$ExpectRdsFailover)
    Assert-True ($TemplateId -match '^EXT[A-Za-z0-9]+$') "$Zone has a real FIS experiment-template ID"
    $response = Invoke-Json aws @("fis", "get-experiment-template", "--region", $Region, "--id", $TemplateId, "--output", "json")
    $template = $response.experimentTemplate
    Assert-True (@($template.stopConditions | Where-Object { $_.source -ne "none" }).Count -ge 3) "$Zone template has all three alarm stop conditions"
    $encoded = $template | ConvertTo-Json -Depth 100 -Compress
    Assert-True ($encoded -match [regex]::Escape($Zone)) "$Zone template targets the mapped availability zone"
    Assert-True ($encoded -match "aws:ec2:(stop|terminate)-instances") "$Zone template interrupts EC2 compute"
    Assert-True ($encoded -match "aws:network:disrupt-connectivity") "$Zone template disrupts subnet connectivity"
    Assert-True ($encoded -match "replicationgroup-interrupt-az-power") "$Zone template interrupts the Valkey replication group"
    Assert-True ($encoded -match "PT10M") "$Zone template keeps the fault active for 10 minutes"
    Assert-True ($encoded -match "PT([2-9]|[1-9][0-9])M") "$Zone template keeps network disruption active for at least 2 minutes"
    $hasForcedRdsFailover = $encoded -match '(?i)forceFailover.{0,20}(true|"true")'
    Assert-True ($hasForcedRdsFailover -eq $ExpectRdsFailover) "$Zone template RDS failover action matches primary location"
    return $template
}

if (-not (Test-Path -LiteralPath $ContractPath)) {
    throw "Contract not found: $ContractPath. Copy mandate21-fis-contract.example.json to mandate21-fis-contract.json and insert Person 1's reviewed template IDs."
}

$contract = Get-Content -LiteralPath $ContractPath -Raw | ConvertFrom-Json -Depth 20
Assert-True ($contract.schemaVersion -eq 1) "contract schemaVersion is 1"
Assert-True (@($contract.zones.PSObject.Properties).Count -eq 2) "contract maps exactly two AZs"

foreach ($tool in @("aws", "kubectl")) {
    Assert-True ($null -ne (Get-Command $tool -ErrorAction SilentlyContinue)) "$tool is installed"
}

$currentContext = Invoke-Text kubectl @("config", "current-context")
Assert-True ($currentContext.Trim() -eq $contract.clusterContext) "kubectl context is the approved production cluster"
$identity = Invoke-Json aws @("sts", "get-caller-identity", "--output", "json")
Write-Host "AWS account=$($identity.Account), principal=$($identity.Arn)"

$nodeZones = Get-NodeZoneMap
$zoneCounts = @{}
foreach ($zone in $nodeZones.Values) {
    if (-not $zoneCounts.ContainsKey($zone)) { $zoneCounts[$zone] = 0 }
    $zoneCounts[$zone]++
}
foreach ($zoneProperty in $contract.zones.PSObject.Properties) {
    Assert-True ($zoneCounts[$zoneProperty.Name] -gt 0) "$($zoneProperty.Name) has at least one Ready node"
}

$deployments = Invoke-Json kubectl @("-n", $contract.namespace, "get", "deployments", "-o", "json")
foreach ($deployment in $deployments.items) {
    Assert-True ((Get-IntProperty $deployment.status "availableReplicas") -eq [int]$deployment.spec.replicas) "$($contract.namespace)/$($deployment.metadata.name) is fully Available"
}
$pending = Invoke-Text kubectl @("get", "pods", "-A", "--field-selector=status.phase=Pending", "-o", "name")
Assert-True ([string]::IsNullOrWhiteSpace($pending)) "cluster has no Pending pod"

$argo = Invoke-Json kubectl @("-n", "argocd", "get", "applications", "-o", "json")
foreach ($app in $argo.items) {
    Assert-True ($app.status.sync.status -eq "Synced" -and $app.status.health.status -eq "Healthy") "Argo application $($app.metadata.name) is Synced/Healthy"
}

$placements = @(
    (Assert-TwoAzDeployment $contract.namespace "accounting" $nodeZones),
    (Assert-TwoAzDeployment $contract.namespace "frontend-proxy" $nodeZones -CheckSkew),
    (Assert-TwoAzDeployment "linkerd" "linkerd-destination" $nodeZones),
    (Assert-TwoAzDeployment "linkerd" "linkerd-identity" $nodeZones),
    (Assert-TwoAzDeployment "linkerd" "linkerd-proxy-injector" $nodeZones),
    (Assert-TwoAzDeployment "kube-system" "coredns" $nodeZones),
    (Assert-TwoAzDeployment "kube-system" "aws-load-balancer-controller" $nodeZones),
    (Assert-TwoAzDeployment "kube-system" "karpenter" $nodeZones)
)

$storefront = Invoke-WebRequest -Uri $contract.storefrontUrl -Method Get -TimeoutSec 15 -MaximumRedirection 3
Assert-True ($storefront.StatusCode -eq 200) "public storefront returns HTTP 200"

$templates = @{}
foreach ($zoneProperty in $contract.zones.PSObject.Properties) {
    $templates["$($zoneProperty.Name)-primary-in-zone"] = Assert-FisTemplate -Region $contract.region -Zone $zoneProperty.Name -TemplateId $zoneProperty.Value.primaryInZoneTemplateId -ExpectRdsFailover $true
    $templates["$($zoneProperty.Name)-primary-outside-zone"] = Assert-FisTemplate -Region $contract.region -Zone $zoneProperty.Name -TemplateId $zoneProperty.Value.primaryOutsideZoneTemplateId -ExpectRdsFailover $false
}

if (-not $Execute) {
    Write-Host ""
    Write-Host "PREVIEW COMPLETE: all runtime and template contracts passed. No fault was created."
    Write-Host "Live execution additionally requires all four approval switches and -ConfirmationToken RUN-M21-FIS."
    exit 0
}

Assert-True ($CapacityApproved -and $CostApproved -and $DurabilityApproved -and $ChangeApproved) "capacity, cost, durability, and change approvals are explicit"
Assert-True ($ConfirmationToken -ceq "RUN-M21-FIS") "confirmation token matches RUN-M21-FIS"
Assert-True (-not [string]::IsNullOrWhiteSpace($ReconcilerPath)) "Person 2 reconciliation checker is supplied"

$selectedZone = Get-Random -InputObject @($contract.zones.PSObject.Properties.Name)
$rds = Invoke-Json aws @("rds", "describe-db-instances", "--region", $contract.region, "--db-instance-identifier", $contract.rdsInstanceIdentifier, "--output", "json")
$rdsPrimaryZone = [string]$rds.DBInstances[0].AvailabilityZone
$rdsPrimaryInFaultZone = $rdsPrimaryZone -eq $selectedZone
$templateId = if ($rdsPrimaryInFaultZone) {
    $contract.zones.$selectedZone.primaryInZoneTemplateId
} else {
    $contract.zones.$selectedZone.primaryOutsideZoneTemplateId
}
$faultId = "m21-$($selectedZone)-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))"
New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
$evidenceRoot = (Resolve-Path -LiteralPath $EvidenceDirectory).Path
$script:RunDirectory = Join-Path $evidenceRoot $faultId
New-Item -ItemType Directory -Path $script:RunDirectory -Force | Out-Null

[ordered]@{
    faultId = $faultId
    selectedZone = $selectedZone
    templateId = $templateId
    rdsPrimaryZone = $rdsPrimaryZone
    rdsForcedFailoverExpected = $rdsPrimaryInFaultZone
    startedAt = (Get-Date).ToUniversalTime().ToString("o")
    awsIdentity = $identity
    nodeZones = $zoneCounts
    placements = $placements
} | ConvertTo-Json -Depth 30 | Set-Content (Join-Path $script:RunDirectory "preflight.json") -Encoding utf8
Save-Snapshot -Name "before.json" -Namespace $contract.namespace

Write-Host "Starting approved FIS experiment $templateId for randomly selected $selectedZone"
$started = Invoke-Json aws @("fis", "start-experiment", "--region", $contract.region, "--experiment-template-id", $templateId, "--tags", "Mandate=21,FaultId=$faultId", "--output", "json")
$experimentId = $started.experiment.id
$started | ConvertTo-Json -Depth 100 | Set-Content (Join-Path $script:RunDirectory "fis-start.json") -Encoding utf8

$terminal = @("completed", "stopped", "failed")
$poll = 0
do {
    Start-Sleep -Seconds 15
    $poll++
    $experiment = Invoke-Json aws @("fis", "get-experiment", "--region", $contract.region, "--id", $experimentId, "--output", "json")
    $experiment | ConvertTo-Json -Depth 100 | Set-Content (Join-Path $script:RunDirectory "fis-latest.json") -Encoding utf8
    $state = [string]$experiment.experiment.state.status
    [ordered]@{
        capturedAt = (Get-Date).ToUniversalTime().ToString("o")
        experimentId = $experimentId
        status = $state
    } | ConvertTo-Json -Compress | Add-Content (Join-Path $script:RunDirectory "fis-timeline.jsonl") -Encoding utf8
    if (($poll % 4) -eq 0 -and $terminal -notcontains $state) {
        Save-Snapshot -Name "during-$('{0:D3}' -f $poll).json" -Namespace $contract.namespace
    }
    Write-Host "FIS $experimentId state=$state"
} while ($terminal -notcontains $state)

Save-Snapshot -Name "after.json" -Namespace $contract.namespace
$postPending = Invoke-Text kubectl @("get", "pods", "-A", "--field-selector=status.phase=Pending", "-o", "name")
Assert-True ([string]::IsNullOrWhiteSpace($postPending)) "cleanup left no Pending pod"
$cordoned = Invoke-Text kubectl @("get", "nodes", "-o", "jsonpath={range .items[?(@.spec.unschedulable==true)]}{.metadata.name}{' '}{end}")
Assert-True ([string]::IsNullOrWhiteSpace($cordoned)) "cleanup left no cordoned node"
$postArgo = Invoke-Json kubectl @("-n", "argocd", "get", "applications", "-o", "json")
Assert-True (@($postArgo.items | Where-Object { $_.status.sync.status -ne "Synced" -or $_.status.health.status -ne "Healthy" }).Count -eq 0) "cleanup left no Argo drift or unhealthy application"
$postDeployments = Invoke-Json kubectl @("-n", $contract.namespace, "get", "deployments", "-o", "json")
Assert-True (@($postDeployments.items | Where-Object { (Get-IntProperty $_.status "availableReplicas") -ne [int]$_.spec.replicas }).Count -eq 0) "all application Deployments recovered"

Assert-True (Test-Path -LiteralPath $ReconcilerPath) "Person 2 reconciliation checker exists"
& $ReconcilerPath -EvidenceDirectory $script:RunDirectory -FaultId $faultId
if ($LASTEXITCODE -ne 0) { throw "Reconciliation failed with exit code $LASTEXITCODE" }

Assert-True ($state -eq "completed") "FIS experiment completed without stop/failure"
Write-Host "DRILL COMPLETE: evidence=$script:RunDirectory"
