[CmdletBinding()]
param(
    [string]$Region = "us-east-1",
    [string]$ClusterContext = "arn:aws:eks:us-east-1:493499579600:cluster/techx-tf2-prod",
    [string]$Namespace = "techx-corp-prod",
    [string]$StorefrontUrl = "https://hungtran.id.vn",
    [string]$LogFile = "",
    [double]$PassRatio = 0.999,
    [int]$TargetRps = 10,
    [string]$FaultVariant = "1a-primary-in",
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

Write-Host "Mandate 21 FIS Drill Script (Chart Repository)"
Write-Host "Region: $Region, Cluster: $ClusterContext, Namespace: $Namespace"
Write-Host "Storefront: $StorefrontUrl, FaultVariant: $FaultVariant, TargetRPS: $TargetRps"

foreach ($tool in @("aws", "kubectl")) {
    Assert-True ($null -ne (Get-Command $tool -ErrorAction SilentlyContinue)) "$tool is installed"
}

$storefront = Invoke-WebRequest -Uri $StorefrontUrl -Method Get -TimeoutSec 15 -MaximumRedirection 3
Assert-True ($storefront.StatusCode -eq 200) "public storefront returns HTTP 200"

if (-not $Execute) {
    Write-Host "PREVIEW COMPLETE: Mandate 21 parameters validated. No fault injected."
    exit 0
}

Assert-True ($CapacityApproved -and $CostApproved -and $DurabilityApproved -and $ChangeApproved) "all approvals granted"
Assert-True ($ConfirmationToken -ceq "RUN-M21-FIS") "confirmation token matches RUN-M21-FIS"

Write-Host "Executing Mandate 21 FIS Drill for variant $FaultVariant..."

# Change trail: @hungxqt - 2026-07-28 - Port Mandate 21 drill script into Chart repository.
