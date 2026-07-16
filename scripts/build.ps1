[CmdletBinding()]
param(
    [ValidateSet('Draft', 'Strict')]
    [string]$Mode = 'Draft',
    [string]$ProfilePath = '',
    [string]$WorkspaceRoot = ''
)

$ErrorActionPreference = 'Stop'

$engineRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { $WorkspaceRoot = $engineRoot }
$WorkspaceRoot = [System.IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\', '/')

. (Join-Path $PSScriptRoot 'utf8-native.ps1')
. (Join-Path $PSScriptRoot 'profile.ps1')
. (Join-Path $PSScriptRoot 'workspace.ps1')

$workspace = Resolve-AutoNormoKontrolWorkspace `
    -EngineRoot $engineRoot -WorkspaceRoot $WorkspaceRoot
$profile = $workspace.Profile
if (-not [string]::IsNullOrWhiteSpace($ProfilePath)) {
    $normalizedProfilePath = $ProfilePath.Replace('\', '/')
    if ($workspace.Legacy) {
        # R2 migration diagnostic: the embedded legacy workspace may be probed
        # with another manifest. A real workspace remains pinned by project.yaml.
        $profile = Resolve-AutoNormoKontrolProfile -Root $engineRoot `
            -WorkspaceRoot $WorkspaceRoot -ProfilePath $normalizedProfilePath
    }
    elseif ($normalizedProfilePath -ne $workspace.ProfilePath) {
        throw ("Explicit profile '{0}' does not match workspace profile '{1}'." -f
            $ProfilePath, $workspace.ProfilePath)
    }
}
$config = $profile.Data
$content = @($workspace.ContentPaths)
if ($workspace.Legacy) { $content = @($config.inputs.content | ForEach-Object { [string]$_ }) }

if (-not $workspace.ProfileDigestMatches) {
    Write-Warning (("Workspace was created with profile digest {0}, current digest is {1}. " +
        'The build will use the current profile; review the resulting PDF.') -f
        $workspace.PinnedProfileDigest, $profile.ProfileDigest)
}
if (-not $workspace.EngineVersionMatches) {
    Write-Warning (("Workspace was created with AutoNormoKontrol {0}; current engine is {1}. " +
        'The build continues without automatic migration; review the result.') -f
        $workspace.CreatedWithEngineVersion, $workspace.EngineVersion)
}

Set-Location -LiteralPath $WorkspaceRoot

$metadataPath = [string]$config.inputs.metadata
$bibliographyPath = [string]$config.inputs.bibliography
$assetManifestPath = [string]$config.inputs.asset_manifest
$reviewInventoryPath = Resolve-ProfileProjectPath -Root $engineRoot `
    -Path ([string]$config.compliance.review_inventory) `
    -Location 'compliance.review_inventory' -Kind File
$semanticReviewPath = [string]$config.compliance.semantic_review
$externalAcceptancePath = [string]$config.compliance.external_acceptance
$assetReportPath = [string]$config.assets.report
$assetBuildPath = [string]$config.assets.output_directory
$snapshotPath = [string]$config.reports.document_snapshot
$buildReportPath = [string]$config.reports.build_report
$postflightReportPath = [string]$config.reports.postflight
$outputTexPath = [string]$config.outputs.tex
$outputPdfPath = [string]$config.outputs.pdf

& (Join-Path $PSScriptRoot 'check-coverage.ps1') `
    -ProfilePath $profile.ManifestPath `
    -WorkspaceRoot $WorkspaceRoot `
    -ContentPaths $content
if (-not $?) { exit 1 }

# STO-TRACEABILITY: every normal build refreshes the human- and
# machine-readable file:line ledger after the fail-closed coverage gate.
& (Join-Path $PSScriptRoot 'report-traceability.ps1') `
    -ProfilePath $profile.ManifestPath `
    -WorkspaceRoot $WorkspaceRoot `
    -ContentPaths $content
if (-not $?) { exit 1 }

& (Join-Path $PSScriptRoot 'lint-content.ps1') `
    -ProjectRoot $WorkspaceRoot -ContentPaths $content
if (-not $?) { exit 1 }

$build = Split-Path -Parent (Join-Path $WorkspaceRoot $outputPdfPath)
$assetBuild = Join-Path $WorkspaceRoot $assetBuildPath
$texCache = Join-Path $build 'texmf-var'
New-Item -ItemType Directory -Force -Path $assetBuild | Out-Null
New-Item -ItemType Directory -Force -Path $texCache | Out-Null

# R1.1: build only manifest-declared assets through the fixed generator
# whitelist. fixtures/ remain test data and never participate in this path.
& (Join-Path $PSScriptRoot 'build-assets.ps1') `
    -ProjectRoot $WorkspaceRoot `
    -ManifestPath $assetManifestPath `
    -ReportPath $assetReportPath
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# STO-AI-GATE, R1.1: bind semantic review to the complete verifiable document
# snapshot: Markdown, metadata, bibliography, the document-local format spec,
# asset manifest, source data, TeX plot source and generated PDF. Any one of
# them invalidates stale review and prevents exporting an obsolete build.
$snapshotInputs = @($content) + @(
    $metadataPath,
    $bibliographyPath,
    [string]$config.compliance.format_spec
)
if (-not $workspace.Legacy) {
    # R1/workspace: project.yaml owns chapter order. Reordering or adding a
    # chapter must invalidate both semantic review and a pending export.
    $snapshotInputs += $script:AutoNormoKontrolWorkspaceManifest
}
& (Join-Path $PSScriptRoot 'write-document-snapshot.ps1') `
    -ProjectRoot $WorkspaceRoot `
    -ProfileId $profile.ProfileId `
    -AssetReportPath $assetReportPath `
    -OutputPath $snapshotPath `
    -ContentPaths $snapshotInputs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$snapshotFull = Join-Path $WorkspaceRoot $snapshotPath
$assetReportFull = Join-Path $WorkspaceRoot $assetReportPath
$snapshot = Get-Content -Raw -Encoding UTF8 -LiteralPath $snapshotFull | ConvertFrom-Json
$assetReport = Get-Content -Raw -Encoding UTF8 -LiteralPath $assetReportFull | ConvertFrom-Json
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
        $baseRoot = if ([string]$_ -eq '.') { $WorkspaceRoot } else { $engineRoot }
        Resolve-ProfileProjectPath -Root $baseRoot -Path ([string]$_) `
            -Location 'render.tex_input_paths' -Kind Directory
    })
    $env:TEXINPUTS = ($texInputs -join ';') + ';'

    $templatePath = Resolve-ProfileProjectPath -Root $engineRoot `
        -Path ([string]$config.render.template) -Location 'render.template' -Kind File
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
        "--template=$templatePath"
    )
    foreach ($filter in @($config.render.lua_filters)) {
        $filterPath = Resolve-ProfileProjectPath -Root $engineRoot -Path ([string]$filter) `
            -Location 'render.lua_filters' -Kind File
        $pandocArguments += "--lua-filter=$filterPath"
    }
    $pandocArguments += @(
        '--biblatex',
        "--resource-path=$WorkspaceRoot;$build",
        "--output=$outputTexPath"
    )
    $pandocPath = Resolve-PandocExecutable
    $pandocResult = Invoke-Utf8NativeCommand `
        -FilePath $pandocPath `
        -Arguments $pandocArguments `
        -WorkingDirectory $WorkspaceRoot
    Write-NativeCommandResult $pandocResult
    if ($pandocResult.ExitCode -ne 0) { exit $pandocResult.ExitCode }

    $texOutputDirectory = Split-Path -Parent (Join-Path $WorkspaceRoot $outputTexPath)
    & latexmk -lualatex -interaction=nonstopmode -halt-on-error -file-line-error `
        "-outdir=$texOutputDirectory" $outputTexPath
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $postflightScript = Resolve-ProfileProjectPath -Root $engineRoot `
        -Path ([string]$config.render.postflight) -Location 'render.postflight' -Kind File
    & $postflightScript `
        -ProjectRoot $WorkspaceRoot -PdfPath $outputPdfPath -TexPath $outputTexPath `
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
$pdfRelative = $outputPdfPath.Replace('\', '/')
$pdfFull = Join-Path $WorkspaceRoot $pdfRelative
$pdf = Get-Item -LiteralPath $pdfFull
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
    document_snapshot = $snapshotPath.Replace('\', '/')
    asset_manifest = $assetReport.manifest
    used_assets = @($assetReport.assets)
    output = [pscustomobject][ordered]@{
        path = $pdfRelative
        sha256 = $pdfHash
        bytes = $pdf.Length
    }
}
$buildReportFull = Join-Path $WorkspaceRoot $buildReportPath
[System.IO.File]::WriteAllText(
    $buildReportFull,
    ($buildReport | ConvertTo-Json -Depth 12),
    (New-Object System.Text.UTF8Encoding($false))
)

Write-Host ("Ready: {0}" -f $pdf.FullName)
& pdfinfo -enc UTF-8 $pdf.FullName | Select-String 'Pages|Page size'
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
Write-Host ("Build report:    {0}" -f $buildReportFull)
