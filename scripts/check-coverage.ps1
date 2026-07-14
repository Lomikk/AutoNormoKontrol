[CmdletBinding()]
param(
    [string]$RegistryPath = 'compliance/requirements.json'
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
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
$implementationFiles = @(Get-TextFiles @('filters', 'styles', 'templates'))
$implementationFiles += @(Get-TextFiles @(
    'scripts/build.ps1',
    'scripts/lint-content.ps1',
    'scripts/validate-pdf.ps1'
))
$implementationFiles = @($implementationFiles | Sort-Object FullName -Unique)

# Test evidence includes fixtures, executable compliance tests and PDF
# postflight assertions. STO markers must occur in comments in these files.
$testFiles = @(Get-TextFiles @('tests', 'scripts/test-compliance.ps1', 'scripts/validate-pdf.ps1'))
$testFiles = @($testFiles | Sort-Object FullName -Unique)
$promptFiles = @(Get-TextFiles @('prompts'))
$semanticFiles = @(Get-TextFiles @('compliance/semantic-review.yaml'))
$externalFiles = @(Get-TextFiles @('compliance/external-acceptance.yaml'))

$failures = New-Object System.Collections.Generic.List[string]
$seenIds = @{}

# Registry schema and lifecycle invariants. A clause is not traceable if its
# description/classification is blank or if mechanism and status disagree.
$requiredRegistryFields = @(
    'id', 'summary', 'applicability', 'mechanism', 'status',
    'implementation_markers', 'test_markers', 'notes'
)
$mechanismStatuses = @{
    'programmatic' = 'specified'
    'ai' = 'semantic-review-required'
    'external' = 'external-evidence-required'
    'conflict' = 'blocked-pending-resolution'
    'informational' = 'indexed'
    'not-applicable' = 'not-applicable-coursework'
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

# Canonical inventory is generated independently of requirements.json. This
# prevents a shortened registry from making its own coverage report green.
$canonicalIds = New-Object System.Collections.Generic.List[string]
foreach ($section in 1..9) { $canonicalIds.Add("STO-$section") }
foreach ($clause in 1..5) { $canonicalIds.Add("STO-3.$clause") }
foreach ($clause in 1..6) { $canonicalIds.Add("STO-5.$clause") }

$section7Ranges = @{
    '1' = 3
    '2' = 3
    '3' = 5
    '4' = 2
    '5' = 4
    '6' = 0
    '7' = 0
    '8' = 3
    '9' = 0
    '10' = 0
    '11' = 7
    '12' = 9
}
foreach ($subsection in 1..12) {
    $canonicalIds.Add("STO-7.$subsection")
    $lastClause = [int]$section7Ranges[[string]$subsection]
    if ($lastClause -gt 0) {
        foreach ($clause in 1..$lastClause) {
            $canonicalIds.Add("STO-7.$subsection.$clause")
        }
    }
}

$section8Ranges = @{
    '1' = 7
    '2' = 11
    '3' = 3
    '4' = 9
    '5' = 12
    '6' = 16
    '7' = 18
}
foreach ($subsection in 1..7) {
    $canonicalIds.Add("STO-8.$subsection")
    foreach ($clause in 1..([int]$section8Ranges[[string]$subsection])) {
        $canonicalIds.Add("STO-8.$subsection.$clause")
    }
}

foreach ($clause in 1..4) { $canonicalIds.Add("STO-9.$clause") }
foreach ($appendix in @(
    'A1', 'A2', 'B1', 'B2', 'V', 'G', 'D', 'E1', 'E2',
    'ZH', 'I1', 'I2', 'K', 'L', 'M', 'N', 'P'
)) {
    $canonicalIds.Add("STO-$appendix")
}

if ($canonicalIds.Count -ne 172) {
    Add-Failure $failures '<canonical-inventory>' "internal canonical count is $($canonicalIds.Count), expected 172"
}
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
