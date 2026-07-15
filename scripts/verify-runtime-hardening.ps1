[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$negativeValues = Join-Path $repoRoot "tests/runtime-hardening/invalid-init-container-resources.yaml"
$suite = "gitops/gatekeeper/tests/suite.yaml"

function Assert-LastExitCode {
    param([string]$Step)

    if ($LASTEXITCODE -ne 0) {
        throw "$Step failed with exit code $LASTEXITCODE"
    }
}

Push-Location $repoRoot
try {
    & helm lint . -f values.yaml -f values-public-alb.yaml -f values-prod.yaml
    Assert-LastExitCode "Positive Helm lint"

    & helm lint gatekeeper-chart
    Assert-LastExitCode "Gatekeeper Helm lint"

    $gatekeeperRender = & helm template gatekeeper gatekeeper-chart `
        --namespace gatekeeper-system
    Assert-LastExitCode "Gatekeeper Helm render"
    $gatekeeperText = $gatekeeperRender -join "`n"
    if ($gatekeeperText -notmatch "(?m)^kind:\s+ValidatingWebhookConfiguration\s*$") {
        throw "Gatekeeper render is missing the validating webhook"
    }
    if ($gatekeeperText -notmatch "(?m)^\s*failurePolicy:\s*Fail\s*$") {
        throw "Gatekeeper validating webhook must fail closed"
    }

    $negativeOutput = & helm lint . `
        -f values.yaml `
        -f values-public-alb.yaml `
        -f values-prod.yaml `
        -f $negativeValues 2>&1
    $negativeExitCode = $LASTEXITCODE
    $negativeText = $negativeOutput -join "`n"

    if ($negativeExitCode -eq 0) {
        throw "Negative schema test unexpectedly passed"
    }
    if ($negativeText -notmatch "additional properties 'typo' not allowed") {
        throw "Negative schema test failed for an unexpected reason:`n$negativeText"
    }
    Write-Output "Negative schema test passed: invalid initContainerResources key was rejected."

    $null = & kubectl kustomize gitops/gatekeeper
    Assert-LastExitCode "Gatekeeper Kustomize render"

    $dryrunOutput = New-TemporaryFile
    try {
        & (Join-Path $PSScriptRoot "render-gatekeeper-dryrun.ps1") `
            -OutputPath $dryrunOutput.FullName
        Assert-LastExitCode "Temporary dryrun render"

        $dryrunText = Get-Content -Raw -LiteralPath $dryrunOutput.FullName
        $dryrunCount = [regex]::Matches(
            $dryrunText,
            "(?m)^\s*enforcementAction:\s*dryrun\s*$"
        ).Count
        if ($dryrunCount -ne 3) {
            throw "Temporary render must contain exactly 3 dryrun constraints"
        }
    }
    finally {
        Remove-Item -LiteralPath $dryrunOutput.FullName -Force -ErrorAction SilentlyContinue
    }

    $productionRender = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        ("mandate5-production-{0}.yaml" -f [guid]::NewGuid())
    try {
        & helm template techx-corp . `
            --namespace techx-corp-prod `
            -f values-public-alb.yaml `
            -f values-prod.yaml |
            Set-Content -LiteralPath $productionRender -Encoding utf8NoBOM
        Assert-LastExitCode "Production Helm render"

        & go run github.com/open-policy-agent/gatekeeper/v3/cmd/gator@v3.23.0 test `
            -f $productionRender `
            -f gitops/gatekeeper/templates `
            -f gitops/gatekeeper/constraints `
            --deny-only
        Assert-LastExitCode "Production render policy audit"
        Write-Output "Production render policy audit passed: zero denied resources."
    }
    finally {
        Remove-Item -LiteralPath $productionRender -Force -ErrorAction SilentlyContinue
    }

    & go run github.com/open-policy-agent/gatekeeper/v3/cmd/gator@v3.23.0 verify $suite
    Assert-LastExitCode "Gator policy suite"
}
finally {
    Pop-Location
}
