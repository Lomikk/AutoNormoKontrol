[CmdletBinding()]
param(
    [string]$ProfilePath = '',
    [string]$InventoryPath = '',
    [string]$RequirementsPath = '',
    [string[]]$ImplementationPaths = @(),
    [string[]]$TestPaths = @()
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'profile.ps1')
. (Join-Path $PSScriptRoot 'requirements.ps1')

function Get-CoverageTextFiles {
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

function Test-CoverageCommentMarker {
    param(
        [Parameter(Mandatory = $true)][string]$Marker,
        [System.IO.FileInfo[]]$Files
    )
    $pattern = '(?<![A-Za-z0-9.-])' + [regex]::Escape($Marker) +
        '(?![A-Za-z0-9_-]|\.[0-9])'
    foreach ($file in $Files) {
        foreach ($line in [System.IO.File]::ReadLines(
            $file.FullName,
            [System.Text.Encoding]::UTF8
        )) {
            $match = [regex]::Match($line, $pattern)
            if ($match.Success -and $line.Substring(0, $match.Index) -match '(--|#|%|//|/\*|<!--)') {
                return $true
            }
        }
    }
    return $false
}

try {
    $profile = Resolve-AutoNormoKontrolProfile -Root $root -ProfilePath $ProfilePath
    if (-not $PSBoundParameters.ContainsKey('ImplementationPaths')) {
        $ImplementationPaths = @($profile.Data.compliance.implementation_paths)
    }
    if (-not $PSBoundParameters.ContainsKey('TestPaths')) {
        $TestPaths = @($profile.Data.compliance.test_paths)
    }
    $contractParameters = @{
        Root = $root
        Profile = $profile
    }
    if ($PSBoundParameters.ContainsKey('InventoryPath')) {
        $contractParameters.InventoryPath = $InventoryPath
    }
    if ($PSBoundParameters.ContainsKey('RequirementsPath')) {
        $contractParameters.RequirementsPath = $RequirementsPath
    }
    $contract = Get-AutoNormoKontrolRequirementContract @contractParameters
    $implementationFiles = @(Get-CoverageTextFiles $ImplementationPaths)
    $testFiles = @(Get-CoverageTextFiles $TestPaths)
    $failures = New-Object System.Collections.Generic.List[string]

    # R0/requirements-v2: inventory exact-set, verification types, diagnostic
    # references and the check allow-list have already failed closed while the
    # effective contract was compiled. The independent coverage gate now proves
    # that every declared programmatic rule still has real code and a real test.
    foreach ($requirement in @($contract.requirements)) {
        $programmatic = @($requirement.verification | Where-Object kind -eq 'programmatic')
        if ($programmatic.Count -eq 0) { continue }
        foreach ($marker in @($requirement.coverage.implementation_markers)) {
            if (-not (Test-CoverageCommentMarker -Marker ([string]$marker) -Files $implementationFiles)) {
                $failures.Add("$($requirement.id): implementation comment marker not found: $marker")
            }
        }
        foreach ($marker in @($requirement.coverage.test_markers)) {
            if (-not (Test-CoverageCommentMarker -Marker ([string]$marker) -Files $testFiles)) {
                $failures.Add("$($requirement.id): test comment marker not found: $marker")
            }
        }
    }

    if ($failures.Count -gt 0) {
        foreach ($failure in $failures) { Write-Error $failure }
        exit 1
    }
    Write-Host ("Requirement coverage passed: {0} canonical entries; {1} semantic; {2} external." -f
        $contract.requirements.Count,
        $contract.semantic_items.Count,
        $contract.external_items.Count)
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
