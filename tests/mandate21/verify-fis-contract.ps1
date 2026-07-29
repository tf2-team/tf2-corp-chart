$ErrorActionPreference = "Stop"; Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot "../../scripts/mandate21-fis-contract.psm1") -Force
function Assert-True([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "ASSERTION FAILED: $Message" } }
$a = [pscustomobject]@{ z = 1; a = [pscustomobject]@{ y = 2; x = 3 } }; $b = [pscustomobject]@{ a = [pscustomobject]@{ x = 3; y = 2 }; z = 1 }
Assert-True ((Get-Mandate21Sha256 $a) -eq (Get-Mandate21Sha256 $b)) "canonical hash must ignore property insertion order"
$contract = Get-Content -Raw (Join-Path $PSScriptRoot "../../scripts/mandate21-fis-contract.json") | ConvertFrom-Json -Depth 50
Assert-Mandate21Contract $contract | Out-Null
$map = Get-Mandate21VariantMap $contract
$expected = @('EXT2UboGoZ7ErXaQ','EXT2cGQZ1Hb4HKCC','EXTDqvVeTfQiN7zBS','EXT34dobGM9bVqZ2')
Assert-True (@($map.Values).Count -eq 4) "four variants required"
for ($i=0; $i -lt 4; $i++) { Assert-True (@($map.Values)[$i] -eq $expected[$i]) "live template order $i" }
$bad = $contract | ConvertTo-Json -Depth 50 | ConvertFrom-Json -Depth 50; $bad.region = 'us-west-2'
try { Assert-Mandate21Contract $bad | Out-Null; throw 'wrong region accepted' } catch { Assert-True ($_.Exception.Message -ne 'wrong region accepted') "wrong region rejected" }
$fixtureContract = $contract | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100
$variant = '1a-primary-in'
$template = [pscustomobject]@{ id=$fixtureContract.templateRevisions.$variant.templateId; lastUpdateTime='t'; experimentOptions=[pscustomobject]@{emptyTargetResolutionMode='fail'}; tags=[pscustomobject]@{CleanupPolicy='fis-native-verify-v1'}; stopConditions=@($fixtureContract.requiredStopAlarmArns | ForEach-Object {[pscustomobject]@{source='aws:cloudwatch:alarm';value=$_}}); targets=[pscustomobject]@{safe=$true}; actions=[pscustomobject]@{safe=$true} }
$fixtureContract.templateRevisions.$variant.revisionSha256=Get-Mandate21Sha256 $template
Assert-Mandate21LiveTemplate -Contract $fixtureContract -Variant $variant -Template $template | Out-Null
$template.targets.safe=$false
try { Assert-Mandate21LiveTemplate -Contract $fixtureContract -Variant $variant -Template $template | Out-Null; throw 'target drift accepted' } catch { Assert-True ($_.Exception.Message -ne 'target drift accepted') "canonical target/action drift rejected" }$example = Get-Content -Raw (Join-Path $PSScriptRoot "../../scripts/mandate21-fis-contract.example.json") | ConvertFrom-Json -Depth 100
Assert-Mandate21Contract $example | Out-Null
$source = Get-Content -Raw (Join-Path $PSScriptRoot "../../scripts/sync-mandate21-fis-contract.ps1")
Assert-True (-not $source.Contains('Invoke-Expression')) "sync must not evaluate shell text"
Write-Host "FIS contract checks passed."

# Change trail: @hungxqt - 2026-07-29 - Added canonical hash, four-live-ID, context, and safe-sync contract checks.