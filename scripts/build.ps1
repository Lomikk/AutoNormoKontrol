param(
    [ValidateSet('Draft', 'Strict')]
    [string]$Mode = 'Draft',
    [string]$ProfilePath = ''
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root
. (Join-Path $PSScriptRoot 'utf8-native.ps1')
. (Join-Path $PSScriptRoot 'profile.ps1')

$profile = Resolve-AutoNormoKontrolProfile -Root $root -ProfilePath $ProfilePath
$config = $profile.Data
$content = @($config.inputs.content | ForEach-Object { [string]$_ })
$metadataPath = [string]$config.inputs.metadata
$bibliographyPath = [string]$config.inputs.bibliography
$assetManifestPath = [string]$config.inputs.asset_manifest
$reviewInventoryPath = [string]$config.compliance.review_inventory
$semanticReviewPath = [string]$config.compliance.semantic_review
$externalAcceptancePath = [string]$config.compliance.external_acceptance
$assetReportPath = [string]$config.assets.report
$assetBuildPath = [string]$config.assets.output_directory
$snapshotPath = [string]$config.reports.document_snapshot
$buildReportPath = [string]$config.reports.build_report
$postflightReportPath = [string]$config.reports.postflight
$outputTexPath = [string]$config.outputs.tex
$outputPdfPath = [string]$config.outputs.pdf

& (Join-Path $PSScriptRoot 'check-coverage.ps1') -ProfilePath $profile.ManifestPath
if (-not $?) { exit 1 }

# STO-TRACEABILITY: every normal build refreshes the human- and
# machine-readable file:line ledger after the fail-closed coverage gate.
& (Join-Path $PSScriptRoot 'report-traceability.ps1') -ProfilePath $profile.ManifestPath
if (-not $?) { exit 1 }

& (Join-Path $PSScriptRoot 'lint-content.ps1') -ContentPaths $content
if (-not $?) { exit 1 }

$build = Split-Path -Parent (Join-Path $root $outputPdfPath)
$assetBuild = Join-Path $root $assetBuildPath
$texCache = Join-Path $build 'texmf-var'
New-Item -ItemType Directory -Force -Path $assetBuild | Out-Null
New-Item -ItemType Directory -Force -Path $texCache | Out-Null

# R1.1: build only manifest-declared assets through the fixed generator
# whitelist. fixtures/ remain test data and never participate in this path.
& (Join-Path $PSScriptRoot 'build-assets.ps1') `
    -ManifestPath $assetManifestPath `
    -ReportPath $assetReportPath
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# STO-AI-GATE, R1.1: bind semantic review to the complete verifiable document
# snapshot: Markdown, metadata, bibliography, asset manifest, source data,
# TeX plot source and generated PDF. Any one of them invalidates stale review.
& (Join-Path $PSScriptRoot 'write-document-snapshot.ps1') `
    -ProfileId $profile.ProfileId `
    -AssetReportPath $assetReportPath `
    -OutputPath $snapshotPath `
    -ContentPaths (@($content) + @($metadataPath, $bibliographyPath))
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$snapshot = Get-Content -Raw -Encoding UTF8 -LiteralPath $snapshotPath | ConvertFrom-Json
$assetReport = Get-Content -Raw -Encoding UTF8 -LiteralPath $assetReportPath | ConvertFrom-Json
$contentHash = [string]$snapshot.content_hash
$modeValue = $Mode.ToLowerInvariant()

$oldTexInputs = $env:TEXINPUTS
$oldTexmfVar = $env:TEXMFVAR
$oldTexmfCache = $env:TEXMFCACHE
$oldLcAll = $env:LC_ALL
$oldLcCtype = $env:LC_CTYPE
$oldLang = $env:LANG
try {
    # TeX Live's Windows Perl does not provide the Unix C.UTF-8 locale that
    # some terminals export. Let it use the native Windows locale instead.
    $env:LC_ALL = $null
    $env:LC_CTYPE = $null
    $env:LANG = $null
    $env:TEXMFVAR = $texCache
    $env:TEXMFCACHE = $texCache
    $texInputs = @($config.render.tex_input_paths | ForEach-Object {
        Resolve-ProfileProjectPath -Root $root -Path ([string]$_) `
            -Location 'render.tex_input_paths' -Kind Directory
    })
    $env:TEXINPUTS = ($texInputs -join ';') + ';'

    $pandocArguments = @($content) + @(
        "--from=$($config.render.pandoc_from)",
        '--to=latex',
        '--standalone',
        '--number-sections',
        '--top-level-division=section',
        "--metadata-file=$metadataPath",
        "--metadata-file=$reviewInventoryPath",
        "--metadata-file=$semanticReviewPath",
        "--metadata-file=$externalAcceptancePath",
        "--metadata=compliance-mode:$modeValue",
        "--metadata=active-profile-id:$($profile.ProfileId)",
        "--metadata=content-hash:$contentHash",
        "--template=$($config.render.template)"
    )
    foreach ($filter in @($config.render.lua_filters)) {
        $pandocArguments += "--lua-filter=$filter"
    }
    $pandocArguments += @(
        '--biblatex',
        "--resource-path=$root;$build",
        "--output=$outputTexPath"
    )
    $pandocPath = Resolve-PandocExecutable
    $pandocResult = Invoke-Utf8NativeCommand `
        -FilePath $pandocPath `
        -Arguments $pandocArguments `
        -WorkingDirectory $root
    Write-NativeCommandResult $pandocResult
    if ($pandocResult.ExitCode -ne 0) { exit $pandocResult.ExitCode }

    $texOutputDirectory = Split-Path -Parent (Join-Path $root $outputTexPath)
    & latexmk -lualatex -interaction=nonstopmode -halt-on-error -file-line-error `
        "-outdir=$texOutputDirectory" $outputTexPath
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    & (Join-Path $root ([string]$config.render.postflight)) `
        -ProjectRoot $root -PdfPath $outputPdfPath -TexPath $outputTexPath `
        -ReportPath $postflightReportPath
    if (-not $?) { exit 1 }
}
finally {
    $env:TEXINPUTS = $oldTexInputs
    $env:TEXMFVAR = $oldTexmfVar
    $env:TEXMFCACHE = $oldTexmfCache
    $env:LC_ALL = $oldLcAll
    $env:LC_CTYPE = $oldLcCtype
    $env:LANG = $oldLang
}

Write-Host ''
$pdfRelative = $outputPdfPath
$pdf = Get-Item -LiteralPath $pdfRelative
$pdfHash = (Get-FileHash -LiteralPath $pdf.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
$buildReport = [pscustomobject][ordered]@{
    version = 1
    profile_id = $profile.ProfileId
    profile_manifest = [pscustomobject][ordered]@{
        path = $profile.ManifestPath
        sha256 = $profile.ManifestSha256
    }
    profile_digest = $profile.ProfileDigest
    mode = $modeValue
    content_hash = $contentHash
    document_snapshot = $snapshotPath
    asset_manifest = $assetReport.manifest
    used_assets = @($assetReport.assets)
    output = [pscustomobject][ordered]@{
        path = $pdfRelative
        sha256 = $pdfHash
        bytes = $pdf.Length
    }
}
[System.IO.File]::WriteAllText(
    (Join-Path $root $buildReportPath),
    ($buildReport | ConvertTo-Json -Depth 12),
    (New-Object System.Text.UTF8Encoding($false))
)

Write-Host ("Ready: {0}" -f $pdf.FullName)
& pdfinfo -enc UTF-8 $pdfRelative | Select-String 'Pages|Page size'
Write-Host ("File size:       {0} bytes" -f $pdf.Length)
Write-Host ("Mode:            {0}" -f $Mode)
Write-Host ("Profile:         {0}" -f $profile.ProfileId)
Write-Host ("Profile digest:  {0}" -f $profile.ProfileDigest)
Write-Host ("Content hash:    {0}" -f $contentHash)
Write-Host ("Asset manifest:  {0}" -f $assetReport.manifest.sha256)
Write-Host 'Used assets:'
foreach ($asset in @($assetReport.assets)) {
    Write-Host ("  {0} [{1}]" -f $asset.id, $asset.generator)
    foreach ($source in @($asset.sources)) {
        Write-Host ("    source {0}: {1}" -f $source.path, $source.sha256)
    }
    Write-Host ("    output {0}: {1}" -f $asset.output.path, $asset.output.sha256)
}
Write-Host ("Build report:    {0}" -f $buildReportPath)
