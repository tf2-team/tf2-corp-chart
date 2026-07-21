param(
    [string]$Helm = "helm"
)

$ErrorActionPreference = "Stop"
$chartRoot = Split-Path -Parent $PSScriptRoot
$valueFiles = @(
    (Join-Path $chartRoot "values.yaml"),
    (Join-Path $chartRoot "values-public-alb.yaml"),
    (Join-Path $chartRoot "values-prod.yaml")
)
$prodValues = Get-Content -Raw (Join-Path $chartRoot "values-prod.yaml")
$componentsBlockMatch = [regex]::Match($prodValues, '(?ms)^components:[ \t]*\r?\n(?<block>.*?)(?=^[^\s#][^:\r\n]*:[ \t]*(?:#.*)?$|\z)')
if (-not $componentsBlockMatch.Success) {
    throw 'flagd: values-prod.yaml must contain a top-level components block'
}
$flagdBlockMatch = [regex]::Match($componentsBlockMatch.Groups['block'].Value, '(?ms)^  flagd:[ \t]*(?:#.*)?\r?\n(?<block>.*?)(?=^  [^\s#][^:\r\n]*:[ \t]*(?:#.*)?$|\z)')
if (-not $flagdBlockMatch.Success) {
    throw 'flagd: values-prod.yaml components block must contain flagd'
}
$flagdBlock = $flagdBlockMatch.Groups['block'].Value
$flagdAuthHeaders = [regex]::Matches($flagdBlock, '"authHeader"\s*:')
$exactFlagdAuthHeaders = [regex]::Matches($flagdBlock, [regex]::Escape('"authHeader":"Bearer $(FLAGD_SYNC_TOKEN)"'))
if ($flagdAuthHeaders.Count -ne 1 -or $exactFlagdAuthHeaders.Count -ne 1) {
    throw 'flagd: values-prod.yaml authHeader must use only the FLAGD_SYNC_TOKEN placeholder'
}

$helmArgs = @(
    "template", "techx-corp", $chartRoot,
    "--namespace", "techx-corp-prod"
)
foreach ($valueFile in $valueFiles) {
    $helmArgs += @("--values", $valueFile)
}

$renderedLines = & $Helm @helmArgs
if ($LASTEXITCODE -ne 0) {
    throw "helm template failed with exit code $LASTEXITCODE"
}
$documents = (($renderedLines -join "`n") -split "(?m)^---\s*$")

function Get-Manifest {
    param([string]$Kind, [string]$Name)

    $kindPattern = "(?m)^kind: $([regex]::Escape($Kind))$"
    $namePattern = "(?m)^  name: $([regex]::Escape($Name))$"
    return @($documents | Where-Object {
        $_ -match $kindPattern -and $_ -match $namePattern
    })
}

function Assert-Match {
    param([string]$Text, [string]$Pattern, [string]$Message)

    if ($Text -notmatch $Pattern) {
        throw $Message
    }
}

function Assert-MinimumReplicaFloor {
    param([string]$Manifest, [string]$Field, [string]$Name)

    $floorMatch = [regex]::Match($Manifest, "(?m)^  $([regex]::Escape($Field)): (?<floor>[0-9]+)$")
    if (-not $floorMatch.Success -or [int]$floorMatch.Groups['floor'].Value -lt 2) {
        throw "${Name}: ${Field} must be at least 2"
    }
}

# Money-path / storefront stateless floor: two Ready replicas + PDB. Zone
# spread is soft so workloads can recover in one AZ; hostname remains hard.
$criticalServices = @(
    "ad", "cart", "checkout", "currency", "email", "frontend",
    "frontend-proxy", "image-provider", "payment", "product-catalog",
    "product-reviews", "quote", "recommendation", "shipping"
)

foreach ($name in $criticalServices) {
    [array]$deployment = @(Get-Manifest -Kind "Deployment" -Name $name)
    if ($deployment.Count -ne 1) {
        throw "${name}: expected exactly one Deployment, found $($deployment.Count)"
    }

    [array]$hpa = @(Get-Manifest -Kind "HorizontalPodAutoscaler" -Name $name)
    if ($hpa.Count -eq 1) {
        Assert-MinimumReplicaFloor $hpa[0] "minReplicas" $name
    }
    else {
        Assert-MinimumReplicaFloor $deployment[0] "replicas" $name
    }

    [array]$pdb = @(Get-Manifest -Kind "PodDisruptionBudget" -Name $name)
    if ($pdb.Count -ne 1) {
        throw "${name}: expected exactly one PodDisruptionBudget"
    }
    Assert-Match $pdb[0] "(?m)^  (minAvailable: [12]|maxUnavailable: 1)$" "${name}: PDB configuration is invalid"
    Assert-Match $deployment[0] "(?ms)^  strategy:\s+rollingUpdate:\s+maxSurge: 1\s+maxUnavailable: 0\s+type: RollingUpdate" "${name}: unsafe rolling update strategy"
    Assert-Match $deployment[0] "(?m)^      terminationGracePeriodSeconds: 30$" "${name}: termination grace must be 30 seconds"
    Assert-Match $deployment[0] "(?ms)^          readinessProbe:.*?          lifecycle:\s+preStop:\s+sleep:\s+seconds: 10" "${name}: readiness and native preStop drain hook are required"
    Assert-Match $deployment[0] "(?ms)^      topologySpreadConstraints:.*?topologyKey: topology.kubernetes.io/zone\s+whenUnsatisfiable: ScheduleAnyway.*?topologyKey: kubernetes.io/hostname\s+whenUnsatisfiable: DoNotSchedule\s+minDomains: 2" "${name}: zone spread must be soft and hostname spread must remain hard"

    Write-Host "PASS $name"
}

# flagd: reviewed singleton on Critical MNG (system-*), not multi-replica HA.
[array]$flagdDeployment = @(Get-Manifest -Kind "Deployment" -Name "flagd")
if ($flagdDeployment.Count -ne 1) {
    throw "flagd: expected exactly one Deployment, found $($flagdDeployment.Count)"
}
Assert-Match $flagdDeployment[0] "(?m)^  replicas: 1$" "flagd: fixed replica count must be 1 (singleton control plane)"
Assert-Match $flagdDeployment[0] "(?m)^        workload-class: critical$" "flagd: must pin to Critical MNG (workload-class=critical / system-*)"
if ($flagdDeployment[0] -match "(?m)^      topologySpreadConstraints:") {
    throw "flagd: singleton must not set topologySpreadConstraints"
}
if ((Get-Manifest -Kind "PodDisruptionBudget" -Name "flagd").Count -ne 0) {
    throw "flagd: do not render a multi-replica PDB for the flagd singleton"
}
Assert-Match $flagdDeployment[0] "(?ms)^  strategy:\s+rollingUpdate:\s+maxSurge: 1\s+maxUnavailable: 0\s+type: RollingUpdate" "flagd: unsafe rolling update strategy"
Assert-Match $flagdDeployment[0] "(?m)^      terminationGracePeriodSeconds: 30$" "flagd: termination grace must be 30 seconds"
Assert-Match $flagdDeployment[0] "(?ms)^          readinessProbe:.*?          lifecycle:\s+preStop:\s+sleep:\s+seconds: 10" "flagd: readiness and native preStop drain hook are required"
Assert-Match $flagdDeployment[0] "(?ms)^          env:.*?- name: FLAGD_SYNC_TOKEN\s+valueFrom:\s+secretKeyRef:\s+key: FLAGD_SYNC_TOKEN\s+name: techx-corp-flagd-ui" "flagd: FLAGD_SYNC_TOKEN must come from techx-corp-flagd-ui/FLAGD_SYNC_TOKEN"
Assert-Match $flagdDeployment[0] '(?ms)^          command:\s+- /flagd-build\s+- start\s+- --port\s+- "8013"\s+- --ofrep-port\s+- "8016"\s+- --sources\s+- ''\[\{"uri":"/etc/flagd/demo\.flagd\.json","provider":"file"\},\{"uri":"https://122\.248\.223\.194\.sslip\.io/flags\.json","provider":"http","authHeader":"Bearer\s+\$\(FLAGD_SYNC_TOKEN\)"\}\]''$' "flagd: rendered command must use the exact secret-backed --sources value"
Write-Host "PASS flagd (singleton on critical)"

foreach ($name in @("kafka", "postgresql", "opensearch")) {
    [array]$statefulSet = @(Get-Manifest -Kind "StatefulSet" -Name $name)
    if ($statefulSet.Count -eq 0 -and $name -in @("kafka", "postgresql")) {
        Write-Host "PASS $name (managed production dependency)"
        continue
    }
    if ($statefulSet.Count -ne 1) {
        throw "${name}: expected one reviewed StatefulSet or an approved managed production dependency"
    }
    Assert-Match $statefulSet[0] "(?m)^  replicas: 1$" "${name}: chart safety boundary expects the reviewed singleton architecture"
    if ((Get-Manifest -Kind "PodDisruptionBudget" -Name $name).Count -ne 0) {
        throw "${name}: do not render a misleading HA PDB for a singleton stateful service"
    }
}

if ((Get-Manifest -Kind "StatefulSet" -Name "valkey-cart").Count -ne 0) {
    throw "valkey-cart: production must use managed Multi-AZ Valkey, not the singleton StatefulSet"
}
$cartDeployment = (Get-Manifest -Kind "Deployment" -Name "cart")
Assert-Match $cartDeployment "(?ms)name: VALKEY_ADDR\s+value: valkey-cart.techx.internal:6379" "cart: managed Valkey address is required"
$checkoutDeployment = (Get-Manifest -Kind "Deployment" -Name "checkout")
Assert-Match $checkoutDeployment "(?ms)name: CHECKOUT_OUTBOX_TABLE\s+value: techx-prod-tf2-checkout-outbox" "checkout: durable outbox table is required"
Assert-Match $checkoutDeployment "(?m)^      serviceAccountName: checkout$" "checkout: dedicated IRSA ServiceAccount is required"
if ($checkoutDeployment -match "wait-for-kafka") {
    throw "checkout: Kafka must not block pod startup"
}

[array]$publicIngress = @(Get-Manifest -Kind "Ingress" -Name "frontend-proxy-public")
if ($publicIngress.Count -ne 1) {
    throw "expected the public storefront Ingress"
}
Assert-Match $publicIngress[0] 'alb.ingress.kubernetes.io/scheme: "?internal"?' "Directive #1 regression: storefront origin ALB must remain internal"

# Regression: when an HPA is active, a stale fixed replicas value must not create a PDB.
$singleReplicaHpaArgs = $helmArgs + @(
    "--set", "components.product-reviews.replicas=2",
    "--set", "components.product-reviews.autoscaling.minReplicas=1"
)
$singleReplicaHpaLines = & $Helm @singleReplicaHpaArgs
if ($LASTEXITCODE -ne 0) {
    throw "helm template for single-replica HPA regression failed with exit code $LASTEXITCODE"
}
$singleReplicaHpaDocuments = (($singleReplicaHpaLines -join "`n") -split "(?m)^---\s*$")
$singleReplicaHpaPdbs = @($singleReplicaHpaDocuments | Where-Object {
    $_ -match "(?m)^kind: PodDisruptionBudget$" -and
    $_ -match "(?m)^  name: product-reviews$"
})
if ($singleReplicaHpaPdbs.Count -ne 0) {
    throw "product-reviews: HPA minReplicas=1 must not render a PDB even when replicas=2 is present"
}
Write-Host "PASS product-reviews active-HPA PDB ownership regression"

Write-Host "Directive #3 production manifest policy checks passed."

# Change trail: @hungxqt - 2026-07-15 - Verify active HPA replica floors and stale fixed-replica PDB regression.
