[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root
. (Join-Path $PSScriptRoot 'profile.ps1')

$plannerPath = Join-Path $PSScriptRoot 'context-plan.ps1'
$profilePath = Get-AutoNormoKontrolDefaultProfilePath -Root $root
$profile = Resolve-AutoNormoKontrolProfile -Root $root -ProfilePath $profilePath
$target = [string]@($profile.Data.inputs.content)[0]
$failures = New-Object System.Collections.Generic.List[string]

function Add-Failure {
    param([Parameter(Mandatory = $true)][string]$Message)
    $script:failures.Add($Message)
}

function Invoke-ContextPlanner {
    param(
        [AllowEmptyString()][string]$Capability,
        [AllowEmptyString()][string]$Target
    )

    $arguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $plannerPath,
        '-Capability', $Capability,
        '-Target', $Target,
        '-ProfilePath', $profilePath
    )
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $messages = @(& powershell.exe @arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    return [pscustomobject]@{
        ExitCode = [int]$exitCode
        Text = ($messages | Out-String)
    }
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$RelativePath)
    $full = Join-Path $root $RelativePath
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        Add-Failure "missing generated JSON: $RelativePath"
        return $null
    }
    try {
        return ([System.IO.File]::ReadAllText($full, [System.Text.Encoding]::UTF8) |
            ConvertFrom-Json)
    }
    catch {
        Add-Failure "invalid generated JSON ${RelativePath}: $($_.Exception.Message)"
        return $null
    }
}

function Get-PlanPaths {
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][string]$Field
    )
    return @($Plan.$Field | ForEach-Object { [string]$_.path })
}

function Test-ExactArray {
    param(
        [string[]]$Actual,
        [string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Clause
    )
    if (($Actual -join "`n") -cne ($Expected -join "`n")) {
        Add-Failure ("{0}: actual [{1}], expected [{2}]" -f
            $Clause, ($Actual -join ', '), ($Expected -join ', '))
    }
}

function Get-AiderCommandPaths {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $full = Join-Path $root $RelativePath
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        Add-Failure "missing Aider command file: $RelativePath"
        return [pscustomobject]@{ Editable = @(); ReadOnly = @(); Invalid = @('missing') }
    }
    $editable = @()
    $readOnly = @()
    $invalid = @()
    $firstCommand = $null
    foreach ($rawLine in [System.IO.File]::ReadAllLines($full, [System.Text.Encoding]::UTF8)) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
        if ($null -eq $firstCommand) { $firstCommand = $line }
        if ($line -eq '/drop') { continue }
        $match = [regex]::Match($line, '^/(add|read-only)\s+(.+)$')
        if (-not $match.Success) {
            $invalid += $line
            continue
        }
        $path = $match.Groups[2].Value
        if ($path.Length -ge 2 -and $path.StartsWith('"') -and $path.EndsWith('"')) {
            $path = $path.Substring(1, $path.Length - 2)
        }
        if ($match.Groups[1].Value -eq 'add') { $editable += $path } else { $readOnly += $path }
    }
    if ($firstCommand -ne '/drop') {
        $invalid += 'first-command-is-not-drop'
    }
    return [pscustomobject]@{
        Editable = @($editable)
        ReadOnly = @($readOnly)
        Invalid = @($invalid)
    }
}

if (-not (Test-Path -LiteralPath $plannerPath -PathType Leaf)) {
    Add-Failure 'context planner script is missing'
}

$capabilityIds = @(
    'edit-content', 'edit-references', 'edit-metadata',
    'design-structure', 'review-content'
)

# R1.4a/context-plan-v1: every capability must be selectable without an NLP task taxonomy.
foreach ($capability in $capabilityIds) {
    $result = Invoke-ContextPlanner -Capability $capability -Target $target
    if ($result.ExitCode -ne 0) {
        Add-Failure "capability '$capability' failed:`n$($result.Text)"
        continue
    }
    $current = Read-JsonFile -RelativePath 'build/ai/context-plan.json'
    if ($null -eq $current -or [string]$current.capability -cne $capability) {
        Add-Failure "root context plan did not select capability '$capability'"
    }
}

# R1.4a/context-plan-v1: reject missing, physically existing out-of-profile, engine and traversal targets.
$negativeCases = @(
    [ordered]@{ name = 'unknown content target'; capability = 'edit-content'; target = 'content/unknown.md' },
    [ordered]@{ name = 'existing out-of-profile file'; capability = 'edit-content'; target = 'metadata.yaml' },
    [ordered]@{ name = 'engine file target'; capability = 'edit-content'; target = 'scripts/autonormokontrol.ps1' },
    [ordered]@{ name = 'path traversal target'; capability = 'edit-content'; target = 'content/../scripts/autonormokontrol.ps1' },
    [ordered]@{ name = 'unknown capability'; capability = 'does-not-exist'; target = $target },
    [ordered]@{ name = 'empty capability'; capability = ''; target = $target }
)
foreach ($case in $negativeCases) {
    $result = Invoke-ContextPlanner -Capability ([string]$case.capability) -Target ([string]$case.target)
    if ($result.ExitCode -eq 0) {
        Add-Failure "negative case '$($case.name)' did not fail closed"
    }
}

# Leave a successful, deterministic set of generated plans for the remaining contract checks.
$firstRun = Invoke-ContextPlanner -Capability 'edit-content' -Target $target
if ($firstRun.ExitCode -ne 0) {
    Add-Failure "determinism setup failed:`n$($firstRun.Text)"
}
$firstJson = if (Test-Path -LiteralPath (Join-Path $root 'build/ai/context-plan.json')) {
    [System.IO.File]::ReadAllText((Join-Path $root 'build/ai/context-plan.json'), [System.Text.Encoding]::UTF8)
} else { '' }
$secondRun = Invoke-ContextPlanner -Capability 'edit-content' -Target $target
$secondJson = if (Test-Path -LiteralPath (Join-Path $root 'build/ai/context-plan.json')) {
    [System.IO.File]::ReadAllText((Join-Path $root 'build/ai/context-plan.json'), [System.Text.Encoding]::UTF8)
} else { '' }
if ($secondRun.ExitCode -ne 0 -or [string]::IsNullOrEmpty($firstJson) -or $firstJson -cne $secondJson) {
    Add-Failure 'same profile digest + capability + target did not produce deterministic JSON'
}

$expectedSchemaFields = @(
    'schema', 'profile', 'policy', 'capability', 'target',
    'editable', 'read_only', 'excluded', 'transitions'
)
$bibliography = [string]$profile.Data.inputs.bibliography
$metadata = [string]$profile.Data.inputs.metadata
$semanticReview = [string]$profile.Data.compliance.semantic_review
$externalAcceptance = [string]$profile.Data.compliance.external_acceptance

foreach ($capability in $capabilityIds) {
    $planPath = "build/ai/plans/$capability.json"
    $plan = Read-JsonFile -RelativePath $planPath
    if ($null -eq $plan) { continue }

    Test-ExactArray -Actual @($plan.PSObject.Properties.Name) -Expected $expectedSchemaFields `
        -Clause "$capability exact context-plan-v1 root fields"
    if ([string]$plan.schema -ne 'context-plan-v1' -or
        [string]$plan.profile.digest -ne [string]$profile.ProfileDigest) {
        Add-Failure "$capability plan has invalid schema or profile digest"
    }

    $editable = @(Get-PlanPaths -Plan $plan -Field 'editable')
    $readOnly = @(Get-PlanPaths -Plan $plan -Field 'read_only')
    switch ($capability) {
        'edit-content' {
            Test-ExactArray -Actual $editable -Expected @($target) -Clause 'edit-content editable set'
            if ($editable -contains $bibliography) { Add-Failure 'edit-content added bibliography just in case' }
        }
        'edit-references' {
            Test-ExactArray -Actual $editable -Expected @($target, $bibliography) `
                -Clause 'edit-references editable set'
        }
        'edit-metadata' {
            Test-ExactArray -Actual $editable -Expected @($metadata) -Clause 'edit-metadata editable set'
        }
        'design-structure' {
            Test-ExactArray -Actual $editable -Expected @($target) -Clause 'design-structure editable set'
            foreach ($other in @($profile.Data.inputs.content | Where-Object { [string]$_ -cne $target })) {
                if ($readOnly -cnotcontains [string]$other) {
                    Add-Failure "design-structure is missing other profile content: $other"
                }
            }
        }
        'review-content' {
            Test-ExactArray -Actual $editable -Expected @() -Clause 'review-content editable set'
            if ($readOnly -cnotcontains $target) { Add-Failure 'review-content target is not read-only' }
        }
    }

    foreach ($path in $editable) {
        if ($path -ceq $semanticReview -or $path -ceq $externalAcceptance -or
            $path -match '^(build|sources|scripts|schemas|tests|fixtures|profiles)/') {
            Add-Failure "$capability granted editable access to protected path: $path"
        }
    }
    $excluded = @($plan.excluded | ForEach-Object { [string]$_.path })
    foreach ($requiredExcluded in @('build/**', 'sources/**', 'scripts/**', 'schemas/**',
            $semanticReview, $externalAcceptance)) {
        if ($excluded -cnotcontains $requiredExcluded) {
            Add-Failure "$capability excluded set is missing $requiredExcluded"
        }
    }

    $aiderRelativePath = "build/ai/switch/$capability.aider"
    $aider = Get-AiderCommandPaths -RelativePath $aiderRelativePath
    Test-ExactArray -Actual @($aider.Editable) -Expected $editable `
        -Clause "$capability Aider editable adapter"
    Test-ExactArray -Actual @($aider.ReadOnly) -Expected $readOnly `
        -Clause "$capability Aider read-only adapter"
    if (@($aider.Invalid).Count -gt 0) {
        Add-Failure "$capability Aider adapter contains non-plan commands: $($aider.Invalid -join ', ')"
    }

    $expectedTransitions = @($capabilityIds | Where-Object { $_ -cne $capability })
    $actualTransitions = @($plan.transitions | ForEach-Object { [string]$_.capability })
    Test-ExactArray -Actual $actualTransitions -Expected $expectedTransitions `
        -Clause "$capability transition catalog"
    foreach ($transition in @($plan.transitions)) {
        if ([string]$transition.command -cne "/load $($transition.aider_file)" -or
            -not (Test-Path -LiteralPath (Join-Path $root ([string]$transition.aider_file)) -PathType Leaf) -or
            -not (Test-Path -LiteralPath (Join-Path $root ([string]$transition.plan_path)) -PathType Leaf)) {
            Add-Failure "$capability transition '$($transition.capability)' references missing output"
        }
    }
}

$schemaPath = Join-Path $root 'schemas/context-plan-v1.schema.json'
if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
    Add-Failure 'context-plan-v1 JSON schema is missing'
}
else {
    try {
        $schema = ([System.IO.File]::ReadAllText($schemaPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
        if ([string]$schema.properties.schema.const -ne 'context-plan-v1' -or
            $schema.additionalProperties -ne $false) {
            Add-Failure 'context-plan-v1 JSON schema is not fail-closed'
        }
    }
    catch {
        Add-Failure "context-plan-v1 JSON schema is invalid JSON: $($_.Exception.Message)"
    }
}

$currentInstructions = Join-Path $root 'build/ai/capabilities.md'
if (-not (Test-Path -LiteralPath $currentInstructions -PathType Leaf) -or
    -not ([System.IO.File]::ReadAllText($currentInstructions, [System.Text.Encoding]::UTF8).Contains(
        'Current capability: `edit-content`.'))) {
    Add-Failure 'current capability instructions do not identify the active capability'
}

if ($failures.Count -gt 0) {
    Write-Host ("Context plan tests failed: {0} problem(s)." -f $failures.Count) -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host ('  - ' + $failure) }
    exit 1
}

Write-Host 'PASS context-plan-v1 capability, boundary, determinism and Aider adapter contracts'
exit 0
