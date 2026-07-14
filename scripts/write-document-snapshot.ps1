[CmdletBinding()]
param(
    [string]$ProjectRoot = '',
    [string]$AssetReportPath = 'build/asset-report.json',
    [string]$OutputPath = 'build/document-snapshot.json',
    [string[]]$ContentPaths = @(
        'content/00-introduction.md',
        'content/01-literature-review.md',
        'content/02-main.md',
        'content/03-conclusion.md',
        'content/90-bibliography.md',
        'content/99-appendix.md',
        'metadata.yaml',
        'bibliography.bib'
    )
)

$ErrorActionPreference = 'Stop'

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Resolve-SnapshotPath {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        [System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "Snapshot paths must be non-empty project-relative paths: $RelativePath"
    }
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $script:ProjectRootFull $RelativePath))
    $prefix = $script:ProjectRootFull.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Snapshot path leaves the project root: $RelativePath"
    }
    return $candidate
}

function Assert-RecordedHash {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$ExpectedHash,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $full = Resolve-SnapshotPath $RelativePath
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "$Label is missing: $RelativePath"
    }
    $actual = Get-Sha256 $full
    if ($actual -ne $ExpectedHash.ToLowerInvariant()) {
        throw "$Label changed after asset report generation: $RelativePath"
    }
}

try {
    if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
        $ProjectRoot = Split-Path -Parent $PSScriptRoot
    }
    $script:ProjectRootFull = [System.IO.Path]::GetFullPath($ProjectRoot)
    if (-not (Test-Path -LiteralPath $script:ProjectRootFull -PathType Container)) {
        throw "Project root does not exist: $script:ProjectRootFull"
    }

    $assetReportFull = Resolve-SnapshotPath $AssetReportPath
    $outputFull = Resolve-SnapshotPath $OutputPath
    if (-not (Test-Path -LiteralPath $assetReportFull -PathType Leaf)) {
        throw "Asset report not found: $AssetReportPath"
    }
    try {
        $assetReport = Get-Content -Raw -Encoding UTF8 -LiteralPath $assetReportFull | ConvertFrom-Json
    }
    catch {
        throw "Asset report is not valid JSON: $($_.Exception.Message)"
    }
    if ($assetReport.version -ne 1 -or $null -eq $assetReport.manifest -or
        $null -eq $assetReport.assets) {
        throw 'Asset report has an unsupported or incomplete structure.'
    }

    Assert-RecordedHash ([string]$assetReport.manifest.path) `
        ([string]$assetReport.manifest.sha256) 'Asset manifest'

    $paths = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' `
        ([StringComparer]::OrdinalIgnoreCase)
    function Add-SnapshotPath {
        param([string]$RelativePath)
        $normalized = $RelativePath.Replace('\', '/')
        if ($seen.Add($normalized)) { $paths.Add($normalized) }
    }

    foreach ($path in $ContentPaths) { Add-SnapshotPath $path }
    Add-SnapshotPath ([string]$assetReport.manifest.path)
    foreach ($asset in @($assetReport.assets)) {
        foreach ($source in @($asset.sources)) {
            Assert-RecordedHash ([string]$source.path) ([string]$source.sha256) `
                ("Asset '{0}' source" -f $asset.id)
            Add-SnapshotPath ([string]$source.path)
        }
        Assert-RecordedHash ([string]$asset.output.path) ([string]$asset.output.sha256) `
            ("Asset '{0}' output" -f $asset.id)
        Add-SnapshotPath ([string]$asset.output.path)
    }

    $records = @()
    foreach ($relative in $paths) {
        $full = Resolve-SnapshotPath $relative
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw "Document snapshot input is missing: $relative"
        }
        $records += [pscustomobject][ordered]@{
            path = $relative
            sha256 = Get-Sha256 $full
        }
    }

    $canonicalLines = @($records | ForEach-Object {
        $_.path + [char]0 + $_.sha256
    })
    $canonicalBytes = [System.Text.Encoding]::UTF8.GetBytes(($canonicalLines -join "`n"))
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $snapshotHash = ([System.BitConverter]::ToString(
            $sha256.ComputeHash($canonicalBytes)
        )).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }

    $snapshot = [pscustomobject][ordered]@{
        version = 1
        profile_id = 'susu-hsem-ceit-coursework-v1'
        algorithm = 'sha256(path-null-file-sha256)'
        content_hash = $snapshotHash
        files = $records
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outputFull) | Out-Null
    [System.IO.File]::WriteAllText(
        $outputFull,
        ($snapshot | ConvertTo-Json -Depth 8),
        (New-Object System.Text.UTF8Encoding($false))
    )
    Write-Host ("Document snapshot: {0}" -f $snapshotHash)
    exit 0
}
catch {
    Write-Error ("Document snapshot failed: {0}" -f $_.Exception.Message)
    exit 1
}
