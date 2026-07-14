param(
    [ValidateSet('Draft', 'Strict')]
    [string]$Mode = 'Draft'
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root

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

# STO-AI-GATE: bind a semantic review to the exact Markdown and metadata that
# affect document meaning.  A changed source cannot reuse a stale approval.
$hashFiles = @($content) + @('metadata.yaml', 'bibliography.bib')
$hashText = foreach ($relative in $hashFiles) {
    $absolute = Join-Path $root $relative
    $relative
    [System.IO.File]::ReadAllText($absolute, [System.Text.Encoding]::UTF8)
}
$hashBytes = [System.Text.Encoding]::UTF8.GetBytes(($hashText -join "`n"))
$sha256 = [System.Security.Cryptography.SHA256]::Create()
try {
    $contentHash = ([System.BitConverter]::ToString($sha256.ComputeHash($hashBytes))).Replace('-', '').ToLowerInvariant()
}
finally {
    $sha256.Dispose()
}
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

    & latexmk -lualatex -interaction=nonstopmode -halt-on-error -file-line-error `
        "-outdir=$assetBuild" 'fixtures/architecture.tex'
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    & pandoc @content `
        --from='markdown+smart+fenced_divs+tex_math_dollars+table_captions-raw_tex-raw_html-raw_attribute' `
        --to=latex `
        --standalone `
        --number-sections `
        --top-level-division=section `
        --metadata-file='metadata.yaml' `
        --metadata-file='compliance/semantic-review.yaml' `
        --metadata-file='compliance/external-acceptance.yaml' `
        "--metadata=compliance-mode:$modeValue" `
        "--metadata=content-hash:$contentHash" `
        --template='templates/susu-coursework.tex' `
        --lua-filter='filters/sto-validate.lua' `
        --lua-filter='filters/susu.lua' `
        --biblatex `
        --resource-path="$root;$build" `
        --output='build/coursework.tex'
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

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
Write-Host ("Ready: {0}" -f $pdf.FullName)
& pdfinfo -enc UTF-8 $pdfRelative | Select-String 'Pages|Page size'
Write-Host ("File size:       {0} bytes" -f $pdf.Length)
Write-Host ("Mode:            {0}" -f $Mode)
Write-Host ("Content hash:    {0}" -f $contentHash)
