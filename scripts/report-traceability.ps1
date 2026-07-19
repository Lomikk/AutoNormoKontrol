[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$WorkspaceRoot,
    [string]$InventoryPath = '',
    [string]$RequirementsPath = '',
    [string]$JsonOutputPath = '',
    [string]$MarkdownOutputPath = '',
    [string[]]$ImplementationPaths = @(),
    [string[]]$TestPaths = @()
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$WorkspaceRoot = [System.IO.Path]::GetFullPath($WorkspaceRoot)
. (Join-Path $PSScriptRoot 'profile.ps1')
. (Join-Path $PSScriptRoot 'workspace.ps1')
. (Join-Path $PSScriptRoot 'requirements.ps1')

function Get-TraceFiles {
    param([string[]]$Paths)
    $result = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $full = if ([System.IO.Path]::IsPathRooted($path)) { $path } else { Join-Path $root $path }
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            $result.Add((Get-Item -LiteralPath $full))
        }
        elseif (Test-Path -LiteralPath $full -PathType Container) {
            Get-ChildItem -LiteralPath $full -Recurse -File | ForEach-Object { $result.Add($_) }
        }
    }
    return @($result | Sort-Object FullName -Unique)
}

function Get-TraceRelativePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $rootFull = [System.IO.Path]::GetFullPath($root).TrimEnd('\', '/')
    if ($full.StartsWith($rootFull + [System.IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($rootFull.Length).TrimStart('\', '/').Replace('\', '/')
    }
    return $full.Replace('\', '/')
}

function Find-TraceMarker {
    param(
        [Parameter(Mandatory = $true)][string]$Marker,
        [System.IO.FileInfo[]]$Files
    )
    $pattern = '(?<![A-Za-z0-9.-])' + [regex]::Escape($Marker) +
        '(?![A-Za-z0-9_-]|\.[0-9])'
    $hits = New-Object System.Collections.Generic.List[object]
    foreach ($file in $Files) {
        $lineNumber = 0
        foreach ($line in [System.IO.File]::ReadLines(
            $file.FullName,
            [System.Text.Encoding]::UTF8
        )) {
            $lineNumber++
            $match = [regex]::Match($line, $pattern)
            if (-not $match.Success -or
                $line.Substring(0, $match.Index) -notmatch '(--|#|%|//|/\*|<!--)') {
                continue
            }
            $hits.Add([pscustomobject][ordered]@{
                file = Get-TraceRelativePath $file.FullName
                line = $lineNumber
            })
        }
    }
    return $hits.ToArray()
}

function Escape-TraceMarkdown {
    param([object]$Value)
    return (([string]$Value) -replace '\|', '\|' -replace "`r?`n", '<br>')
}

try {
    $workspace = Resolve-AutoNormoKontrolWorkspace `
        -EngineRoot $root -WorkspaceRoot $WorkspaceRoot
    $profile = $workspace.Profile
    if ([string]::IsNullOrWhiteSpace($JsonOutputPath)) {
        $JsonOutputPath = [string]$profile.Data.reports.traceability_json
    }
    if ([string]::IsNullOrWhiteSpace($MarkdownOutputPath)) {
        $MarkdownOutputPath = [string]$profile.Data.reports.traceability_markdown
    }
    if (-not $PSBoundParameters.ContainsKey('ImplementationPaths')) {
        $ImplementationPaths = @($profile.Data.compliance.implementation_paths)
    }
    if (-not $PSBoundParameters.ContainsKey('TestPaths')) {
        $TestPaths = @($profile.Data.compliance.test_paths)
    }
    $contractParameters = @{ Root = $root; Profile = $profile }
    if ($PSBoundParameters.ContainsKey('InventoryPath')) {
        $contractParameters.InventoryPath = $InventoryPath
    }
    if ($PSBoundParameters.ContainsKey('RequirementsPath')) {
        $contractParameters.RequirementsPath = $RequirementsPath
    }
    $contract = Get-AutoNormoKontrolRequirementContract @contractParameters
    $implementationFiles = @(Get-TraceFiles $ImplementationPaths)
    $testFiles = @(Get-TraceFiles $TestPaths)
    $results = New-Object System.Collections.Generic.List[object]
    $missing = New-Object System.Collections.Generic.List[string]

    foreach ($requirement in @($contract.requirements)) {
        $checks = New-Object System.Collections.Generic.List[object]
        foreach ($verification in @($requirement.verification)) {
            if ([string]$verification.kind -eq 'programmatic') {
                $implementationHits = New-Object System.Collections.Generic.List[object]
                foreach ($marker in @($requirement.coverage.implementation_markers)) {
                    foreach ($hit in @(Find-TraceMarker $marker $implementationFiles)) {
                        $implementationHits.Add($hit)
                    }
                }
                $testHits = New-Object System.Collections.Generic.List[object]
                foreach ($marker in @($requirement.coverage.test_markers)) {
                    foreach ($hit in @(Find-TraceMarker $marker $testFiles)) { $testHits.Add($hit) }
                }
                $satisfied = $implementationHits.Count -gt 0 -and $testHits.Count -gt 0
                if (-not $satisfied) { $missing.Add("$($requirement.id): programmatic evidence") }
                $checks.Add([pscustomobject][ordered]@{
                    kind = 'programmatic'
                    check = [string]$verification.check
                    diagnostic = [string]$verification.diagnostic
                    satisfied = $satisfied
                    implementation_hits = $implementationHits.ToArray()
                    test_hits = $testHits.ToArray()
                })
            }
            elseif ([string]$verification.kind -eq 'semantic') {
                $checks.Add([pscustomobject][ordered]@{
                    kind = 'semantic'
                    review_id = [string]$verification.review_id
                    satisfied = $true
                    note = 'Review item is generated from requirements; release status remains workspace-owned.'
                })
            }
            elseif ([string]$verification.kind -eq 'external') {
                $checks.Add([pscustomobject][ordered]@{
                    kind = 'external'
                    review_id = [string]$verification.review_id
                    satisfied = $true
                    note = 'Acceptance item is generated from requirements; the decision remains external.'
                })
            }
        }
        $source = @($contract.inventory.document.entries | Where-Object id -eq $requirement.id)[0]
        $sourceClause = if ($null -ne $source) {
            [string]$source.clause
        }
        else { [string]$requirement.origin.locator }
        $summary = if ($null -ne $source) {
            [string]$source.summary
        }
        else { [string]$requirement.summary }
        $results.Add([pscustomobject][ordered]@{
            id = [string]$requirement.id
            source_ref = [string]$requirement.source_ref
            origin = $requirement.origin
            source_clause = $sourceClause
            summary = $summary
            disposition = [string]$requirement.disposition
            scope = [string]$requirement.scope
            status = if (@($checks | Where-Object { -not $_.satisfied }).Count -eq 0) {
                'evidence-located'
            } else { 'missing-evidence' }
            verification = $checks.ToArray()
            notes = [string]$requirement.notes
        })
    }

    $report = [pscustomobject][ordered]@{
        schema_version = 2
        profile_id = $profile.ProfileId
        profile_digest = $profile.ProfileDigest
        inventory = [pscustomobject][ordered]@{
            path = $contract.inventory.path
            sha256 = $contract.inventory.sha256
        }
        requirements_registry = [pscustomobject][ordered]@{
            path = $contract.registry.path
            sha256 = $contract.registry.sha256
        }
        counts = [pscustomobject][ordered]@{
            total = $results.Count
            evidence_located = @($results | Where-Object status -eq 'evidence-located').Count
            missing_evidence = @($results | Where-Object status -eq 'missing-evidence').Count
            semantic_items = $contract.semantic_items.Count
            external_items = $contract.external_items.Count
        }
        requirements = $results.ToArray()
    }
    $jsonFull = Join-Path $WorkspaceRoot $JsonOutputPath
    $markdownFull = Join-Path $WorkspaceRoot $MarkdownOutputPath
    foreach ($path in @($jsonFull, $markdownFull)) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($jsonFull, ($report | ConvertTo-Json -Depth 20), $encoding)

    $markdown = New-Object System.Collections.Generic.List[string]
    $markdown.Add('# Requirement traceability v2')
    $markdown.Add('')
    $markdown.Add("Profile: ``$($profile.ProfileId)``.")
    $markdown.Add('')
    $markdown.Add('| ID | Source | Disposition | Verification | Status |')
    $markdown.Add('|---|---|---|---|---|')
    foreach ($item in $results) {
        $kinds = @($item.verification | ForEach-Object kind | Sort-Object -Unique) -join ', '
        $sourceLocation = [string]$item.source_clause
        $markdown.Add(('| {0} | {1} | {2} | {3} | {4} |' -f
            (Escape-TraceMarkdown $item.id),
            (Escape-TraceMarkdown $sourceLocation),
            (Escape-TraceMarkdown $item.disposition),
            (Escape-TraceMarkdown $kinds),
            (Escape-TraceMarkdown $item.status)))
    }
    [System.IO.File]::WriteAllText($markdownFull, ($markdown -join "`n") + "`n", $encoding)
    Write-Host "Traceability JSON: $JsonOutputPath"
    Write-Host "Traceability Markdown: $MarkdownOutputPath"
    if ($missing.Count -gt 0) {
        foreach ($item in $missing) { Write-Error $item }
        exit 1
    }
    Write-Host ("Requirement traceability passed: {0} requirement(s)." -f $results.Count)
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
