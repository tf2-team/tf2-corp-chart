[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)][string]$KubeContext,
    [ValidateSet("ad", "recommendation")][string]$Dependency = "ad",
    [string]$Namespace = "techx-corp-prod",
    [int]$HoldSeconds = 60,
    [string]$ProbeUri = "",
    [string]$EvidenceDirectory = ""
)

$ErrorActionPreference = "Stop"
if ($HoldSeconds -lt 1) { throw "HoldSeconds must be positive" }
if (-not $EvidenceDirectory) {
    $EvidenceDirectory = Join-Path $PSScriptRoot "..\docs\evidence\mandate-17\dependency-$Dependency"
}
New-Item -ItemType Directory -Force -Path $EvidenceDirectory | Out-Null

$hpa = kubectl --context $KubeContext -n $Namespace get hpa $Dependency --ignore-not-found -o name
if ($hpa) {
    throw "${Dependency}: active HPA owns replicas; use the fixed-replica ad demo or pause HPA/Argo through an approved runbook"
}

$originalReplicas = kubectl --context $KubeContext -n $Namespace get deployment $Dependency `
    -o jsonpath='{.spec.replicas}'
if ($LASTEXITCODE -ne 0 -or -not $originalReplicas) { throw "Cannot read ${Dependency} replicas" }

kubectl --context $KubeContext -n $Namespace get deployment $Dependency -o yaml |
    Out-File -Encoding utf8 (Join-Path $EvidenceDirectory "deployment-before.yaml")

try {
    if (-not $PSCmdlet.ShouldProcess("$Namespace/deployment/$Dependency", "scale to zero for dependency chaos")) { return }
    kubectl --context $KubeContext -n $Namespace scale deployment $Dependency --replicas=0
    if ($LASTEXITCODE -ne 0) { throw "Failed to scale ${Dependency} to zero" }

    $samples = @()
    $deadline = (Get-Date).AddSeconds($HoldSeconds)
    do {
        if ($ProbeUri) {
            try {
                $response = Invoke-WebRequest -Uri $ProbeUri -TimeoutSec 5 -UseBasicParsing
                $samples += [pscustomobject]@{
                    time = (Get-Date).ToString("o")
                    status = $response.StatusCode
                    degraded = $response.Headers['X-TechX-Degraded-Dependencies']
                }
            }
            catch {
                $samples += [pscustomobject]@{ time = (Get-Date).ToString("o"); status = 0; degraded = "" }
            }
        }
        Start-Sleep -Seconds ([Math]::Min(5, $HoldSeconds))
    } while ((Get-Date) -lt $deadline)

    if ($ProbeUri) {
        $samples | ConvertTo-Json | Out-File -Encoding utf8 (Join-Path $EvidenceDirectory "probe-samples.json")
        $failed = @($samples | Where-Object { $_.status -ne 200 -or $_.degraded -notmatch $Dependency })
        if ($failed.Count -gt 0) { throw "Fallback probe failed for $($failed.Count) sample(s)" }
    }
}
finally {
    kubectl --context $KubeContext -n $Namespace scale deployment $Dependency --replicas=$originalReplicas
    kubectl --context $KubeContext -n $Namespace rollout status deployment $Dependency --timeout=5m
}
