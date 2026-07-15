[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot

Push-Location $repoRoot
try {
    $rendered = & kubectl kustomize gitops/gatekeeper
    if ($LASTEXITCODE -ne 0) {
        throw "Gatekeeper Kustomize render failed with exit code $LASTEXITCODE"
    }

    $renderedText = $rendered -join "`n"
    $denyPattern = "(?m)^(\s*enforcementAction:\s*)deny\s*$"
    $denyCount = [regex]::Matches($renderedText, $denyPattern).Count
    if ($denyCount -ne 3) {
        throw "Expected exactly 3 deny constraints, found $denyCount"
    }

    $dryrunText = [regex]::Replace($renderedText, $denyPattern, '${1}dryrun')
    $dryrunCount = [regex]::Matches(
        $dryrunText,
        "(?m)^\s*enforcementAction:\s*dryrun\s*$"
    ).Count
    if ($dryrunCount -ne 3) {
        throw "Expected exactly 3 dryrun constraints, found $dryrunCount"
    }

    Set-Content -LiteralPath $OutputPath -Value $dryrunText -Encoding utf8NoBOM
    Write-Output "Rendered temporary dryrun policy to $OutputPath"
}
finally {
    Pop-Location
}
