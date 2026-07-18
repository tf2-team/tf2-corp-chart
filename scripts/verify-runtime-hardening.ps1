[CmdletBinding()]
param(
    [string]$KubeContext
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$negativeValues = Join-Path $repoRoot "tests/runtime-hardening/invalid-init-container-resources.yaml"
$fixtureRoot = Join-Path $repoRoot "tests/runtime-hardening/fixtures"

function Assert-LastExitCode {
    param([string]$Step)

    if ($LASTEXITCODE -ne 0) {
        throw "$Step failed with exit code $LASTEXITCODE"
    }
}

function Assert-Count {
    param(
        [string]$Text,
        [string]$Pattern,
        [int]$Expected,
        [string]$Step
    )

    $actual = [regex]::Matches($Text, $Pattern).Count
    if ($actual -ne $Expected) {
        throw "$Step expected $Expected match(es), found $actual"
    }
}

function Invoke-Kubectl {
    param([string[]]$Arguments)

    & kubectl --context $KubeContext @Arguments
}

function Assert-AdmissionDenied {
    param([string]$Path)

    $output = Invoke-Kubectl @("apply", "--dry-run=server", "-f", $Path) 2>&1
    $exitCode = $LASTEXITCODE
    $text = $output -join "`n"
    if ($exitCode -eq 0) {
        throw "Invalid fixture unexpectedly admitted: $Path"
    }
    if ($text -notmatch "ValidatingAdmissionPolicy") {
        throw "Fixture was denied for an unexpected reason: $Path`n$text"
    }
    Write-Output "PASS denied: $([IO.Path]::GetFileName($Path))"
}

function Wait-PolicyReady {
    param([string]$PolicyName)

    for ($attempt = 1; $attempt -le 30; $attempt++) {
        $rawPolicy = Invoke-Kubectl @("get", "validatingadmissionpolicy", $PolicyName, "-o", "json") 2>$null
        if ($LASTEXITCODE -eq 0) {
            $policy = $rawPolicy -join "`n" | ConvertFrom-Json -Depth 100
            $warnings = @(
                $policy.status.typeChecking.expressionWarnings |
                    Where-Object { $null -ne $_ }
            )
            $acceptedCondition = @($policy.status.conditions | Where-Object type -eq "Accepted")
            $accepted = $acceptedCondition.Count -eq 0 -or $acceptedCondition[0].status -eq "True"
            if (
                $policy.status.observedGeneration -eq $policy.metadata.generation -and
                $warnings.Count -eq 0 -and
                $accepted
            ) {
                return
            }
        }
        Start-Sleep -Seconds 1
    }

    throw "VAP $PolicyName did not reach an observed, warning-free status within 30 seconds"
}

Push-Location $repoRoot
try {
    & helm lint . -f values.yaml -f values-public-alb.yaml -f values-prod.yaml
    Assert-LastExitCode "Positive Helm lint"

    $negativeOutput = & helm lint . `
        -f values.yaml `
        -f values-public-alb.yaml `
        -f values-prod.yaml `
        -f $negativeValues 2>&1
    $negativeExitCode = $LASTEXITCODE
    $negativeText = $negativeOutput -join "`n"
    if ($negativeExitCode -eq 0 -or $negativeText -notmatch "additional properties 'typo' not allowed") {
        throw "Negative schema test did not reject the expected typo:`n$negativeText"
    }
    Write-Output "PASS negative Helm schema test"

    $baseText = (& kubectl kustomize gitops/runtime-hardening/base) -join "`n"
    Assert-LastExitCode "VAP base render"
    Assert-Count $baseText "(?m)^kind: ValidatingAdmissionPolicy$" 3 "VAP base"

    $auditText = (& kubectl kustomize gitops/runtime-hardening/overlays/audit) -join "`n"
    Assert-LastExitCode "VAP audit overlay render"
    Assert-Count $auditText "(?m)^kind: ValidatingAdmissionPolicyBinding$" 3 "Audit overlay bindings"
    Assert-Count $auditText "(?m)^  - Warn$" 3 "Audit overlay Warn actions"
    Assert-Count $auditText "(?m)^  - Audit$" 3 "Audit overlay Audit actions"
    Assert-Count $auditText "(?m)^  - Deny$" 0 "Audit overlay Deny actions"

    $enforceText = (& kubectl kustomize gitops/runtime-hardening/overlays/enforce) -join "`n"
    Assert-LastExitCode "VAP enforce overlay render"
    Assert-Count $enforceText "(?m)^kind: ValidatingAdmissionPolicyBinding$" 3 "Enforce overlay bindings"
    Assert-Count $enforceText "(?m)^  - Deny$" 3 "Enforce overlay Deny actions"
    Assert-Count $enforceText "(?m)^  - Warn$" 0 "Enforce overlay Warn actions"
    Assert-Count $enforceText "(?m)^  - Audit$" 0 "Enforce overlay Audit actions"
    Write-Output "PASS VAP base/audit/enforce render contracts"

    if (-not $KubeContext) {
        Write-Output "SKIP native admission tests: pass -KubeContext for a disposable Kubernetes cluster."
        return
    }

    foreach ($auditBinding in @(
        "runtime-hardening-pod-audit.techx.io",
        "runtime-hardening-pod-template-audit.techx.io",
        "runtime-hardening-cronjob-audit.techx.io"
    )) {
        Invoke-Kubectl @(
            "delete", "validatingadmissionpolicybinding", $auditBinding,
            "--ignore-not-found=true", "--wait=true"
        ) | Out-Null
    }

    Invoke-Kubectl @("apply", "-k", "gitops/runtime-hardening/overlays/enforce") | Out-Host
    Assert-LastExitCode "Install VAP enforce overlay"

    $policyNames = @(
        "runtime-hardening-pod.techx.io",
        "runtime-hardening-pod-template.techx.io",
        "runtime-hardening-cronjob.techx.io"
    )
    foreach ($policyName in $policyNames) {
        Wait-PolicyReady $policyName
    }
    Write-Output "PASS all VAP policies observed with zero type-check warnings"

    foreach ($validFixture in @(
        "valid-pod.yaml",
        "valid-deployment.yaml",
        "valid-job.yaml",
        "valid-cronjob.yaml",
        "valid-digest-pod.yaml",
        "valid-registry-port-pod.yaml"
    )) {
        $path = Join-Path $fixtureRoot $validFixture
        Invoke-Kubectl @("apply", "--dry-run=server", "-f", $path) | Out-Host
        Assert-LastExitCode "Admit valid fixture $validFixture"
    }
    Write-Output "PASS valid Pod/Deployment/Job/CronJob fixtures admitted"

    foreach ($invalidFixture in @(
        "invalid-root.yaml",
        "invalid-uid-zero.yaml",
        "invalid-capability.yaml",
        "invalid-latest-deployment.yaml",
        "invalid-untagged-pod.yaml",
        "invalid-digest-pod.yaml",
        "invalid-resources-job.yaml",
        "invalid-cronjob.yaml"
    )) {
        Assert-AdmissionDenied (Join-Path $fixtureRoot $invalidFixture)
    }

    $validPod = Join-Path $fixtureRoot "valid-pod.yaml"
    Invoke-Kubectl @("apply", "-f", $validPod) | Out-Host
    Assert-LastExitCode "Create valid Pod for UPDATE test"
    try {
        Assert-AdmissionDenied (Join-Path $fixtureRoot "update-latest-pod.yaml")
    }
    finally {
        Invoke-Kubectl @("delete", "-f", $validPod, "--ignore-not-found=true", "--wait=false") | Out-Null
    }
    Write-Output "PASS native CREATE and UPDATE admission tests"

    if (-not (Get-Command yq -ErrorAction SilentlyContinue)) {
        throw "yq v4 is required for production workload render filtering"
    }

    $productionRender = Join-Path ([IO.Path]::GetTempPath()) ("mandate5-production-{0}.yaml" -f [guid]::NewGuid())
    $workloadRender = Join-Path ([IO.Path]::GetTempPath()) ("mandate5-workloads-{0}.yaml" -f [guid]::NewGuid())
    try {
        & helm template techx-corp . `
            --namespace techx-corp-prod `
            -f values-public-alb.yaml `
            -f values-prod.yaml |
            Set-Content -LiteralPath $productionRender -Encoding utf8NoBOM
        Assert-LastExitCode "Production Helm render"

        $kindFilter = 'select(.kind == "Pod" or .kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet" or .kind == "ReplicaSet" or .kind == "ReplicationController" or .kind == "Job" or .kind == "CronJob")'
        & yq eval $kindFilter $productionRender |
            Set-Content -LiteralPath $workloadRender -Encoding utf8NoBOM
        Assert-LastExitCode "Filter production workload render"

        Invoke-Kubectl @("get", "namespace", "techx-corp-prod") 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Invoke-Kubectl @("create", "namespace", "techx-corp-prod") | Out-Host
            Assert-LastExitCode "Create production test namespace"
        }

        Invoke-Kubectl @("apply", "--dry-run=server", "-f", $workloadRender) | Out-Null
        Assert-LastExitCode "Production workload render admission inventory"
        Write-Output "PASS production workload render: zero VAP denials"
    }
    finally {
        Remove-Item -LiteralPath $productionRender, $workloadRender -Force -ErrorAction SilentlyContinue
    }
}
finally {
    Pop-Location
}
