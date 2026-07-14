[CmdletBinding()]
param(
    [string]$ProjectRoot = '',
    [string]$ManifestPath = 'assets/manifest.json',
    [string]$ReportPath = 'build/asset-report.json',
    [string[]]$Id = @()
)

$ErrorActionPreference = 'Stop'

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Resolve-ProjectPath {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$AllowedDirectory
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        throw 'Manifest contains an empty path.'
    }
    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "Absolute paths are forbidden in the asset pipeline: $RelativePath"
    }

    $candidate = [System.IO.Path]::GetFullPath((Join-Path $script:ProjectRootFull $RelativePath))
    $allowed = [System.IO.Path]::GetFullPath((Join-Path $script:ProjectRootFull $AllowedDirectory))
    $allowedPrefix = $allowed.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidate.Equals($allowed, [StringComparison]::OrdinalIgnoreCase) -and
        -not $candidate.StartsWith($allowedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path leaves the allowed '$AllowedDirectory' directory: $RelativePath"
    }
    return $candidate
}

function Assert-RequiredProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$AssetId
    )

    if ($Object.PSObject.Properties.Name -notcontains $Name) {
        throw "Asset '$AssetId' is missing required manifest field '$Name'."
    }
    $value = $Object.$Name
    if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
        throw "Asset '$AssetId' has an empty manifest field '$Name'."
    }
}

function Remove-GeneratedFiles {
    param(
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [string]$AssetId,
        [switch]$All
    )

    if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) { return }
    $files = @(Get-ChildItem -LiteralPath $OutputDirectory -File -Force)
    if (-not $All) {
        $files = @($files | Where-Object { $_.BaseName -eq $AssetId })
    }
    foreach ($file in $files) {
        Remove-Item -LiteralPath $file.FullName -Force
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

    $manifestFull = Resolve-ProjectPath -RelativePath $ManifestPath -AllowedDirectory 'assets'
    $reportFull = Resolve-ProjectPath -RelativePath $ReportPath -AllowedDirectory 'build'
    if (-not (Test-Path -LiteralPath $manifestFull -PathType Leaf)) {
        throw "Asset manifest not found: $ManifestPath"
    }

    try {
        $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestFull | ConvertFrom-Json
    }
    catch {
        throw "Asset manifest is not valid JSON: $($_.Exception.Message)"
    }
    if ($manifest.version -ne 1) {
        throw "Unsupported asset manifest version '$($manifest.version)'; expected 1."
    }
    if ($null -eq $manifest.assets) {
        throw 'Asset manifest must contain an assets array.'
    }

    $knownAssets = [ordered]@{}
    foreach ($asset in @($manifest.assets)) {
        Assert-RequiredProperty $asset 'id' '<unknown>'
        $assetId = [string]$asset.id
        if ($assetId -notmatch '^[a-z][a-z0-9-]*$') {
            throw "Invalid asset ID '$assetId'; use lowercase ASCII letters, digits and hyphens."
        }
        if ($knownAssets.Contains($assetId)) {
            throw "Duplicate asset ID in manifest: $assetId"
        }
        foreach ($field in @('type', 'sources', 'generator', 'output', 'tex-source',
                'data-source', 'provenance', 'license')) {
            Assert-RequiredProperty $asset $field $assetId
        }
        foreach ($forbidden in @('command', 'arguments', 'shell', 'script')) {
            if ($asset.PSObject.Properties.Name -contains $forbidden) {
                throw "Asset '$assetId' contains forbidden executable field '$forbidden'."
            }
        }

        # R1.1 whitelist: the manifest selects a symbolic generator only. It
        # never supplies an executable, arguments or a shell command.
        if ([string]$asset.type -ne 'plot' -or [string]$asset.generator -ne 'tex-pgfplots') {
            throw "Asset '$assetId' uses unsupported type/generator '$($asset.type)/$($asset.generator)'. Allowed: plot/tex-pgfplots."
        }

        $expectedTex = "assets/plots/$assetId.tex"
        $expectedOutput = "build/assets/$assetId.pdf"
        $texRelative = ([string]$asset.'tex-source').Replace('\', '/')
        $dataRelative = ([string]$asset.'data-source').Replace('\', '/')
        $outputRelative = ([string]$asset.output).Replace('\', '/')
        if ($texRelative -ne $expectedTex) {
            throw "Asset '$assetId' tex-source must be '$expectedTex'."
        }
        if ($outputRelative -ne $expectedOutput) {
            throw "Asset '$assetId' output must be '$expectedOutput'."
        }
        if ($dataRelative -notmatch '^assets/data/[A-Za-z0-9._-]+\.csv$') {
            throw "Asset '$assetId' data-source must be one CSV directly under assets/data/."
        }

        $declaredSources = @($asset.sources | ForEach-Object { ([string]$_).Replace('\', '/') })
        $expectedSources = @($texRelative, $dataRelative)
        if ($declaredSources.Count -ne 2 -or
            @($expectedSources | Where-Object { $declaredSources -notcontains $_ }).Count -ne 0) {
            throw "Asset '$assetId' sources must contain exactly tex-source and data-source."
        }

        $texFull = Resolve-ProjectPath -RelativePath $texRelative -AllowedDirectory 'assets/plots'
        $dataFull = Resolve-ProjectPath -RelativePath $dataRelative -AllowedDirectory 'assets/data'
        $outputFull = Resolve-ProjectPath -RelativePath $outputRelative -AllowedDirectory 'build/assets'
        if (-not (Test-Path -LiteralPath $texFull -PathType Leaf)) {
            throw "Asset '$assetId' TeX source not found: $texRelative"
        }
        if (-not (Test-Path -LiteralPath $dataFull -PathType Leaf)) {
            throw "Asset '$assetId' CSV data source not found: $dataRelative"
        }

        $knownAssets[$assetId] = [pscustomobject][ordered]@{
            manifest = $asset
            id = $assetId
            type = [string]$asset.type
            generator = [string]$asset.generator
            tex_relative = $texRelative
            tex_full = $texFull
            data_relative = $dataRelative
            data_full = $dataFull
            output_relative = $outputRelative
            output_full = $outputFull
        }
    }

    $selectedIds = if ($Id.Count -gt 0) { @($Id) } else { @($knownAssets.Keys) }
    foreach ($requestedId in $selectedIds) {
        if (-not $knownAssets.Contains($requestedId)) {
            throw "Unknown asset ID '$requestedId' in manifest '$ManifestPath'."
        }
    }

    $latexmk = Get-Command latexmk -ErrorAction SilentlyContinue
    if ($null -eq $latexmk) {
        throw 'latexmk was not found in PATH.'
    }

    $outputDirectory = Resolve-ProjectPath -RelativePath 'build/assets' -AllowedDirectory 'build/assets'
    $texCache = Resolve-ProjectPath -RelativePath 'build/texmf-var' -AllowedDirectory 'build'
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
    New-Item -ItemType Directory -Force -Path $texCache | Out-Null
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $reportFull) | Out-Null

    if ($Id.Count -eq 0) {
        # build/assets is disposable generated state. A normal full build starts
        # from an empty file set so removed manifest entries cannot survive.
        Remove-GeneratedFiles -OutputDirectory $outputDirectory -All
    }
    else {
        foreach ($selectedId in $selectedIds) {
            Remove-GeneratedFiles -OutputDirectory $outputDirectory -AssetId $selectedId
        }
    }

    $oldLocation = Get-Location
    $oldSourceDateEpoch = $env:SOURCE_DATE_EPOCH
    $oldForceSourceDate = $env:FORCE_SOURCE_DATE
    $oldTexmfVar = $env:TEXMFVAR
    $oldTexmfCache = $env:TEXMFCACHE
    $oldLcAll = $env:LC_ALL
    $oldLcCtype = $env:LC_CTYPE
    $oldLang = $env:LANG
    try {
        Set-Location -LiteralPath $script:ProjectRootFull
        # Fixed PDF metadata makes identical sources byte-reproducible across
        # repeated local builds with the same TeX toolchain.
        $env:SOURCE_DATE_EPOCH = '946684800'
        $env:FORCE_SOURCE_DATE = '1'
        $env:TEXMFVAR = $texCache
        $env:TEXMFCACHE = $texCache
        $env:LC_ALL = $null
        $env:LC_CTYPE = $null
        $env:LANG = $null

        foreach ($selectedId in $selectedIds) {
            $assetInfo = $knownAssets[$selectedId]
            Write-Host ("Building asset {0} ({1})" -f $selectedId, $assetInfo.generator)
            $latexmkArguments = @(
                '-norc',
                '-lualatex',
                '-interaction=nonstopmode',
                '-halt-on-error',
                '-file-line-error',
                '-no-shell-escape',
                "-outdir=$outputDirectory",
                $assetInfo.tex_relative
            )
            & $latexmk.Source @latexmkArguments
            if ($LASTEXITCODE -ne 0) {
                throw "Asset '$selectedId' compilation failed with exit code $LASTEXITCODE."
            }
            if (-not (Test-Path -LiteralPath $assetInfo.output_full -PathType Leaf)) {
                throw "Asset '$selectedId' did not produce expected output: $($assetInfo.output_relative)"
            }
        }
    }
    finally {
        Set-Location -LiteralPath $oldLocation
        $env:SOURCE_DATE_EPOCH = $oldSourceDateEpoch
        $env:FORCE_SOURCE_DATE = $oldForceSourceDate
        $env:TEXMFVAR = $oldTexmfVar
        $env:TEXMFCACHE = $oldTexmfCache
        $env:LC_ALL = $oldLcAll
        $env:LC_CTYPE = $oldLcCtype
        $env:LANG = $oldLang
    }

    $reportAssets = @()
    foreach ($selectedId in $selectedIds) {
        $assetInfo = $knownAssets[$selectedId]
        $sourceRecords = @(
            [pscustomobject][ordered]@{
                path = $assetInfo.tex_relative
                sha256 = Get-Sha256 $assetInfo.tex_full
            },
            [pscustomobject][ordered]@{
                path = $assetInfo.data_relative
                sha256 = Get-Sha256 $assetInfo.data_full
            }
        )
        $reportAssets += [pscustomobject][ordered]@{
            id = $assetInfo.id
            type = $assetInfo.type
            generator = $assetInfo.generator
            sources = $sourceRecords
            data_source = [pscustomobject][ordered]@{
                path = $assetInfo.data_relative
                sha256 = Get-Sha256 $assetInfo.data_full
            }
            output = [pscustomobject][ordered]@{
                path = $assetInfo.output_relative
                sha256 = Get-Sha256 $assetInfo.output_full
            }
            provenance = [string]$assetInfo.manifest.provenance
            license = [string]$assetInfo.manifest.license
        }
    }

    $report = [pscustomobject][ordered]@{
        version = 1
        manifest = [pscustomobject][ordered]@{
            path = $ManifestPath.Replace('\', '/')
            sha256 = Get-Sha256 $manifestFull
        }
        assets = $reportAssets
    }
    [System.IO.File]::WriteAllText(
        $reportFull,
        ($report | ConvertTo-Json -Depth 10),
        (New-Object System.Text.UTF8Encoding($false))
    )

    # Only final PDFs belong in build/assets; latexmk intermediates are not
    # inputs and cannot affect the next build.
    foreach ($file in @(Get-ChildItem -LiteralPath $outputDirectory -File -Force)) {
        if ($file.Extension -ne '.pdf') {
            Remove-Item -LiteralPath $file.FullName -Force
        }
    }

    Write-Host ("Asset report: {0}" -f $ReportPath)
    exit 0
}
catch {
    Write-Error ("Asset pipeline failed: {0}" -f $_.Exception.Message)
    exit 1
}
