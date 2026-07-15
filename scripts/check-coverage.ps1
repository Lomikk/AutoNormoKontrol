[CmdletBinding()]
param(
    [string]$ProfilePath = '',
    [string]$CanonicalInventoryPath = '',
    [string]$RegistryPath = '',
    [string[]]$ImplementationPaths = @(),
    [string[]]$TestPaths = @(),
    [string[]]$PromptPaths = @(),
    [string[]]$SemanticPaths = @(),
    [string[]]$ExternalPaths = @()
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'profile.ps1')
$resolvedProfile = Resolve-AutoNormoKontrolProfile -Root $root -ProfilePath $ProfilePath
if (-not $PSBoundParameters.ContainsKey('CanonicalInventoryPath')) {
    $CanonicalInventoryPath = [string]$resolvedProfile.Data.compliance.canonical_inventory
}
if (-not $PSBoundParameters.ContainsKey('RegistryPath')) {
    $RegistryPath = [string]$resolvedProfile.Data.compliance.requirements
}
if (-not $PSBoundParameters.ContainsKey('ImplementationPaths')) {
    $ImplementationPaths = @($resolvedProfile.Data.compliance.implementation_paths)
}
if (-not $PSBoundParameters.ContainsKey('TestPaths')) {
    $TestPaths = @($resolvedProfile.Data.compliance.test_paths)
}
if (-not $PSBoundParameters.ContainsKey('PromptPaths')) {
    $PromptPaths = @($resolvedProfile.Data.compliance.prompt_paths)
}
if (-not $PSBoundParameters.ContainsKey('SemanticPaths')) {
    $SemanticPaths = @($resolvedProfile.Data.compliance.semantic_paths)
}
if (-not $PSBoundParameters.ContainsKey('ExternalPaths')) {
    $ExternalPaths = @($resolvedProfile.Data.compliance.external_paths)
}
$canonicalInventory = if ([System.IO.Path]::IsPathRooted($CanonicalInventoryPath)) {
    $CanonicalInventoryPath
}
else {
    Join-Path $root $CanonicalInventoryPath
}
$registry = if ([System.IO.Path]::IsPathRooted($RegistryPath)) {
    $RegistryPath
}
else {
    Join-Path $root $RegistryPath
}

function Get-TextFiles {
    param([string[]]$Paths)

    $result = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $fullPath = if ([System.IO.Path]::IsPathRooted($path)) {
            $path
        }
        else {
            Join-Path $root $path
        }
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            $result.Add((Get-Item -LiteralPath $fullPath))
        }
        elseif (Test-Path -LiteralPath $fullPath -PathType Container) {
            Get-ChildItem -LiteralPath $fullPath -Recurse -File | ForEach-Object {
                $result.Add($_)
            }
        }
    }
    return @($result | Sort-Object FullName -Unique)
}

function Read-Utf8Text {
    param([System.IO.FileInfo]$File)
    return [System.IO.File]::ReadAllText($File.FullName, [System.Text.Encoding]::UTF8)
}

function Get-PropertyValue {
    param(
        [object]$Object,
        [string[]]$Names
    )
    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) {
            return $property.Value
        }
    }
    return $null
}

function Convert-ToStringArray {
    param([object]$Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [string]) { return @($Value) }
    return @($Value | ForEach-Object { [string]$_ })
}

function Get-DefaultMarker {
    param([string]$Id)
    if ($Id -match '^STO-') { return $Id }
    return 'STO-' + $Id
}

function Get-Markers {
    param(
        [object]$Requirement,
        [string]$Kind,
        [string]$DefaultMarker
    )

    $names = switch ($Kind) {
        'implementation' { @('implementation_markers', 'implementationMarkers') }
        'test' { @('test_markers', 'testMarkers') }
        'prompt' { @('prompt_markers', 'promptMarkers') }
        'semantic' { @('semantic_review_markers', 'semanticReviewMarkers') }
        'external' { @('external_acceptance_markers', 'externalAcceptanceMarkers') }
        default { @() }
    }
    $value = Get-PropertyValue -Object $Requirement -Names $names

    $markersProperty = $Requirement.PSObject.Properties['markers']
    if ($null -eq $value -and $null -ne $markersProperty -and $null -ne $markersProperty.Value) {
        $nested = $markersProperty.Value.PSObject.Properties[$Kind]
        if ($null -ne $nested) { $value = $nested.Value }
    }

    $markers = @(Convert-ToStringArray $value | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($markers.Count -eq 0) { return @($DefaultMarker) }
    return $markers
}

function Get-Mechanisms {
    param([object]$Requirement)

    $value = Get-PropertyValue -Object $Requirement -Names @('mechanism', 'mechanisms', 'enforcement')
    if ($null -eq $value) { return @() }

    $items = Convert-ToStringArray $value
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($item in $items) {
        foreach ($part in ($item -split '[+,/]')) {
            $normalized = $part.Trim().ToLowerInvariant().Replace('_', '-').Replace(' ', '-')
            if ($normalized -ne '') { $result.Add($normalized) }
        }
    }
    return @($result | Select-Object -Unique)
}

function Test-MarkerInComment {
    param(
        [string]$Marker,
        [System.IO.FileInfo[]]$Files
    )

    $escaped = [regex]::Escape($Marker)
    # A trailing full stop is normal prose punctuation (`STO-8.4.8.`), but
    # `.1` means a longer clause and must not satisfy the parent marker.
    $markerPattern = '(?<![A-Za-z0-9.-])' + $escaped + '(?![A-Za-z0-9_-]|\.[0-9])'
    foreach ($file in $Files) {
        $lineNumber = 0
        foreach ($line in [System.IO.File]::ReadLines($file.FullName, [System.Text.Encoding]::UTF8)) {
            $lineNumber++
            $match = [regex]::Match($line, $markerPattern)
            if (-not $match.Success) { continue }
            $prefix = $line.Substring(0, $match.Index)
            if ($prefix -match '(--|#|%|//|/\*|<!--)') {
                return $true
            }
        }
    }
    return $false
}

function Test-MarkerInText {
    param(
        [string]$Marker,
        [System.IO.FileInfo[]]$Files
    )

    $escaped = [regex]::Escape($Marker)
    $pattern = '(?<![A-Za-z0-9.-])' + $escaped + '(?![A-Za-z0-9_-]|\.[0-9])'
    foreach ($file in $Files) {
        if ([regex]::IsMatch((Read-Utf8Text $file), $pattern)) { return $true }
    }
    return $false
}

function Add-Failure {
    param(
        [System.Collections.Generic.List[string]]$Failures,
        [string]$Id,
        [string]$Message
    )
    $Failures.Add(('{0}: {1}' -f $Id, $Message))
}

if (-not (Test-Path -LiteralPath $registry -PathType Leaf)) {
    Write-Error "Coverage registry not found: $registry"
    exit 1
}

if (-not (Test-Path -LiteralPath $canonicalInventory -PathType Leaf)) {
    Write-Error "Canonical requirement inventory not found: $canonicalInventory"
    exit 1
}

try {
    $canonicalDocument = (Get-Content -LiteralPath $canonicalInventory -Raw -Encoding UTF8) |
        ConvertFrom-Json
}
catch {
    Write-Error "Canonical requirement inventory is not valid JSON: $($_.Exception.Message)"
    exit 1
}
if ($canonicalDocument.schema_version -ne 1 -or
    [string]$canonicalDocument.profile_id -ne $resolvedProfile.ProfileId -or
    $canonicalDocument.requirement_ids -is [string]) {
    Write-Error 'Canonical requirement inventory has an unsupported or inconsistent structure.'
    exit 1
}
$canonicalIds = @($canonicalDocument.requirement_ids | ForEach-Object { [string]$_ })
if ($canonicalIds.Count -eq 0 -or
    @($canonicalIds | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0 -or
    @($canonicalIds | Group-Object | Where-Object Count -ne 1).Count -gt 0) {
    Write-Error 'Canonical requirement inventory must contain unique non-empty IDs.'
    exit 1
}

try {
    $registryDocument = (Get-Content -LiteralPath $registry -Raw -Encoding UTF8) | ConvertFrom-Json
}
catch {
    Write-Error "Coverage registry is not valid JSON: $($_.Exception.Message)"
    exit 1
}

$requirementsProperty = $registryDocument.PSObject.Properties['requirements']
$requirements = if ($null -ne $requirementsProperty) {
    @($requirementsProperty.Value)
}
elseif ($registryDocument -is [System.Array]) {
    @($registryDocument)
}
else {
    @($registryDocument)
}

if ($requirements.Count -eq 0) {
    Write-Error 'Coverage registry contains no requirements.'
    exit 1
}

# Real implementation sources only. The registry and the coverage checker are
# deliberately excluded so they cannot prove their own assertions.
$implementationFiles = @(Get-TextFiles $ImplementationPaths)
$implementationFiles = @($implementationFiles | Sort-Object FullName -Unique)

# Test evidence includes fixtures, executable compliance tests and PDF
# postflight assertions. STO markers must occur in comments in these files.
$testFiles = @(Get-TextFiles $TestPaths)
$testFiles = @($testFiles | Sort-Object FullName -Unique)
$promptFiles = @(Get-TextFiles $PromptPaths)
$semanticFiles = @(Get-TextFiles $SemanticPaths)
$externalFiles = @(Get-TextFiles $ExternalPaths)

$failures = New-Object System.Collections.Generic.List[string]
$seenIds = @{}

# Registry schema and lifecycle invariants. A clause is not traceable if its
# description/classification is blank or if mechanism and status disagree.
$requiredRegistryFields = @(
    'id', 'summary', 'applicability', 'mechanism', 'status',
    'implementation_markers', 'test_markers', 'notes'
)
$mechanismStatuses = @{}
$mechanismStatusProperty = $registryDocument.metadata.PSObject.Properties['mechanism_statuses']
if ($null -eq $mechanismStatusProperty -or $null -eq $mechanismStatusProperty.Value) {
    Add-Failure $failures '<registry-metadata>' 'missing mechanism_statuses mapping'
}
else {
    foreach ($property in $mechanismStatusProperty.Value.PSObject.Properties) {
        $mechanismStatuses[$property.Name.ToLowerInvariant()] = ([string]$property.Value).ToLowerInvariant()
    }
}
foreach ($requirement in $requirements) {
    $candidateId = [string](Get-PropertyValue -Object $requirement -Names @('id'))
    if ([string]::IsNullOrWhiteSpace($candidateId)) { $candidateId = '<missing-id>' }
    foreach ($field in $requiredRegistryFields) {
        if ($null -eq $requirement.PSObject.Properties[$field]) {
            Add-Failure $failures $candidateId "missing required registry field: $field"
        }
    }
    foreach ($field in @('id', 'summary', 'applicability', 'mechanism', 'status', 'notes')) {
        $value = Get-PropertyValue -Object $requirement -Names @($field)
        if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
            Add-Failure $failures $candidateId "blank required registry field: $field"
        }
    }

    $mechanism = ([string](Get-PropertyValue -Object $requirement -Names @('mechanism'))).ToLowerInvariant()
    $status = ([string](Get-PropertyValue -Object $requirement -Names @('status'))).ToLowerInvariant()
    if (-not $mechanismStatuses.ContainsKey($mechanism)) {
        Add-Failure $failures $candidateId "unsupported registry mechanism: $mechanism"
    }
    elseif ($status -ne $mechanismStatuses[$mechanism]) {
        Add-Failure $failures $candidateId ("status {0} does not match {1}; expected {2}" -f
            $status, $mechanism, $mechanismStatuses[$mechanism])
    }

    $implementationProperty = $requirement.PSObject.Properties['implementation_markers']
    $testProperty = $requirement.PSObject.Properties['test_markers']
    $implementationMarkers = if ($null -eq $implementationProperty) { @() } else { @($implementationProperty.Value) }
    $testMarkers = if ($null -eq $testProperty) { @() } else { @($testProperty.Value) }
    if ($null -ne $implementationProperty -and $implementationProperty.Value -is [string]) {
        Add-Failure $failures $candidateId 'implementation_markers must be a JSON array'
    }
    if ($null -ne $testProperty -and $testProperty.Value -is [string]) {
        Add-Failure $failures $candidateId 'test_markers must be a JSON array'
    }
    foreach ($marker in @($implementationMarkers) + @($testMarkers)) {
        if ([string]::IsNullOrWhiteSpace([string]$marker)) {
            Add-Failure $failures $candidateId 'marker arrays may not contain blank values'
        }
    }
    if ($mechanism -in @('programmatic', 'ai')) {
        if ($implementationMarkers -notcontains $candidateId) {
            Add-Failure $failures $candidateId 'implementation_markers must contain the clause id'
        }
        if ($testMarkers -notcontains $candidateId) {
            Add-Failure $failures $candidateId 'test_markers must contain the clause id'
        }
    }
    elseif ($mechanism -in @('external', 'conflict')) {
        if ($implementationMarkers -notcontains $candidateId) {
            Add-Failure $failures $candidateId 'external/conflict implementation_markers must contain the clause id'
        }
    }
    elseif ($mechanism -in @('informational', 'not-applicable')) {
        if ($implementationMarkers.Count -ne 0 -or $testMarkers.Count -ne 0) {
            Add-Failure $failures $candidateId 'registry-only clauses must have empty marker arrays'
        }
    }
}

# The profile-owned canonical inventory is independent of requirements.json.
# A shortened registry therefore cannot make its own coverage report green.
$canonicalSet = @{}
foreach ($id in $canonicalIds) { $canonicalSet[$id] = $true }
$actualSet = @{}
foreach ($requirement in $requirements) {
    $actualId = [string](Get-PropertyValue -Object $requirement -Names @('id', 'clause'))
    if (-not [string]::IsNullOrWhiteSpace($actualId)) { $actualSet[$actualId] = $true }
}
foreach ($id in $canonicalIds) {
    if (-not $actualSet.ContainsKey($id)) {
        Add-Failure $failures $id 'canonical requirement is missing from registry'
    }
}
foreach ($id in $actualSet.Keys) {
    if (-not $canonicalSet.ContainsKey($id)) {
        Add-Failure $failures $id 'non-canonical extra requirement in registry'
    }
}

foreach ($requirement in $requirements) {
    $id = [string](Get-PropertyValue -Object $requirement -Names @('id', 'clause'))
    if ([string]::IsNullOrWhiteSpace($id)) {
        Add-Failure $failures '<missing-id>' 'requirement has no id/clause'
        continue
    }
    if ($seenIds.ContainsKey($id)) {
        Add-Failure $failures $id 'duplicate requirement id'
        continue
    }
    $seenIds[$id] = $true

    $mechanisms = @(Get-Mechanisms $requirement)
    if ($mechanisms.Count -eq 0) {
        Add-Failure $failures $id 'missing mechanism/enforcement classification'
        continue
    }
    $defaultMarker = Get-DefaultMarker $id

    foreach ($mechanism in $mechanisms) {
        switch ($mechanism) {
            'programmatic' {
                foreach ($marker in (Get-Markers $requirement 'implementation' $defaultMarker)) {
                    if (-not (Test-MarkerInComment $marker $implementationFiles)) {
                        Add-Failure $failures $id "implementation comment marker not found: $marker"
                    }
                }
                foreach ($marker in (Get-Markers $requirement 'test' $defaultMarker)) {
                    if (-not (Test-MarkerInComment $marker $testFiles)) {
                        Add-Failure $failures $id "test comment marker not found: $marker"
                    }
                }
            }
            'ai' {
                foreach ($marker in (Get-Markers $requirement 'prompt' $defaultMarker)) {
                    if (-not (Test-MarkerInText $marker $promptFiles)) {
                        Add-Failure $failures $id "prompt marker not found: $marker"
                    }
                }
                foreach ($marker in (Get-Markers $requirement 'semantic' $defaultMarker)) {
                    if (-not (Test-MarkerInText $marker $semanticFiles)) {
                        Add-Failure $failures $id "semantic-review marker not found: $marker"
                    }
                }
            }
            { $_ -in @('external', 'conflict') } {
                foreach ($marker in (Get-Markers $requirement 'external' $defaultMarker)) {
                    if (-not (Test-MarkerInText $marker $externalFiles)) {
                        Add-Failure $failures $id "external-acceptance marker not found: $marker"
                    }
                }
            }
            { $_ -in @('informational', 'not-applicable', 'n-a', 'na') } {
                # Registry-only classifications intentionally require no
                # implementation evidence, but remain visible in the ledger.
            }
            default {
                Add-Failure $failures $id "unknown mechanism: $mechanism"
            }
        }
    }
}

if ($failures.Count -gt 0) {
    Write-Host ('STO coverage failed: {0} problem(s).' -f $failures.Count) -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host ('  - ' + $failure) }
    exit 1
}

Write-Host ('STO coverage passed: {0} unique requirement(s).' -f $seenIds.Count) -ForegroundColor Green
exit 0
