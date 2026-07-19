[CmdletBinding()]
param(
    [string]$KubeContext,
    [string[]]$ExcludedNamespaces = @()
)

$ErrorActionPreference = "Stop"

function Test-Property {
    param(
        [object]$Object,
        [string]$Name
    )

    return $null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]
}

function Get-PodSpec {
    param([object]$Item)

    switch ($Item.kind) {
        "Pod" { return $Item.spec }
        "CronJob" { return $Item.spec.jobTemplate.spec.template.spec }
        default { return $Item.spec.template.spec }
    }
}

function Test-FixedImage {
    param([string]$Image)

    if ($Image -match '^.+@sha256:[0-9A-Fa-f]{64}$') {
        return $true
    }

    return $Image -match '^[^@]+:[^/:@]+$' -and $Image -notmatch '(?i):latest$'
}

function Add-Violation {
    param(
        [System.Collections.Generic.List[object]]$Violations,
        [object]$Item,
        [object]$RootOwner,
        [string]$ContainerType,
        [object]$Container,
        [string]$Rule
    )

    $ruleId = switch ($Rule) {
        "effective runAsNonRoot is not true" { "NON_ROOT" }
        "effective runAsUser is 0" { "UID_0" }
        "capabilities.drop does not contain ALL" { "DROP_ALL" }
        "capabilities.add is not empty" { "ADDED_CAPS" }
        "container is privileged" { "PRIVILEGED" }
        "allowPrivilegeEscalation is not false" { "PRIV_ESC" }
        "hostNetwork is enabled" { "HOST_NETWORK" }
        "hostPID is enabled" { "HOST_PID" }
        "hostIPC is enabled" { "HOST_IPC" }
        "hostPath volume is present" { "HOST_PATH" }
        "image is latest, untagged, or has an invalid digest" { "IMAGE_PIN" }
        "CPU/memory requests or limits are missing" { "RESOURCES" }
        default { "UNKNOWN" }
    }

    $Violations.Add([pscustomobject]@{
        Namespace      = $Item.metadata.namespace
        Kind           = $Item.kind
        Workload       = $Item.metadata.name
        ObjectKey      = "$($Item.metadata.namespace)/$($Item.kind)/$($Item.metadata.name)"
        RootNamespace  = $RootOwner.Namespace
        RootKind       = $RootOwner.Kind
        RootWorkload   = $RootOwner.Name
        RootKey        = "$($RootOwner.Namespace)/$($RootOwner.Kind)/$($RootOwner.Name)"
        IsRootObject   = $RootOwner.Uid -eq [string]$Item.metadata.uid
        ContainerType  = $ContainerType
        Container      = $Container.name
        RuleId          = $ruleId
        Rule           = $Rule
    })
}

function Get-ControllerOwnerReference {
    param([object]$Item)

    $owners = @($Item.metadata.ownerReferences)
    if ($owners.Count -eq 0 -or $null -eq $owners[0]) {
        return $null
    }

    $controller = @($owners | Where-Object { $_.controller -eq $true } | Select-Object -First 1)
    if ($controller.Count -gt 0) {
        return $controller[0]
    }

    return $owners[0]
}

function Get-RootOwner {
    param(
        [object]$Item,
        [hashtable]$ItemsByUid
    )

    $current = $Item
    $visited = [System.Collections.Generic.HashSet[string]]::new()

    while ($null -ne $current) {
        $currentUid = [string]$current.metadata.uid
        if ($currentUid -and -not $visited.Add($currentUid)) {
            break
        }

        $owner = Get-ControllerOwnerReference -Item $current
        if ($null -eq $owner) {
            break
        }

        $ownerUid = [string]$owner.uid
        if (-not $ownerUid -or -not $ItemsByUid.ContainsKey($ownerUid)) {
            return [pscustomobject]@{
                Namespace = [string]$current.metadata.namespace
                Kind      = [string]$owner.kind
                Name      = [string]$owner.name
                Uid       = $ownerUid
            }
        }

        $current = $ItemsByUid[$ownerUid]
    }

    return [pscustomobject]@{
        Namespace = [string]$current.metadata.namespace
        Kind      = [string]$current.kind
        Name      = [string]$current.metadata.name
        Uid       = [string]$current.metadata.uid
    }
}

$kubectlArgs = @()
if ($KubeContext) {
    $kubectlArgs += @("--context", $KubeContext)
}
$kubectlArgs += @(
    "get",
    "pods,deployments.apps,statefulsets.apps,daemonsets.apps,replicasets.apps,replicationcontrollers,jobs.batch,cronjobs.batch",
    "--all-namespaces",
    "-o",
    "json"
)

$rawInventory = & kubectl @kubectlArgs
if ($LASTEXITCODE -ne 0) {
    throw "kubectl inventory failed with exit code $LASTEXITCODE"
}

$inventory = $rawInventory -join "`n" | ConvertFrom-Json -Depth 100
$violations = [System.Collections.Generic.List[object]]::new()
$checkedWorkloads = 0
$checkedContainers = 0
$itemsByUid = @{}

foreach ($item in $inventory.items) {
    $uid = [string]$item.metadata.uid
    if ($uid) {
        $itemsByUid[$uid] = $item
    }
}

foreach ($item in $inventory.items) {
    if ($item.metadata.namespace -in $ExcludedNamespaces) {
        continue
    }

    $checkedWorkloads++
    $rootOwner = Get-RootOwner -Item $item -ItemsByUid $itemsByUid
    $podSpec = Get-PodSpec -Item $item
    $podSpecSubject = [pscustomobject]@{ name = "<pod-spec>" }

    if ((Test-Property $podSpec "hostNetwork") -and $podSpec.hostNetwork -eq $true) {
        Add-Violation $violations $item $rootOwner "podSpec" $podSpecSubject "hostNetwork is enabled"
    }
    if ((Test-Property $podSpec "hostPID") -and $podSpec.hostPID -eq $true) {
        Add-Violation $violations $item $rootOwner "podSpec" $podSpecSubject "hostPID is enabled"
    }
    if ((Test-Property $podSpec "hostIPC") -and $podSpec.hostIPC -eq $true) {
        Add-Violation $violations $item $rootOwner "podSpec" $podSpecSubject "hostIPC is enabled"
    }
    foreach ($volume in @($podSpec.volumes)) {
        if ($null -ne $volume -and (Test-Property $volume "hostPath")) {
            Add-Violation $violations $item $rootOwner "podSpec" $podSpecSubject "hostPath volume is present"
        }
    }

    $containerGroups = @(
        @{ Type = "container"; Items = @($podSpec.containers); RequireResources = $true },
        @{ Type = "initContainer"; Items = @($podSpec.initContainers); RequireResources = $true },
        @{ Type = "ephemeralContainer"; Items = @($podSpec.ephemeralContainers); RequireResources = $false }
    )

    foreach ($group in $containerGroups) {
        foreach ($container in $group.Items) {
            if ($null -eq $container) {
                continue
            }

            $checkedContainers++
            $containerSecurity = $container.securityContext
            $podSecurity = $podSpec.securityContext

            $runAsNonRoot = if (Test-Property $containerSecurity "runAsNonRoot") {
                $containerSecurity.runAsNonRoot
            }
            elseif (Test-Property $podSecurity "runAsNonRoot") {
                $podSecurity.runAsNonRoot
            }
            else {
                $false
            }

            if ($runAsNonRoot -ne $true) {
                Add-Violation $violations $item $rootOwner $group.Type $container "effective runAsNonRoot is not true"
            }

            $runAsUser = if (Test-Property $containerSecurity "runAsUser") {
                $containerSecurity.runAsUser
            }
            elseif (Test-Property $podSecurity "runAsUser") {
                $podSecurity.runAsUser
            }
            else {
                $null
            }

            if ($runAsUser -eq 0) {
                Add-Violation $violations $item $rootOwner $group.Type $container "effective runAsUser is 0"
            }

            $drops = if (Test-Property $containerSecurity.capabilities "drop") {
                @($containerSecurity.capabilities.drop)
            }
            else {
                @()
            }
            if ($drops -notcontains "ALL") {
                Add-Violation $violations $item $rootOwner $group.Type $container "capabilities.drop does not contain ALL"
            }

            $adds = if (Test-Property $containerSecurity.capabilities "add") {
                @($containerSecurity.capabilities.add)
            }
            else {
                @()
            }
            if ($adds.Count -gt 0) {
                Add-Violation $violations $item $rootOwner $group.Type $container "capabilities.add is not empty"
            }

            if ((Test-Property $containerSecurity "privileged") -and $containerSecurity.privileged -eq $true) {
                Add-Violation $violations $item $rootOwner $group.Type $container "container is privileged"
            }

            if (-not (Test-Property $containerSecurity "allowPrivilegeEscalation") -or
                $containerSecurity.allowPrivilegeEscalation -ne $false) {
                Add-Violation $violations $item $rootOwner $group.Type $container "allowPrivilegeEscalation is not false"
            }

            if (-not (Test-FixedImage -Image $container.image)) {
                Add-Violation $violations $item $rootOwner $group.Type $container "image is latest, untagged, or has an invalid digest"
            }

            if ($group.RequireResources) {
                $resources = $container.resources
                $hasResources =
                    (Test-Property $resources "requests") -and
                    (Test-Property $resources.requests "cpu") -and
                    (Test-Property $resources.requests "memory") -and
                    (Test-Property $resources "limits") -and
                    (Test-Property $resources.limits "cpu") -and
                    (Test-Property $resources.limits "memory")

                if (-not $hasResources) {
                    Add-Violation $violations $item $rootOwner $group.Type $container "CPU/memory requests or limits are missing"
                }
            }
        }
    }
}

if ($violations.Count -gt 0) {
    $remediationGroups = @(
        $violations |
            Group-Object -Property {
                "$($_.RootKey)`u{001f}$($_.ContainerType)`u{001f}$($_.Container)`u{001f}$($_.RuleId)"
            } |
            ForEach-Object {
                $entries = @($_.Group)
                $first = $entries[0]
                $affectedObjects = @($entries.ObjectKey | Sort-Object -Unique)
                $affectedKinds = @($entries.Kind | Sort-Object -Unique)
                $affectedPods = @(
                    $entries |
                        Where-Object { $_.Kind -eq "Pod" } |
                        Select-Object -ExpandProperty ObjectKey -Unique
                )
                $rootTemplateViolation = @($entries | Where-Object { $_.IsRootObject }).Count -gt 0

                [pscustomobject]@{
                    Namespace       = $first.RootNamespace
                    RootOwner       = "$($first.RootKind)/$($first.RootWorkload)"
                    RootKey         = $first.RootKey
                    ContainerType   = $first.ContainerType
                    Container       = $first.Container
                    RuleId          = $first.RuleId
                    Rule            = $first.Rule
                    RawViolations   = $entries.Count
                    Objects         = $affectedObjects.Count
                    RunningPods     = $affectedPods.Count
                    ObjectKinds     = $affectedKinds -join ","
                    RuntimeDrift    = (-not $rootTemplateViolation) -and $affectedObjects.Count -gt 0
                }
            }
    )

    $remediationGroups |
        Sort-Object Namespace, RootOwner, ContainerType, Container, RuleId |
        Format-Table `
            @{ Label = "Root"; Expression = { $_.RootKey } },
            Container,
            RuleId,
            @{ Label = "Raw"; Expression = { $_.RawViolations } },
            @{ Label = "Objects"; Expression = { $_.Objects } },
            @{ Label = "Pods"; Expression = { $_.RunningPods } },
            @{ Label = "Drift"; Expression = { $_.RuntimeDrift } } `
            -AutoSize

    $violatingObjectCount = @($violations.ObjectKey | Sort-Object -Unique).Count
    $violatingPodCount = @(
        $violations |
            Where-Object { $_.Kind -eq "Pod" } |
            Select-Object -ExpandProperty ObjectKey -Unique
    ).Count
    $runtimeDriftCount = @($remediationGroups | Where-Object { $_.RuntimeDrift }).Count

    throw (
        "Runtime-hardening inventory failed: {0} raw violation(s) across {1} violating object(s), " +
        "grouped into {2} remediation group(s); {3} running Pod(s) violate and {4} group(s) are runtime drift. " +
        "Checked {5} workload object(s) and {6} container(s)."
    ) -f @(
        $violations.Count,
        $violatingObjectCount,
        $remediationGroups.Count,
        $violatingPodCount,
        $runtimeDriftCount,
        $checkedWorkloads,
        $checkedContainers
    )
}

Write-Output "PASS runtime-hardening inventory: $checkedWorkloads workload objects and $checkedContainers containers checked; zero violations."
