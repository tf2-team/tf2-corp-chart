[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PodName,

    [Parameter(Mandatory = $false)]
    [string]$Namespace = "techx-corp-prod"
)

Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "TRACE PROVENANCE FOR POD: $PodName IN NAMESPACE: $Namespace" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan

# 1. Fetch Pod Info
try {
    $pod = kubectl get pod $PodName -n $Namespace -o json | ConvertFrom-Json
} catch {
    Write-Error "Failed to fetch pod info via kubectl. Make sure kubectl is installed, configured, and namespace/pod names are correct."
    exit 1
}

if (-not $pod) {
    Write-Error "Pod $PodName not found in namespace $Namespace."
    exit 1
}

# 2. Extract Container Images
$containers = $pod.status.containerStatuses
if (-not $containers) {
    Write-Warning "No container statuses found yet. Is the pod starting up?"
    exit 0
}

foreach ($c in $containers) {
    Write-Host "`n[Container: $($c.name)]" -ForegroundColor Green
    $imageID = $c.imageID
    $imageName = $c.image

    Write-Host "  Image Name: $imageName"
    Write-Host "  Image ID:   $imageID"

    # Check if using digest
    if ($imageID -match "@sha256:([0-9a-fA-F]{64})") {
        $digest = $Matches[0]
        # Build exact ECR Image Ref (strip tag if present, replace with digest)
        $baseImage = $imageName.Split(":")[0]
        $imageRef = "$baseImage$digest"
        Write-Host "  Detected Digest: $digest" -ForegroundColor White
        Write-Host "  Image Ref for Cosign: $imageRef"
    } else {
        Write-Host "  [WARNING] Container is not running with an image digest! Violates VAP rules!" -ForegroundColor Yellow
        continue
    }

    # 3. Verify Cosign Signature
    Write-Host "  --> Verifying Cosign Signature using AWS KMS..." -ForegroundColor Gray
    $sigVerify = & cosign verify --key awskms:///alias/tf2-cosign-signing-key $imageRef 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [SUCCESS] Signature verified successfully against KMS key!" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] Failed to verify image signature! Image is unsigned or signed with wrong key." -ForegroundColor Red
        continue
    }

    # 4. Fetch and Parse Attestations (SBOM & Custom Provenance)
    Write-Host "  --> Fetching Cosign Attestations (SBOM & Provenance)..." -ForegroundColor Gray
    $attestationsRaw = & cosign verify-attestation --key awskms:///alias/tf2-cosign-signing-key $imageRef 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $attestationsRaw) {
        Write-Host "  [WARNING] No attestations found for this image." -ForegroundColor Yellow
        continue
    }

    $attIndex = 0
    foreach ($line in $attestationsRaw) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $att = $line | ConvertFrom-Json
            $payloadBytes = [System.Convert]::FromBase64String($att.payload)
            $payloadText = [System.Text.Encoding]::UTF8.GetString($payloadBytes)
            $payload = $payloadText | ConvertFrom-Json

            $predicateType = $payload.predicateType
            Write-Host "  [Attestation #$attIndex] Type: $predicateType" -ForegroundColor Cyan

            if ($predicateType -match "cosign.sigstore.dev/attestation/v1") {
                # SBOM Attestation
                Write-Host "    Format: SBOM (CycloneDX / SPDX)" -ForegroundColor White
                Write-Host "    Details: SBOM attached successfully in ECR."
            } elseif ($predicateType -match "slsa|provenance|custom") {
                # Provenance Attestation
                Write-Host "    Format: Custom Provenance (SLSA-like)" -ForegroundColor White
                $pred = $payload.predicate
                Write-Host "    - Commit SHA:  $($pred.gitCommit)" -ForegroundColor White
                Write-Host "    - PR Number:   $($pred.pullRequest)" -ForegroundColor White
                Write-Host "    - Approver:    $($pred.approver)" -ForegroundColor White
                Write-Host "    - Scan Status: $($pred.scanStatus)" -ForegroundColor White
            } else {
                Write-Host "    Raw Predicate type: $predicateType"
            }
            $attIndex++
        } catch {
            Write-Host "    [WARNING] Failed to parse attestation line: $_" -ForegroundColor Yellow
        }
    }
}
