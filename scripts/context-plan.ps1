[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Capability,

    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Target,

    [string]$ProfilePath = ''
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root
. (Join-Path $PSScriptRoot 'profile.ps1')

$policyRelativePath = 'scripts/context-capabilities-v1.json'
$outputRelativePath = 'build/ai'
$activePointerRelativePath = 'profiles/active-profile.txt'

function Get-ContextPropertyNames {
    param([Parameter(Mandatory = $true)][object]$Object)
    if ($Object -is [System.Collections.IDictionary]) {
        return @($Object.Keys | ForEach-Object { [string]$_ })
    }
    return @($Object.PSObject.Properties | ForEach-Object { $_.Name })
}

function Assert-ContextObjectShape {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Location,
        [Parameter(Mandatory = $true)][string[]]$Required
    )

    if ($Object -isnot [pscustomobject] -and $Object -isnot [System.Collections.IDictionary]) {
        throw "Context field '$Location' must be an object."
    }
    $actual = @(Get-ContextPropertyNames -Object $Object)
    foreach ($name in $Required) {
        if ($actual -notcontains $name) {
            throw "Context field '$Location' is missing required field '$name'."
        }
    }
    foreach ($name in $actual) {
        if ($Required -notcontains $name) {
            throw "Context field '$Location' contains unknown field '$name'."
        }
    }
}

function Assert-ContextString {
    param(
        [AllowEmptyString()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Location
    )
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        throw "Context field '$Location' must be a non-empty string."
    }
}

function Assert-ContextStringArray {
    param(
        [AllowEmptyCollection()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Location,
        [string[]]$Allowed = @()
    )

    if ($Value -is [string] -or $Value -isnot [System.Array]) {
        throw "Context field '$Location' must be an array."
    }
    $seen = @{}
    foreach ($item in @($Value)) {
        Assert-ContextString -Value $item -Location $Location
        $text = [string]$item
        if ($Allowed.Count -gt 0 -and $Allowed -notcontains $text) {
            throw "Context field '$Location' contains unsupported resource '$text'."
        }
        if ($seen.ContainsKey($text)) {
            throw "Context field '$Location' contains duplicate value '$text'."
        }
        $seen[$text] = $true
    }
}

function Assert-SafeContextPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Location
    )

    Assert-ContextString -Value $Path -Location $Location
    if ([System.IO.Path]::IsPathRooted($Path) -or $Path.StartsWith('/') -or
        $Path.Contains('\') -or $Path -match '(^|/)\.\.(/|$)' -or
        $Path.IndexOfAny(@([char]13, [char]10, [char]0)) -ge 0) {
        throw "Context path '$Location' must be a canonical project-relative path: $Path"
    }
}

function Read-ContextPolicy {
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = Resolve-ProfileProjectPath -Root $root -Path $Path -Location 'context_policy' -Kind File
    try {
        $policy = ([System.IO.File]::ReadAllText($full, [System.Text.Encoding]::UTF8) |
            ConvertFrom-Json)
    }
    catch {
        throw "Context capability policy is not valid JSON: $($_.Exception.Message)"
    }

    Assert-ContextObjectShape -Object $policy -Location '<policy>' -Required @(
        'schema_version', 'policy_id', 'capabilities'
    )
    if ([int]$policy.schema_version -ne 1) {
        throw "Unsupported context capability policy schema_version: $($policy.schema_version)"
    }
    if ([string]$policy.policy_id -ne 'document-authoring-capabilities-v1') {
        throw "Unsupported context capability policy id: $($policy.policy_id)"
    }

    $capabilities = @($policy.capabilities)
    $expectedIds = @(
        'edit-content', 'edit-references', 'edit-metadata',
        'design-structure', 'review-content'
    )
    if ($capabilities.Count -ne $expectedIds.Count) {
        throw 'Context capability policy must contain exactly the five v1 capabilities.'
    }

    $seen = @{}
    foreach ($entry in $capabilities) {
        Assert-ContextObjectShape -Object $entry -Location 'capabilities[]' -Required @(
            'id', 'purpose', 'editable', 'read_only'
        )
        Assert-ContextString -Value $entry.id -Location 'capabilities[].id'
        Assert-ContextString -Value $entry.purpose -Location 'capabilities[].purpose'
        $id = [string]$entry.id
        if ($expectedIds -notcontains $id) {
            throw "Unknown v1 capability in policy: $id"
        }
        if ($seen.ContainsKey($id)) {
            throw "Duplicate capability in policy: $id"
        }
        $seen[$id] = $true
        Assert-ContextStringArray -Value $entry.editable -Location "$id.editable" `
            -Allowed @('target', 'metadata', 'bibliography')
        Assert-ContextStringArray -Value $entry.read_only -Location "$id.read_only" `
            -Allowed @('target', 'metadata', 'bibliography', 'other_content')
    }
    foreach ($id in $expectedIds) {
        if (-not $seen.ContainsKey($id)) {
            throw "Context capability policy is missing required capability: $id"
        }
    }
    return $policy
}

function New-ContextResourceList {
    return ,(New-Object System.Collections.Generic.List[object])
}

function Add-ContextResource {
    param(
        [AllowEmptyCollection()][Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[object]]$List,
        [Parameter(Mandatory = $true)][hashtable]$Seen,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Reason
    )

    Assert-SafeContextPath -Path $Path -Location 'resource.path'
    if (-not $Seen.ContainsKey($Path)) {
        $List.Add([ordered]@{ path = $Path; reason = $Reason })
        $Seen[$Path] = $true
    }
}

function Get-ContextCapability {
    param(
        [Parameter(Mandatory = $true)][object]$Policy,
        [Parameter(Mandatory = $true)][string]$Id
    )

    $matches = @($Policy.capabilities | Where-Object { [string]$_.id -ceq $Id })
    if ($matches.Count -ne 1) {
        throw "Unknown capability '$Id'. Allowed values: $((@($Policy.capabilities.id)) -join ', ')."
    }
    return $matches[0]
}

function Get-ContextPlan {
    param(
        [Parameter(Mandatory = $true)][object]$Profile,
        [Parameter(Mandatory = $true)][object]$Policy,
        [Parameter(Mandatory = $true)][string]$PolicyDigest,
        [Parameter(Mandatory = $true)][object]$CapabilityEntry,
        [Parameter(Mandatory = $true)][string]$ContentTarget
    )

    $profileData = $Profile.Data
    $editable = New-ContextResourceList
    $readOnly = New-ContextResourceList
    $editableSeen = @{}
    $readOnlySeen = @{}
    $capabilityId = [string]$CapabilityEntry.id
    $instructionPath = "build/ai/capabilities/$capabilityId.md"

    $resources = @{
        target = [ordered]@{ path = $ContentTarget; reason = 'selected-content-target' }
        metadata = [ordered]@{ path = [string]$profileData.inputs.metadata; reason = 'document-context' }
        bibliography = [ordered]@{ path = [string]$profileData.inputs.bibliography; reason = 'active-bibliography-input' }
    }

    foreach ($symbol in @($CapabilityEntry.editable)) {
        $resource = $resources[[string]$symbol]
        Add-ContextResource -List $editable -Seen $editableSeen `
            -Path ([string]$resource.path) -Reason ([string]$resource.reason)
    }

    # R1.4a/context-plan-v1: these contracts are mandatory for every document-authoring capability.
    foreach ($base in @(
        [ordered]@{ path = 'AGENTS.md'; reason = 'agent-contract' },
        [ordered]@{ path = 'README.md'; reason = 'workflow-contract' },
        [ordered]@{ path = $activePointerRelativePath; reason = 'active-profile-selection' },
        [ordered]@{ path = [string]$Profile.ManifestPath; reason = 'profile-contract' },
        [ordered]@{ path = [string]$profileData.compliance.system_prompt; reason = 'authoring-contract' },
        [ordered]@{ path = [string]$profileData.compliance.requirements; reason = 'normative-constraints' },
        [ordered]@{ path = $instructionPath; reason = 'capability-context-instructions' }
    )) {
        Add-ContextResource -List $readOnly -Seen $readOnlySeen `
            -Path ([string]$base.path) -Reason ([string]$base.reason)
    }

    foreach ($symbol in @($CapabilityEntry.read_only)) {
        if ([string]$symbol -eq 'other_content') {
            foreach ($path in @($profileData.inputs.content)) {
                $contentPath = [string]$path
                if ($contentPath -cne $ContentTarget) {
                    Add-ContextResource -List $readOnly -Seen $readOnlySeen `
                        -Path $contentPath -Reason 'document-structure-context'
                }
            }
            continue
        }
        $resource = $resources[[string]$symbol]
        Add-ContextResource -List $readOnly -Seen $readOnlySeen `
            -Path ([string]$resource.path) -Reason ([string]$resource.reason)
    }

    foreach ($path in @($editableSeen.Keys)) {
        if ($readOnlySeen.ContainsKey($path)) {
            throw "Context policy made one path both editable and read-only: $path"
        }
    }

    $excluded = @(
        [ordered]@{ path = 'build/**'; reason = 'generated-artifact' },
        [ordered]@{ path = 'sources/**'; reason = 'normative-source-library' },
        [ordered]@{ path = 'scripts/**'; reason = 'engine-implementation' },
        [ordered]@{ path = 'schemas/**'; reason = 'engine-contract' },
        [ordered]@{ path = 'tests/**'; reason = 'test-implementation' },
        [ordered]@{ path = 'fixtures/**'; reason = 'test-fixture' },
        [ordered]@{ path = 'profiles/**'; reason = 'profile-implementation' },
        [ordered]@{ path = [string]$profileData.compliance.semantic_review; reason = 'protected-attestation' },
        [ordered]@{ path = [string]$profileData.compliance.external_acceptance; reason = 'protected-attestation' }
    )

    $transitions = @()
    foreach ($entry in @($Policy.capabilities)) {
        $nextId = [string]$entry.id
        if ($nextId -ceq $capabilityId) { continue }
        $aiderFile = "build/ai/switch/$nextId.aider"
        $transitions += [ordered]@{
            capability = $nextId
            purpose = [string]$entry.purpose
            command = "/load $aiderFile"
            plan_path = "build/ai/plans/$nextId.json"
            aider_file = $aiderFile
        }
    }

    return [ordered]@{
        schema = 'context-plan-v1'
        profile = [ordered]@{
            id = [string]$Profile.ProfileId
            digest = [string]$Profile.ProfileDigest
            manifest = [string]$Profile.ManifestPath
        }
        policy = [ordered]@{
            id = [string]$Policy.policy_id
            digest = $PolicyDigest
            source = $policyRelativePath
        }
        capability = $capabilityId
        target = $ContentTarget
        editable = $editable.ToArray()
        read_only = $readOnly.ToArray()
        excluded = @($excluded)
        transitions = @($transitions)
    }
}

function Assert-ContextPlan {
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][object]$Profile,
        [Parameter(Mandatory = $true)][object]$Policy,
        [switch]$RequireResourceFiles,
        [switch]$RequireTransitionFiles
    )

    Assert-ContextObjectShape -Object $Plan -Location '<context-plan>' -Required @(
        'schema', 'profile', 'policy', 'capability', 'target',
        'editable', 'read_only', 'excluded', 'transitions'
    )
    if ([string]$Plan.schema -ne 'context-plan-v1') {
        throw "Unsupported context plan schema: $($Plan.schema)"
    }
    Assert-ContextObjectShape -Object $Plan.profile -Location 'profile' -Required @('id', 'digest', 'manifest')
    Assert-ContextObjectShape -Object $Plan.policy -Location 'policy' -Required @('id', 'digest', 'source')
    if ([string]$Plan.profile.id -ne [string]$Profile.ProfileId -or
        [string]$Plan.profile.digest -ne [string]$Profile.ProfileDigest -or
        [string]$Plan.profile.manifest -ne [string]$Profile.ManifestPath) {
        throw 'Context plan profile provenance does not match the resolved active profile.'
    }
    $policyFull = Resolve-ProfileProjectPath -Root $root -Path $policyRelativePath `
        -Location 'context_policy' -Kind File
    if ([string]$Plan.policy.id -ne [string]$Policy.policy_id -or
        [string]$Plan.policy.source -ne $policyRelativePath -or
        [string]$Plan.policy.digest -ne (Get-ProfileSha256 -Path $policyFull)) {
        throw 'Context plan policy provenance does not match the capability policy.'
    }

    $capabilityEntry = Get-ContextCapability -Policy $Policy -Id ([string]$Plan.capability)
    $contentPaths = @($Profile.Data.inputs.content | ForEach-Object { [string]$_ })
    if ($contentPaths -cnotcontains [string]$Plan.target) {
        throw "Context plan target is not an active profile content input: $($Plan.target)"
    }

    $editablePaths = @()
    $readOnlyPaths = @()
    foreach ($groupName in @('editable', 'read_only')) {
        $seen = @{}
        foreach ($item in @($Plan.$groupName)) {
            Assert-ContextObjectShape -Object $item -Location "$groupName[]" -Required @('path', 'reason')
            Assert-SafeContextPath -Path ([string]$item.path) -Location "$groupName[].path"
            Assert-ContextString -Value $item.reason -Location "$groupName[].reason"
            $path = [string]$item.path
            if ($seen.ContainsKey($path)) {
                throw "Context plan contains duplicate $groupName path: $path"
            }
            $seen[$path] = $true
            if ($RequireResourceFiles) {
                [void](Resolve-ProfileProjectPath -Root $root -Path $path `
                    -Location "$groupName[].path" -Kind File)
            }
            if ($groupName -eq 'editable') { $editablePaths += $path } else { $readOnlyPaths += $path }
        }
    }
    foreach ($path in $editablePaths) {
        if ($readOnlyPaths -ccontains $path) {
            throw "Context plan path is both editable and read-only: $path"
        }
        if ($path -match '^(build|sources|scripts|schemas|tests|fixtures|profiles)/' -or
            $path -ceq [string]$Profile.Data.compliance.semantic_review -or
            $path -ceq [string]$Profile.Data.compliance.external_acceptance) {
            throw "Context plan grants editable access to a protected path: $path"
        }
    }

    $expectedEditable = @()
    foreach ($symbol in @($capabilityEntry.editable)) {
        switch ([string]$symbol) {
            'target' { $expectedEditable += [string]$Plan.target }
            'metadata' { $expectedEditable += [string]$Profile.Data.inputs.metadata }
            'bibliography' { $expectedEditable += [string]$Profile.Data.inputs.bibliography }
        }
    }
    if (($editablePaths -join "`n") -cne ($expectedEditable -join "`n")) {
        throw "Context plan editable set does not match capability '$($Plan.capability)'."
    }

    $expectedReadOnly = @(
        'AGENTS.md',
        'README.md',
        $activePointerRelativePath,
        [string]$Profile.ManifestPath,
        [string]$Profile.Data.compliance.system_prompt,
        [string]$Profile.Data.compliance.requirements,
        "build/ai/capabilities/$($Plan.capability).md"
    )
    foreach ($symbol in @($capabilityEntry.read_only)) {
        switch ([string]$symbol) {
            'target' { $expectedReadOnly += [string]$Plan.target }
            'metadata' { $expectedReadOnly += [string]$Profile.Data.inputs.metadata }
            'bibliography' { $expectedReadOnly += [string]$Profile.Data.inputs.bibliography }
            'other_content' {
                $expectedReadOnly += @($Profile.Data.inputs.content | ForEach-Object { [string]$_ } |
                    Where-Object { $_ -cne [string]$Plan.target })
            }
        }
    }
    if (($readOnlyPaths -join "`n") -cne ($expectedReadOnly -join "`n")) {
        throw "Context plan read-only set does not match capability '$($Plan.capability)'."
    }

    foreach ($item in @($Plan.excluded)) {
        Assert-ContextObjectShape -Object $item -Location 'excluded[]' -Required @('path', 'reason')
        Assert-ContextString -Value $item.path -Location 'excluded[].path'
        Assert-ContextString -Value $item.reason -Location 'excluded[].reason'
    }

    $expectedTransitionIds = @($Policy.capabilities | ForEach-Object { [string]$_.id } |
        Where-Object { $_ -cne [string]$Plan.capability })
    $actualTransitionIds = @()
    foreach ($transition in @($Plan.transitions)) {
        Assert-ContextObjectShape -Object $transition -Location 'transitions[]' -Required @(
            'capability', 'purpose', 'command', 'plan_path', 'aider_file'
        )
        $transitionId = [string]$transition.capability
        [void](Get-ContextCapability -Policy $Policy -Id $transitionId)
        if ([string]$transition.command -cne "/load $($transition.aider_file)") {
            throw "Context transition command does not match its Aider file: $transitionId"
        }
        if ([string]$transition.aider_file -cne "build/ai/switch/$transitionId.aider" -or
            [string]$transition.plan_path -cne "build/ai/plans/$transitionId.json") {
            throw "Context transition paths are not canonical for capability: $transitionId"
        }
        if ($RequireTransitionFiles) {
            [void](Resolve-ProfileProjectPath -Root $root -Path ([string]$transition.aider_file) `
                -Location 'transitions[].aider_file' -Kind File)
            [void](Resolve-ProfileProjectPath -Root $root -Path ([string]$transition.plan_path) `
                -Location 'transitions[].plan_path' -Kind File)
        }
        $actualTransitionIds += $transitionId
    }
    if (($actualTransitionIds -join "`n") -cne ($expectedTransitionIds -join "`n")) {
        throw 'Context plan transitions do not match the capability catalog.'
    }
}

function ConvertTo-ContextJson {
    param([Parameter(Mandatory = $true)][object]$Plan)
    return (($Plan | ConvertTo-Json -Depth 12) + "`n")
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowEmptyString()][Parameter(Mandatory = $true)][string]$Text
    )
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Format-AiderPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    Assert-SafeContextPath -Path $Path -Location 'aider.path'
    if ($Path.Contains('"')) {
        throw "Aider v1 adapter cannot safely quote a path containing a double quote: $Path"
    }
    if ($Path -match '\s') { return '"' + $Path + '"' }
    return $Path
}

function ConvertTo-AiderCommands {
    param([Parameter(Mandatory = $true)][object]$Plan)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# Generated by AutoNormoKontrol from a validated context-plan-v1. Do not edit.')
    $lines.Add('/drop')
    foreach ($item in @($Plan.read_only)) {
        $lines.Add('/read-only ' + (Format-AiderPath -Path ([string]$item.path)))
    }
    foreach ($item in @($Plan.editable)) {
        $lines.Add('/add ' + (Format-AiderPath -Path ([string]$item.path)))
    }
    return (($lines -join "`n") + "`n")
}

function ConvertTo-CapabilityInstructions {
    param([Parameter(Mandatory = $true)][object]$Plan)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# AutoNormoKontrol AI context')
    $lines.Add('')
    $lines.Add(('Current capability: `{0}`.' -f $Plan.capability))
    $lines.Add(('Selected target: `{0}`.' -f $Plan.target))
    $lines.Add(('Profile: `{0}` (`{1}`).' -f $Plan.profile.id, $Plan.profile.digest))
    $lines.Add(('Context policy digest: `{0}`.' -f $Plan.policy.digest))
    $lines.Add('This plan is valid only while both digests still match and the target remains an active profile content input.')
    $lines.Add('')
    $lines.Add('The editable and read-only file sets were selected by AutoNormoKontrol.')
    $lines.Add('Do not grant yourself access to another file and do not act as if a transition already happened.')
    $lines.Add('If the current context is insufficient, briefly explain why and recommend exactly one prepared command below.')
    $lines.Add('The user entering that `/load` command is the authority boundary.')
    $lines.Add('')
    $lines.Add('Available transitions:')
    foreach ($transition in @($Plan.transitions)) {
        $lines.Add('')
        $lines.Add(('- `{0}`: {1}' -f $transition.capability, $transition.purpose))
        $lines.Add(('  Command: `{0}`' -f $transition.command))
    }
    $lines.Add('')
    $lines.Add('Files omitted from the plan were not needed. Paths in `excluded` are protected from document-authoring edits.')
    return (($lines -join "`n") + "`n")
}

try {
    Assert-ContextString -Value $Capability -Location 'capability'
    Assert-ContextString -Value $Target -Location 'target'
    Assert-SafeContextPath -Path $Target -Location 'target'

    $resolvedProfilePath = if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
        Get-AutoNormoKontrolDefaultProfilePath -Root $root
    } else {
        $ProfilePath
    }
    $profile = Resolve-AutoNormoKontrolProfile -Root $root -ProfilePath $resolvedProfilePath
    $policy = Read-ContextPolicy -Path $policyRelativePath
    $selectedCapability = Get-ContextCapability -Policy $policy -Id $Capability

    $contentPaths = @($profile.Data.inputs.content | ForEach-Object { [string]$_ })
    if ($contentPaths -cnotcontains $Target) {
        throw "Target '$Target' is not declared in the active profile inputs.content."
    }
    [void](Resolve-ProfileProjectPath -Root $root -Path $Target -Location 'target' -Kind File)

    $policyFull = Resolve-ProfileProjectPath -Root $root -Path $policyRelativePath `
        -Location 'context_policy' -Kind File
    $policyDigest = Get-ProfileSha256 -Path $policyFull

    $outputFull = [System.IO.Path]::GetFullPath((Join-Path $root $outputRelativePath))
    $expectedOutputFull = [System.IO.Path]::GetFullPath((Join-Path $root 'build/ai'))
    if (-not $outputFull.Equals($expectedOutputFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Context output directory is outside the fixed generated boundary: $outputFull"
    }
    if (Test-Path -LiteralPath $outputFull) {
        Remove-Item -LiteralPath $outputFull -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $outputFull | Out-Null

    $plans = [ordered]@{}
    foreach ($entry in @($policy.capabilities)) {
        $plan = Get-ContextPlan -Profile $profile -Policy $policy -PolicyDigest $policyDigest `
            -CapabilityEntry $entry -ContentTarget $Target
        Assert-ContextPlan -Plan $plan -Profile $profile -Policy $policy
        $plans[[string]$entry.id] = $plan
        $planPath = Join-Path $root "build/ai/plans/$($entry.id).json"
        Write-Utf8NoBom -Path $planPath -Text (ConvertTo-ContextJson -Plan $plan)
    }

    foreach ($entry in @($policy.capabilities)) {
        $id = [string]$entry.id
        $plan = $plans[$id]
        $instructionPath = Join-Path $root "build/ai/capabilities/$id.md"
        Write-Utf8NoBom -Path $instructionPath `
            -Text (ConvertTo-CapabilityInstructions -Plan $plan)
    }

    foreach ($entry in @($policy.capabilities)) {
        $id = [string]$entry.id
        $plan = $plans[$id]
        Assert-ContextPlan -Plan $plan -Profile $profile -Policy $policy -RequireResourceFiles
        $aiderPath = Join-Path $root "build/ai/switch/$id.aider"
        Write-Utf8NoBom -Path $aiderPath -Text (ConvertTo-AiderCommands -Plan $plan)
    }

    foreach ($entry in @($policy.capabilities)) {
        Assert-ContextPlan -Plan $plans[[string]$entry.id] -Profile $profile -Policy $policy `
            -RequireResourceFiles -RequireTransitionFiles
    }

    $currentPlan = $plans[[string]$selectedCapability.id]
    Write-Utf8NoBom -Path (Join-Path $outputFull 'context-plan.json') `
        -Text (ConvertTo-ContextJson -Plan $currentPlan)
    Write-Utf8NoBom -Path (Join-Path $outputFull 'aider-context.txt') `
        -Text (ConvertTo-AiderCommands -Plan $currentPlan)
    Write-Utf8NoBom -Path (Join-Path $outputFull 'capabilities.md') `
        -Text (ConvertTo-CapabilityInstructions -Plan $currentPlan)

    Write-Host ("Context plan ready: {0}" -f (Join-Path $outputRelativePath 'context-plan.json'))
    Write-Host ("Capability: {0}" -f $Capability)
    Write-Host ("Target: {0}" -f $Target)
    Write-Host ''
    Write-Host 'Load into Aider:'
    Write-Host ("  /load build/ai/switch/{0}.aider" -f $Capability)
    exit 0
}
catch {
    Write-Error ("{0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace)
    exit 1
}
