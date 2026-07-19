[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SourceKubeContext,

    [Parameter(Mandatory)]
    [string]$TestKubeContext
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot

if ($SourceKubeContext -eq $TestKubeContext) {
    throw "Source and test contexts must be different."
}
if ($TestKubeContext -match "techx-tf2-prod|arn:aws:eks") {
    throw "Refusing to install candidate exception policy on a production/EKS context: $TestKubeContext"
}

function Invoke-Kubectl {
    param(
        [string]$Context,
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    $output = & kubectl --context $Context @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "kubectl --context $Context $($Arguments -join ' ') failed:`n$($output -join "`n")"
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $output -join "`n"
    }
}

function Copy-Object {
    param([object]$InputObject)

    return $InputObject | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100
}

function Get-CleanWorkload {
    param(
        [string]$Kind,
        [string]$Name
    )

    $result = Invoke-Kubectl -Context $SourceKubeContext -Arguments @(
        "-n", "kube-system", "get", $Kind, $Name, "-o", "json"
    )
    $source = $result.Output | ConvertFrom-Json -Depth 100

    return [pscustomobject][ordered]@{
        apiVersion = $source.apiVersion
        kind       = $source.kind
        metadata   = [pscustomobject][ordered]@{
            name      = $source.metadata.name
            namespace = "kube-system"
            labels    = $source.metadata.labels
        }
        spec       = $source.spec
    }
}

function ConvertTo-TestPod {
    param(
        [object]$Workload,
        [string]$Suffix
    )

    $safeName = ($Workload.metadata.name -replace "[^a-z0-9-]", "-").Trim("-")
    $ownerKind = if ($Workload.kind -eq "DaemonSet") { "DaemonSet" } else { "ReplicaSet" }
    $ownerName = if ($ownerKind -eq "DaemonSet") {
        $Workload.metadata.name
    }
    else {
        "$($Workload.metadata.name)-mandate5-test"
    }
    return [pscustomobject][ordered]@{
        apiVersion = "v1"
        kind       = "Pod"
        metadata   = [pscustomobject][ordered]@{
            name      = "mandate5-$safeName-$Suffix"
            namespace = "kube-system"
            labels    = Copy-Object $Workload.spec.template.metadata.labels
            ownerReferences = @([pscustomobject][ordered]@{
                apiVersion = "apps/v1"
                kind       = $ownerKind
                name       = $ownerName
                uid        = "00000000-0000-0000-0000-000000000001"
                controller = $true
            })
        }
        spec       = Copy-Object $Workload.spec.template.spec
    }
}

function Invoke-AdmissionDryRun {
    param([object]$Object)

    $json = $Object | ConvertTo-Json -Depth 100 -Compress
    $output = $json | & kubectl --context $TestKubeContext apply `
        --server-side --force-conflicts --field-manager=mandate5-exception-test `
        --dry-run=server -f - 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = $output -join "`n"
    }
}

function Assert-Admitted {
    param(
        [object]$Object,
        [string]$Case
    )

    $result = Invoke-AdmissionDryRun -Object $Object
    if ($result.ExitCode -ne 0) {
        throw "$Case was unexpectedly denied:`n$($result.Output)"
    }
    Write-Output "PASS admitted: $Case"
}

function Assert-Denied {
    param(
        [object]$Object,
        [string]$Case
    )

    $result = Invoke-AdmissionDryRun -Object $Object
    if ($result.ExitCode -eq 0) {
        throw "$Case was unexpectedly admitted."
    }
    if ($result.Output -notmatch "ValidatingAdmissionPolicy") {
        throw "$Case was denied for an unexpected reason:`n$($result.Output)"
    }
    Write-Output "PASS denied: $Case"
}

function Wait-PolicyReady {
    param([string]$Name)

    for ($attempt = 1; $attempt -le 30; $attempt++) {
        $result = Invoke-Kubectl -Context $TestKubeContext -Arguments @(
            "get", "validatingadmissionpolicy", $Name, "-o", "json"
        ) -AllowFailure
        if ($result.ExitCode -eq 0) {
            $policy = $result.Output | ConvertFrom-Json -Depth 100
            $warnings = @($policy.status.typeChecking.expressionWarnings | Where-Object { $null -ne $_ })
            if ($policy.status.observedGeneration -eq $policy.metadata.generation -and $warnings.Count -eq 0) {
                return
            }
        }
        Start-Sleep -Seconds 1
    }
    throw "Policy $Name did not become warning-free within 30 seconds."
}

function Set-ServiceAccount {
    param(
        [object]$Workload,
        [string]$Name
    )

    $Workload.spec.template.spec.serviceAccountName = $Name
}

function Set-PodServiceAccount {
    param(
        [object]$Pod,
        [string]$Name
    )

    $Pod.spec.serviceAccountName = $Name
}

Push-Location $repoRoot
try {
    Invoke-Kubectl -Context $TestKubeContext -Arguments @("cluster-info") | Out-Null
    Invoke-Kubectl -Context $TestKubeContext -Arguments @(
        "apply", "-k", "gitops/runtime-hardening/overlays/enforce-clusterwide"
    ) | Out-Null

    foreach ($policy in @(
        "runtime-hardening-pod.techx.io",
        "runtime-hardening-pod-template.techx.io",
        "runtime-hardening-cronjob.techx.io"
    )) {
        Wait-PolicyReady -Name $policy
    }
    Write-Output "PASS policies observed with zero type-check warnings"

    # Minikube ships a CoreDNS Deployment with the same name but a different
    # immutable selector. Remove it only from the guarded disposable target so
    # the EKS CoreDNS profile can be evaluated as a CREATE dry-run.
    Invoke-Kubectl -Context $TestKubeContext -Arguments @(
        "-n", "kube-system", "delete", "deployment", "coredns",
        "--ignore-not-found=true", "--wait=true"
    ) | Out-Null

    foreach ($serviceAccount in @(
        "aws-node",
        "kube-proxy",
        "ebs-csi-node-sa",
        "ebs-csi-controller-sa",
        "coredns"
    )) {
        $serviceAccountObject = [pscustomobject][ordered]@{
            apiVersion = "v1"
            kind       = "ServiceAccount"
            metadata   = [pscustomobject][ordered]@{
                name      = $serviceAccount
                namespace = "kube-system"
            }
        }
        $json = $serviceAccountObject | ConvertTo-Json -Depth 10 -Compress
        $json | & kubectl --context $TestKubeContext apply -f - | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create test ServiceAccount $serviceAccount"
        }
    }

    $workloadSpecs = @(
        @{ Kind = "daemonset"; Name = "aws-node" },
        @{ Kind = "daemonset"; Name = "kube-proxy" },
        @{ Kind = "daemonset"; Name = "ebs-csi-node" },
        @{ Kind = "daemonset"; Name = "ebs-csi-node-windows" },
        @{ Kind = "deployment"; Name = "ebs-csi-controller" },
        @{ Kind = "deployment"; Name = "coredns" }
    )

    $workloads = @{}
    foreach ($item in $workloadSpecs) {
        $workload = Get-CleanWorkload -Kind $item.Kind -Name $item.Name
        $workloads[$item.Name] = $workload
        Assert-Admitted -Object $workload -Case "$($workload.kind)/$($item.Name) exact profile"
        Assert-Admitted -Object (ConvertTo-TestPod -Workload $workload -Suffix "valid") `
            -Case "Pod/$($item.Name) exact profile"
    }

    $ownerlessSystemPod = ConvertTo-TestPod -Workload $workloads.coredns -Suffix "ownerless"
    $ownerlessSystemPod.metadata.PSObject.Properties.Remove("ownerReferences")
    Assert-Denied -Object $ownerlessSystemPod -Case "Pod/coredns ownerless lookalike"

    $replicaSet = [pscustomobject][ordered]@{
        apiVersion = "apps/v1"
        kind       = "ReplicaSet"
        metadata   = [pscustomobject][ordered]@{
            name            = "coredns-mandate5-test"
            namespace       = "kube-system"
            labels          = Copy-Object $workloads.coredns.metadata.labels
            ownerReferences = @([pscustomobject][ordered]@{
                apiVersion = "apps/v1"
                kind       = "Deployment"
                name       = "coredns"
                uid        = "00000000-0000-0000-0000-000000000001"
                controller = $true
            })
        }
        spec       = [pscustomobject][ordered]@{
            replicas = 0
            selector = Copy-Object $workloads.coredns.spec.selector
            template = Copy-Object $workloads.coredns.spec.template
        }
    }
    Assert-Admitted -Object $replicaSet -Case "ReplicaSet/coredns approved owner"
    $wrongOwner = Copy-Object $replicaSet
    $wrongOwner.metadata.ownerReferences[0].name = "coredns-lookalike"
    Assert-Denied -Object $wrongOwner -Case "ReplicaSet/coredns wrong owner"

    $wrongServiceAccount = Copy-Object $workloads.coredns
    Set-ServiceAccount -Workload $wrongServiceAccount -Name "default"
    Assert-Denied -Object $wrongServiceAccount -Case "CoreDNS wrong ServiceAccount workload"
    $wrongServiceAccountPod = ConvertTo-TestPod -Workload $workloads.coredns -Suffix "wrong-sa"
    Set-PodServiceAccount -Pod $wrongServiceAccountPod -Name "default"
    Assert-Denied -Object $wrongServiceAccountPod -Case "CoreDNS wrong ServiceAccount Pod"

    $wrongLabel = Copy-Object $workloads.coredns
    $wrongLabel.spec.template.metadata.labels."k8s-app" = "lookalike"
    $wrongLabel.spec.selector.matchLabels."k8s-app" = "lookalike"
    Assert-Denied -Object $wrongLabel -Case "CoreDNS wrong stable label workload"
    $wrongLabelPod = ConvertTo-TestPod -Workload $workloads.coredns -Suffix "wrong-label"
    $wrongLabelPod.metadata.labels."k8s-app" = "lookalike"
    Assert-Denied -Object $wrongLabelPod -Case "CoreDNS wrong stable label Pod"

    $extraCapability = Copy-Object $workloads.coredns
    $extraCapability.spec.template.spec.containers[0].securityContext.capabilities.add = @(
        "NET_BIND_SERVICE", "SYS_ADMIN"
    )
    Assert-Denied -Object $extraCapability -Case "CoreDNS extra capability workload"
    $extraCapabilityPod = ConvertTo-TestPod -Workload $extraCapability -Suffix "extra-cap"
    Assert-Denied -Object $extraCapabilityPod -Case "CoreDNS extra capability Pod"

    $awsExtraCapability = Copy-Object $workloads."aws-node"
    $awsExtraCapability.spec.template.spec.containers[0].securityContext.capabilities.add += "SYS_ADMIN"
    Assert-Denied -Object $awsExtraCapability -Case "VPC CNI extra capability workload"
    $awsExtraCapabilityPod = ConvertTo-TestPod -Workload $awsExtraCapability -Suffix "extra-cap"
    Assert-Denied -Object $awsExtraCapabilityPod -Case "VPC CNI extra capability Pod"

    $floatingImage = Copy-Object $workloads.coredns
    $floatingImage.spec.template.spec.containers[0].image = "602401143452.dkr.ecr.us-east-1.amazonaws.com/eks/coredns:latest"
    Assert-Denied -Object $floatingImage -Case "Approved workload latest image"
    Assert-Denied -Object (ConvertTo-TestPod -Workload $floatingImage -Suffix "latest") `
        -Case "Approved Pod latest image"

    $missingResources = Copy-Object $workloads.coredns
    $missingResources.spec.template.spec.containers[0].resources.requests.PSObject.Properties.Remove("cpu")
    $missingResources.spec.template.spec.containers[0].resources.limits.PSObject.Properties.Remove("cpu")
    Assert-Denied -Object $missingResources -Case "Approved workload missing CPU request/limit"
    Assert-Denied -Object (ConvertTo-TestPod -Workload $missingResources -Suffix "resources") `
        -Case "Approved Pod missing CPU request/limit"

    $extraContainer = Copy-Object $workloads.coredns
    $sidecar = Copy-Object $extraContainer.spec.template.spec.containers[0]
    $sidecar.name = "unapproved-sidecar"
    $extraContainer.spec.template.spec.containers = @($extraContainer.spec.template.spec.containers) + $sidecar
    Assert-Denied -Object $extraContainer -Case "Approved workload extra container"
    Assert-Denied -Object (ConvertTo-TestPod -Workload $extraContainer -Suffix "sidecar") `
        -Case "Approved Pod extra container"

    Write-Output "PASS exact system exception and near-miss admission suite"
}
finally {
    Pop-Location
}
