param(
    [ValidateSet('Draft', 'Strict')]
    [string]$Mode = 'Draft'
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root
. (Join-Path $PSScriptRoot 'utf8-native.ps1')

& (Join-Path $PSScriptRoot 'check-coverage.ps1')
if (-not $?) { exit 1 }

# STO-TRACEABILITY: every normal build refreshes the human- and
# machine-readable file:line ledger after the fail-closed coverage gate.
& (Join-Path $PSScriptRoot 'report-traceability.ps1')
if (-not $?) { exit 1 }

& (Join-Path $PSScriptRoot 'lint-content.ps1')
if (-not $?) { exit 1 }

$build = Join-Path $root 'build'
$assetBuild = Join-Path $build 'assets'
$texCache = Join-Path $build 'texmf-var'
New-Item -ItemType Directory -Force -Path $assetBuild | Out-Null
New-Item -ItemType Directory -Force -Path $texCache | Out-Null

$content = @(
    'content/00-introduction.md',
    'content/01-literature-review.md',
    'content/02-main.md',
    'content/03-conclusion.md',
    'content/90-bibliography.md',
    'content/99-appendix.md'
)

# R1.1: build only manifest-declared assets through the fixed generator
# whitelist. fixtures/ remain test data and never participate in this path.
& (Join-Path $PSScriptRoot 'build-assets.ps1') `
    -ManifestPath 'assets/manifest.json' `
    -ReportPath 'build/asset-report.json'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# STO-AI-GATE, R1.1: bind semantic review to the complete verifiable document
# snapshot: Markdown, metadata, bibliography, asset manifest, source data,
# TeX plot source and generated PDF. Any one of them invalidates stale review.
& (Join-Path $PSScriptRoot 'write-document-snapshot.ps1') `
    -AssetReportPath 'build/asset-report.json' `
    -OutputPath 'build/document-snapshot.json' `
    -ContentPaths (@($content) + @('metadata.yaml', 'bibliography.bib'))
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$snapshot = Get-Content -Raw -Encoding UTF8 -LiteralPath 'build/document-snapshot.json' | ConvertFrom-Json
$assetReport = Get-Content -Raw -Encoding UTF8 -LiteralPath 'build/asset-report.json' | ConvertFrom-Json
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
    $env:TEXINPUTS = "$root;$root\styles;"

    $pandocArguments = @($content) + @(
        '--from=markdown+smart+fenced_divs+tex_math_dollars+table_captions-raw_tex-raw_html-raw_attribute',
        '--to=latex',
        '--standalone',
        '--number-sections',
        '--top-level-division=section',
        '--metadata-file=metadata.yaml',
        '--metadata-file=compliance/semantic-review.yaml',
        '--metadata-file=compliance/external-acceptance.yaml',
        "--metadata=compliance-mode:$modeValue",
        "--metadata=content-hash:$contentHash",
        '--template=templates/susu-coursework.tex',
        '--lua-filter=filters/sto-validate.lua',
        '--lua-filter=filters/susu.lua',
        '--biblatex',
        "--resource-path=$root;$build",
        '--output=build/coursework.tex'
    )
    $pandocPath = Resolve-PandocExecutable
    $pandocResult = Invoke-Utf8NativeCommand `
        -FilePath $pandocPath `
        -Arguments $pandocArguments `
        -WorkingDirectory $root
    Write-NativeCommandResult $pandocResult
    if ($pandocResult.ExitCode -ne 0) { exit $pandocResult.ExitCode }

    & latexmk -lualatex -interaction=nonstopmode -halt-on-error -file-line-error `
        "-outdir=$build" 'build/coursework.tex'
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    & (Join-Path $PSScriptRoot 'validate-pdf.ps1') -PdfPath 'build/coursework.pdf' -TexPath 'build/coursework.tex'
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
$pdfRelative = 'build/coursework.pdf'
$pdf = Get-Item -LiteralPath $pdfRelative
$pdfHash = (Get-FileHash -LiteralPath $pdf.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
$buildReport = [pscustomobject][ordered]@{
    version = 1
    profile_id = 'susu-hsem-ceit-coursework-v1'
    mode = $modeValue
    content_hash = $contentHash
    document_snapshot = 'build/document-snapshot.json'
    asset_manifest = $assetReport.manifest
    used_assets = @($assetReport.assets)
    output = [pscustomobject][ordered]@{
        path = $pdfRelative
        sha256 = $pdfHash
        bytes = $pdf.Length
    }
}
[System.IO.File]::WriteAllText(
    (Join-Path $root 'build/build-report.json'),
    ($buildReport | ConvertTo-Json -Depth 12),
    (New-Object System.Text.UTF8Encoding($false))
)

Write-Host ("Ready: {0}" -f $pdf.FullName)
& pdfinfo -enc UTF-8 $pdfRelative | Select-String 'Pages|Page size'
Write-Host ("File size:       {0} bytes" -f $pdf.Length)
Write-Host ("Mode:            {0}" -f $Mode)
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
Write-Host 'Build report:    build/build-report.json'
