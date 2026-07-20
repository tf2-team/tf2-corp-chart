<#
.SYNOPSIS
    MANDATE 10 (Secure Delivery Pipeline) — full provenance trace for a running pod.

.DESCRIPTION
    Given a Pod name, walks the supply chain backwards end-to-end:
      running Pod -> container image ref -> immutable digest
        -> Cosign signature verification (KMS key)
        -> SBOM attestation (CycloneDX)
        -> provenance attestation (commit, PR, approver, scan results, signer)
    This is the artifact mentor's DoD check #3 asks for: "chỉ vào một pod đang
    chạy -> team truy ngược full provenance ngay trước mặt."

    Requires: kubectl (cluster context configured), cosign, jq, AWS credentials
    with kms:GetPublicKey on the signing key (same permissions granted to
    policy-controller by tf2-corp-infra modules/policy-controller-irsa).

.PARAMETER PodName
    Name of a running Pod to trace.

.PARAMETER Namespace
    Namespace the pod lives in. Default: techx-corp-prod.

.PARAMETER ContainerName
    Optional: trace one specific container in a multi-container pod. Default:
    the pod's first container.

.PARAMETER CosignKey
    Cosign key reference used to verify signatures/attestations. Default
    matches the alias tf2-corp-platform signs with (awskms:///alias/tf2-cosign-signing-key).

.PARAMETER ProvenanceType
    In-toto predicate type used by build-and-push.yml's provenance attest step.

.PARAMETER KubeContext
    Optional kubectl context override.

.EXAMPLE
    ./scripts/trace-provenance.ps1 -PodName checkout-7d9f8c6b4-abcde -Namespace techx-corp-prod
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PodName,

    [string]$Namespace = "techx-corp-prod",

    [string]$ContainerName,

    [string]$CosignKey = "awskms:///alias/tf2-cosign-signing-key",

    [string]$ProvenanceType = "https://techx-corp.dev/attestations/provenance/v1",

    [string]$KubeContext
)

$ErrorActionPreference = "Stop"

function Assert-Tool {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required tool '$Name' not found on PATH. Install it before running this script."
    }
}

function Invoke-Kubectl {
    param([string[]]$Arguments)
    $allArgs = @()
    if ($KubeContext) { $allArgs += @("--context", $KubeContext) }
    $allArgs += $Arguments
    & kubectl @allArgs
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "=== $Title ===" -ForegroundColor Cyan
}

function Write-KeyValue {
    param([string]$Key, [string]$Value, [string]$Color = "White")
    Write-Host ("  {0,-22}: " -f $Key) -NoNewline -ForegroundColor DarkGray
    Write-Host $Value -ForegroundColor $Color
}

Assert-Tool kubectl
Assert-Tool cosign
Assert-Tool jq

$report = [ordered]@{
    pod            = "$Namespace/$PodName"
    container      = $null
    image_ref      = $null
    digest         = $null
    signature      = $null
    provenance     = $null
    sbom           = $null
    errors         = @()
}

# ── 1. Pod -> container image ref (must already be digest-pinned by VAP) ──

Write-Section "1. Resolve container image from running Pod"

$podJson = Invoke-Kubectl @("get", "pod", $PodName, "-n", $Namespace, "-o", "json")
if ($LASTEXITCODE -ne 0 -or -not $podJson) {
    throw "Could not read pod $Namespace/$PodName. Check the pod name/namespace and kubectl context."
}
$pod = $podJson | ConvertFrom-Json

$containers = @($pod.spec.containers)
if ($containers.Count -eq 0) {
    throw "Pod $Namespace/$PodName has no containers."
}
$targetContainer = if ($ContainerName) {
    $containers | Where-Object { $_.name -eq $ContainerName } | Select-Object -First 1
} else {
    $containers[0]
}
if (-not $targetContainer) {
    throw "Container '$ContainerName' not found in pod $Namespace/$PodName. Available: $($containers.name -join ', ')"
}

# Prefer the live status image (kubelet-resolved, always includes digest once running)
# over spec.image (may still show the pre-resolution ref on some client versions).
$statusContainer = @($pod.status.containerStatuses) | Where-Object { $_.name -eq $targetContainer.name } | Select-Object -First 1
$imageRef = if ($statusContainer -and $statusContainer.imageID) { $statusContainer.imageID -replace '^docker-pullable://', '' } else { $targetContainer.image }

$report.container = $targetContainer.name
$report.image_ref = $imageRef
Write-KeyValue "Pod" "$Namespace/$PodName"
Write-KeyValue "Container" $targetContainer.name
Write-KeyValue "Image ref" $imageRef

if ($imageRef -notmatch '@sha256:[0-9a-fA-F]{64}$') {
    $msg = "Image is not pinned by digest ($imageRef). MANDATE-10 VAP should have rejected this at admission — investigate immediately."
    Write-Host "  WARNING: $msg" -ForegroundColor Yellow
    $report.errors += $msg
} else {
    $report.digest = ($imageRef -split '@')[-1]
    Write-KeyValue "Digest" $report.digest
}

# ── 2. Signature verification (Cosign + KMS) ───────────────────────────────

Write-Section "2. Verify Cosign signature (KMS key: $CosignKey)"

$sigOutput = & cosign verify --key $CosignKey $imageRef 2>&1
$sigOk = ($LASTEXITCODE -eq 0)
if ($sigOk) {
    Write-KeyValue "Signature" "VERIFIED" "Green"
    $report.signature = "verified"
} else {
    Write-Host "  Signature verification FAILED:" -ForegroundColor Red
    Write-Host ($sigOutput | Out-String)
    $report.signature = "FAILED"
    $report.errors += "cosign verify failed for $imageRef"
}

# ── 3. Provenance attestation (commit, PR, approver, scan results, signer) ─

Write-Section "3. Provenance attestation (commit / PR approver / scans / signer)"

$provOutput = & cosign verify-attestation --key $CosignKey --type $ProvenanceType $imageRef 2>&1
if ($LASTEXITCODE -eq 0) {
    # cosign verify-attestation prints one JSON envelope per line; predicate is
    # base64 in .payload (in-toto Statement JSON).
    $envelopeLine = ($provOutput | Where-Object { $_ -match '^\{' } | Select-Object -Last 1)
    if ($envelopeLine) {
        $envelope = $envelopeLine | ConvertFrom-Json
        $payloadJson = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($envelope.payload))
        $statement = $payloadJson | ConvertFrom-Json
        $predicate = $statement.predicate

        Write-KeyValue "Commit" $predicate.commit
        Write-KeyValue "PR number" "$($predicate.pr_number)"
        Write-KeyValue "PR approved by" $predicate.pr_approved_by
        Write-KeyValue "Signer (KMS key)" $predicate.signer
        Write-KeyValue "Workflow run" $predicate.workflow_run_url
        Write-Host "  Scan results:" -ForegroundColor DarkGray
        $predicate.scans.PSObject.Properties | ForEach-Object {
            $color = if ($_.Value -eq "pass") { "Green" } else { "Red" }
            Write-KeyValue ("    " + $_.Name) $_.Value $color
        }

        $report.provenance = $predicate
    } else {
        Write-Host "  Could not parse provenance attestation output." -ForegroundColor Yellow
        $report.errors += "provenance attestation present but unparsable"
    }
} else {
    Write-Host "  No provenance attestation found or verification failed:" -ForegroundColor Red
    Write-Host ($provOutput | Out-String)
    $report.errors += "cosign verify-attestation (provenance) failed for $imageRef"
}

# ── 4. SBOM attestation (CycloneDX) ────────────────────────────────────────

Write-Section "4. SBOM attestation (CycloneDX)"

$sbomOutput = & cosign verify-attestation --key $CosignKey --type cyclonedx $imageRef 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-KeyValue "SBOM attestation" "PRESENT (CycloneDX)" "Green"
    $report.sbom = "present"
} else {
    Write-Host "  No SBOM attestation found or verification failed:" -ForegroundColor Red
    Write-Host ($sbomOutput | Out-String)
    $report.sbom = "MISSING"
    $report.errors += "cosign verify-attestation (cyclonedx SBOM) failed for $imageRef"
}

# ── Summary ─────────────────────────────────────────────────────────────

Write-Section "Summary"
$report | ConvertTo-Json -Depth 6 | Write-Output

if ($report.errors.Count -gt 0) {
    Write-Host ""
    Write-Host "TRACE INCOMPLETE — $($report.errors.Count) issue(s):" -ForegroundColor Red
    $report.errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

Write-Host ""
Write-Host "Full provenance chain verified: pod -> digest -> signature -> commit -> PR approver -> scans -> SBOM." -ForegroundColor Green
exit 0
