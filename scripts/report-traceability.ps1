[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$WorkspaceRoot,
    [string]$RegistryPath = '',
    [string]$JsonOutputPath = '',
    [string]$MarkdownOutputPath = '',
    [string]$ProfileId = '',
    [string]$ProfileDigest = '',
    [string[]]$ImplementationPaths = @(),
    [string[]]$TestPaths = @(),
    [string[]]$PromptPaths = @(),
    [string[]]$SemanticPaths = @(),
    [string[]]$ExternalPaths = @()
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$WorkspaceRoot = [System.IO.Path]::GetFullPath($WorkspaceRoot)
. (Join-Path $PSScriptRoot 'profile.ps1')
. (Join-Path $PSScriptRoot 'workspace.ps1')
$workspace = Resolve-AutoNormoKontrolWorkspace -EngineRoot $root -WorkspaceRoot $WorkspaceRoot
$resolvedProfile = $workspace.Profile
if (-not $PSBoundParameters.ContainsKey('RegistryPath')) {
    $RegistryPath = [string]$resolvedProfile.Data.compliance.requirements
}
if (-not $PSBoundParameters.ContainsKey('JsonOutputPath')) {
    $JsonOutputPath = [string]$resolvedProfile.Data.reports.traceability_json
}
if (-not $PSBoundParameters.ContainsKey('MarkdownOutputPath')) {
    $MarkdownOutputPath = [string]$resolvedProfile.Data.reports.traceability_markdown
}
if (-not $PSBoundParameters.ContainsKey('ProfileId')) {
    $ProfileId = $resolvedProfile.ProfileId
}
if (-not $PSBoundParameters.ContainsKey('ProfileDigest')) {
    $ProfileDigest = $resolvedProfile.ProfileDigest
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
$registry = if ([System.IO.Path]::IsPathRooted($RegistryPath)) {
    $RegistryPath
}
else {
    Join-Path $root $RegistryPath
}

function Resolve-ProjectPath {
    param(
        [string]$Path,
        [string]$BaseRoot = $root
    )

    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return Join-Path $BaseRoot $Path
}

function Get-RelativeProjectPath {
    param([string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullWorkspace = [System.IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\', '/')
    $workspacePrefix = $fullWorkspace + [System.IO.Path]::DirectorySeparatorChar
    if ($fullPath.StartsWith($workspacePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $fullPath.Substring($fullWorkspace.Length).TrimStart('\', '/').Replace('\', '/')
    }
    $fullRoot = [System.IO.Path]::GetFullPath($root).TrimEnd('\', '/')
    if ($fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $fullPath.Substring($fullRoot.Length).TrimStart('\', '/').Replace('\', '/')
    }
    return $fullPath.Replace('\', '/')
}

function Get-TextFiles {
    param(
        [string[]]$Paths,
        [string]$BaseRoot = $root
    )

    $result = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $fullPath = Resolve-ProjectPath $path $BaseRoot
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

    $result = New-Object System.Collections.Generic.List[string]
    foreach ($item in (Convert-ToStringArray $value)) {
        foreach ($part in ($item -split '[+,/]')) {
            $normalized = $part.Trim().ToLowerInvariant().Replace('_', '-').Replace(' ', '-')
            if ($normalized -ne '') { $result.Add($normalized) }
        }
    }
    return @($result | Select-Object -Unique)
}

function Get-MarkerPattern {
    param([string]$Marker)

    $escaped = [regex]::Escape($Marker)
    # Keep this boundary identical to scripts/check-coverage.ps1: prose may use
    # `STO-8.4.8.`, while `STO-8.4.8.1` must not satisfy `STO-8.4.8`.
    return '(?<![A-Za-z0-9.-])' + $escaped + '(?![A-Za-z0-9_-]|\.[0-9])'
}

function Find-MarkerHits {
    param(
        [string]$Marker,
        [System.IO.FileInfo[]]$Files,
        [bool]$CommentOnly
    )

    $pattern = Get-MarkerPattern $Marker
    $hits = New-Object System.Collections.Generic.List[object]
    foreach ($file in $Files) {
        $lineNumber = 0
        foreach ($line in [System.IO.File]::ReadLines($file.FullName, [System.Text.Encoding]::UTF8)) {
            $lineNumber++
            foreach ($match in [regex]::Matches($line, $pattern)) {
                if ($CommentOnly) {
                    $prefix = $line.Substring(0, $match.Index)
                    if ($prefix -notmatch '(--|#|%|//|/\*|<!--)') { continue }
                }
                $excerpt = ($line.Trim() -replace '\s+', ' ')
                if ($excerpt.Length -gt 240) { $excerpt = $excerpt.Substring(0, 237) + '...' }
                $hits.Add([pscustomobject][ordered]@{
                    file = Get-RelativeProjectPath $file.FullName
                    line = $lineNumber
                    excerpt = $excerpt
                })
            }
        }
    }
    return @($hits | Sort-Object file, line -Unique)
}

function New-EvidenceCheck {
    param(
        [object]$Requirement,
        [string]$Kind,
        [string]$DefaultMarker,
        [System.IO.FileInfo[]]$Files,
        [bool]$CommentOnly
    )

    $markerReports = New-Object System.Collections.Generic.List[object]
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($marker in (Get-Markers $Requirement $Kind $DefaultMarker)) {
        $hits = @(Find-MarkerHits -Marker $marker -Files $Files -CommentOnly $CommentOnly)
        $satisfied = $hits.Count -gt 0
        if (-not $satisfied) { $missing.Add($marker) }
        $markerReports.Add([pscustomobject][ordered]@{
            marker = $marker
            satisfied = $satisfied
            hits = $hits
        })
    }

    return [pscustomobject][ordered]@{
        kind = $Kind
        comment_only = $CommentOnly
        satisfied = $missing.Count -eq 0
        missing_markers = $missing.ToArray()
        markers = $markerReports.ToArray()
    }
}

function Escape-MarkdownCell {
    param([object]$Value)

    if ($null -eq $Value) { return '' }
    return (([string]$Value) -replace '\|', '\|' -replace "`r?`n", '<br>')
}

function Get-FileManifest {
    param([System.IO.FileInfo[]]$Files)

    $manifest = New-Object System.Collections.Generic.List[object]
    foreach ($file in ($Files | Sort-Object FullName -Unique)) {
        $manifest.Add([pscustomobject][ordered]@{
            file = Get-RelativeProjectPath $file.FullName
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        })
    }
    return $manifest.ToArray()
}

if (-not (Test-Path -LiteralPath $registry -PathType Leaf)) {
    Write-Error "Traceability registry not found: $registry"
    exit 1
}

try {
    $registryDocument = (Get-Content -LiteralPath $registry -Raw -Encoding UTF8) | ConvertFrom-Json
}
catch {
    Write-Error "Traceability registry is not valid JSON: $($_.Exception.Message)"
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
    Write-Error 'Traceability registry contains no requirements.'
    exit 1
}

# Evidence scopes intentionally mirror scripts/check-coverage.ps1. This report
# and the profile requirements registry are excluded: neither may prove an assertion.
$implementationFiles = @(Get-TextFiles $ImplementationPaths)
$implementationFiles = @($implementationFiles | Sort-Object FullName -Unique)

$testFiles = @(Get-TextFiles $TestPaths)
$testFiles = @($testFiles | Sort-Object FullName -Unique)
$promptFiles = @(Get-TextFiles $PromptPaths)
$semanticFiles = @(Get-TextFiles $SemanticPaths $root)
$externalFiles = @(Get-TextFiles $ExternalPaths $root)

$allEvidenceFiles = @(
    $implementationFiles + $testFiles + $promptFiles + $semanticFiles + $externalFiles |
        Sort-Object FullName -Unique
)

$results = New-Object System.Collections.Generic.List[object]
$globalFailures = New-Object System.Collections.Generic.List[string]
$seenIds = @{}
$sequence = 0

foreach ($requirement in $requirements) {
    $sequence++
    $id = [string](Get-PropertyValue -Object $requirement -Names @('id', 'clause'))
    $mechanisms = @(Get-Mechanisms $requirement)
    $mechanismReports = New-Object System.Collections.Generic.List[object]
    $missingEvidence = New-Object System.Collections.Generic.List[string]

    if ([string]::IsNullOrWhiteSpace($id)) {
        $id = '<missing-id-' + $sequence + '>'
        $globalFailures.Add("${id}: requirement has no id/clause")
        $missingEvidence.Add('registry: missing id/clause')
    }
    elseif ($seenIds.ContainsKey($id)) {
        $globalFailures.Add("${id}: duplicate requirement id")
        $missingEvidence.Add('registry: duplicate requirement id')
    }
    else {
        $seenIds[$id] = $true
    }

    if ($mechanisms.Count -eq 0) {
        $globalFailures.Add("${id}: missing mechanism/enforcement classification")
        $missingEvidence.Add('registry: missing mechanism/enforcement classification')
    }

    $defaultMarker = Get-DefaultMarker $id
    foreach ($mechanism in $mechanisms) {
        $checks = New-Object System.Collections.Generic.List[object]
        $registryOnly = $false

        switch ($mechanism) {
            'programmatic' {
                $checks.Add((New-EvidenceCheck $requirement 'implementation' $defaultMarker $implementationFiles $true))
                $checks.Add((New-EvidenceCheck $requirement 'test' $defaultMarker $testFiles $true))
            }
            'ai' {
                $checks.Add((New-EvidenceCheck $requirement 'prompt' $defaultMarker $promptFiles $false))
                $checks.Add((New-EvidenceCheck $requirement 'semantic' $defaultMarker $semanticFiles $false))
            }
            { $_ -in @('external', 'conflict') } {
                $checks.Add((New-EvidenceCheck $requirement 'external' $defaultMarker $externalFiles $false))
            }
            { $_ -in @('informational', 'not-applicable', 'n-a', 'na') } {
                $registryOnly = $true
            }
            default {
                $globalFailures.Add("${id}: unknown mechanism: $mechanism")
                $missingEvidence.Add("unknown mechanism: $mechanism")
            }
        }

        foreach ($check in $checks) {
            foreach ($marker in $check.missing_markers) {
                $message = "$mechanism/$($check.kind): $marker"
                $missingEvidence.Add($message)
                $globalFailures.Add("${id}: missing $message")
            }
        }

        $mechanismReports.Add([pscustomobject][ordered]@{
            mechanism = $mechanism
            registry_only = $registryOnly
            satisfied = if ($registryOnly) { $true } else { @($checks | Where-Object { -not $_.satisfied }).Count -eq 0 }
            evidence_checks = $checks.ToArray()
        })
    }

    $reportStatus = if ($missingEvidence.Count -gt 0) {
        'missing-evidence'
    }
    elseif ($mechanisms.Count -eq 1 -and $mechanisms[0] -in @('not-applicable', 'n-a', 'na')) {
        'not-applicable'
    }
    elseif ($mechanisms.Count -eq 1 -and $mechanisms[0] -eq 'informational') {
        'informational'
    }
    else {
        'evidence-located'
    }

    $results.Add([pscustomobject][ordered]@{
        sequence = $sequence
        id = $id
        summary = [string](Get-PropertyValue $requirement @('summary'))
        applicability = [string](Get-PropertyValue $requirement @('applicability'))
        mechanisms = $mechanisms
        registry_status = [string](Get-PropertyValue $requirement @('status'))
        registry_notes = [string](Get-PropertyValue $requirement @('notes'))
        report_status = $reportStatus
        missing_evidence = $missingEvidence.ToArray()
        mechanism_reports = $mechanismReports.ToArray()
    })
}

$counts = [ordered]@{
    total = $results.Count
    evidence_located = @($results | Where-Object report_status -eq 'evidence-located').Count
    missing_evidence = @($results | Where-Object report_status -eq 'missing-evidence').Count
    informational = @($results | Where-Object report_status -eq 'informational').Count
    not_applicable = @($results | Where-Object report_status -eq 'not-applicable').Count
}

$report = [pscustomobject][ordered]@{
    schema_version = 1
    profile_id = $ProfileId
    profile_digest = $ProfileDigest
    registry = [pscustomobject][ordered]@{
        file = Get-RelativeProjectPath $registry
        sha256 = (Get-FileHash -LiteralPath $registry -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    checker_relationship = 'Independent evidence report; does not invoke or replace scripts/check-coverage.ps1.'
    evidence_policy = [pscustomobject][ordered]@{
        registry_is_evidence = $false
        programmatic = 'Implementation comment marker and test comment marker are both required.'
        ai = 'Prompt marker and semantic-review marker are both required.'
        external_or_conflict = 'External-acceptance marker is required.'
        informational_or_not_applicable = 'No implementation evidence is required; registry status and notes are reported.'
    }
    evidence_files = @(Get-FileManifest $allEvidenceFiles)
    counts = [pscustomobject]$counts
    requirements = $results.ToArray()
}

$markdown = New-Object System.Collections.Generic.List[string]
$traceabilityTitle = if ($null -ne $registryDocument.metadata -and
    -not [string]::IsNullOrWhiteSpace([string]$registryDocument.metadata.standard)) {
    [string]$registryDocument.metadata.standard + ' requirement traceability'
}
else {
    'Requirement traceability'
}
$markdown.Add('# ' + $traceabilityTitle)
$markdown.Add('')
$markdown.Add(('Profile: `{0}` (`sha256:{1}`).' -f $ProfileId, $ProfileDigest))
$markdown.Add('')
$markdown.Add(('Registry: `{0}` (`sha256:{1}`).' -f $report.registry.file, $report.registry.sha256))
$markdown.Add('')
$markdown.Add('The registry classifies requirements but is not evidence. This report neither invokes nor replaces `scripts/check-coverage.ps1`.')
$markdown.Add('')
$markdown.Add('## Summary')
$markdown.Add('')
$markdown.Add('| Total | Required evidence located | Missing evidence | Informational | Not applicable |')
$markdown.Add('|---:|---:|---:|---:|---:|')
$markdown.Add(('| {0} | {1} | {2} | {3} | {4} |' -f $counts.total, $counts.evidence_located, $counts.missing_evidence, $counts.informational, $counts.not_applicable))
$markdown.Add('')
$markdown.Add('## Requirements')
$markdown.Add('')
$markdown.Add('| No. | Clause | Mechanism | Registry status | Report status | Evidence `file:line` | Registry notes |')
$markdown.Add('|---:|---|---|---|---|---|---|')

foreach ($item in $results) {
    $evidenceParts = New-Object System.Collections.Generic.List[string]
    foreach ($mechanismReport in $item.mechanism_reports) {
        if ($mechanismReport.registry_only) {
            $evidenceParts.Add(('{0}: evidence not required' -f $mechanismReport.mechanism))
            continue
        }
        foreach ($check in $mechanismReport.evidence_checks) {
            foreach ($markerReport in $check.markers) {
                if (-not $markerReport.satisfied) {
                    $evidenceParts.Add(('**MISSING** {0}/{1}: `{2}`' -f $mechanismReport.mechanism, $check.kind, $markerReport.marker))
                    continue
                }
                $locations = @($markerReport.hits | ForEach-Object { '`' + $_.file + ':' + $_.line + '`' }) -join ', '
                $evidenceParts.Add(('{0}/{1} `{2}` -> {3}' -f $mechanismReport.mechanism, $check.kind, $markerReport.marker, $locations))
            }
        }
    }
    if ($evidenceParts.Count -eq 0) { $evidenceParts.Add('-') }

    $markdown.Add(('| {0} | `{1}` | {2} | {3} | **{4}** | {5} | {6} |' -f
        $item.sequence,
        (Escape-MarkdownCell $item.id),
        (Escape-MarkdownCell ($item.mechanisms -join ', ')),
        (Escape-MarkdownCell $item.registry_status),
        (Escape-MarkdownCell $item.report_status),
        (Escape-MarkdownCell ($evidenceParts -join '<br>')),
        (Escape-MarkdownCell $item.registry_notes)))
}

$jsonOutput = Resolve-ProjectPath $JsonOutputPath $WorkspaceRoot
$markdownOutput = Resolve-ProjectPath $MarkdownOutputPath $WorkspaceRoot
foreach ($output in @($jsonOutput, $markdownOutput)) {
    $directory = Split-Path -Parent $output
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($jsonOutput, (($report | ConvertTo-Json -Depth 14) + "`n"), $utf8NoBom)
[System.IO.File]::WriteAllText($markdownOutput, (($markdown -join "`n") + "`n"), $utf8NoBom)

Write-Host ('Traceability JSON: {0}' -f (Get-RelativeProjectPath $jsonOutput))
Write-Host ('Traceability Markdown: {0}' -f (Get-RelativeProjectPath $markdownOutput))

if ($globalFailures.Count -gt 0) {
    Write-Host ('STO traceability failed: {0} evidence problem(s) across {1} requirement(s).' -f $globalFailures.Count, $counts.missing_evidence) -ForegroundColor Red
    foreach ($failure in $globalFailures) { Write-Host ('  - ' + $failure) }
    exit 1
}

Write-Host ('STO traceability passed: {0} requirement(s), all required evidence located.' -f $counts.total) -ForegroundColor Green
exit 0
