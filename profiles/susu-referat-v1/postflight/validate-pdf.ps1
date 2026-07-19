[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$PdfPath,
    [Parameter(Mandatory = $true)][string]$TexPath,
    [Parameter(Mandatory = $true)][string]$ReportPath,
    [string]$ContractPath = ''
)

$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath($ProjectRoot)
$failures = New-Object System.Collections.Generic.List[string]

function Resolve-WorkspaceFile([string]$RelativePath) {
    $candidate = if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        [System.IO.Path]::GetFullPath($RelativePath)
    }
    else {
        [System.IO.Path]::GetFullPath((Join-Path $root $RelativePath))
    }
    $prefix = $root.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Postflight path leaves the workspace: $RelativePath"
    }
    return $candidate
}

function Add-Failure([string]$Code, [string]$Message) {
    $failures.Add("$Code`: $Message")
}

$pdf = Resolve-WorkspaceFile $PdfPath
$tex = Resolve-WorkspaceFile $TexPath
$reportFull = Resolve-WorkspaceFile $ReportPath
$contractFull = Resolve-WorkspaceFile $ContractPath
if (-not (Test-Path -LiteralPath $pdf -PathType Leaf)) { throw "PDF not found: $PdfPath" }
if (-not (Test-Path -LiteralPath $tex -PathType Leaf)) { throw "TeX not found: $TexPath" }
$contract = [System.IO.File]::ReadAllText($contractFull, [Text.Encoding]::UTF8) | ConvertFrom-Json

# STO17-4.3.1.1: every page is A4.
$info = (& pdfinfo -f 1 -l 999 -box $pdf 2>&1) -join "`n"
$pageMatch = [regex]::Match($info, '(?m)^Pages:\s+(\d+)')
$pageCount = if ($pageMatch.Success) { [int]$pageMatch.Groups[1].Value } else { 0 }
if ($pageCount -le 0) { Add-Failure 'STO17-4.3.1.1' 'pdfinfo did not report pages' }
$sizes = [regex]::Matches($info, '(?m)^Page\s+\d+ size:\s+([0-9.]+) x ([0-9.]+) pts')
if ($sizes.Count -ne $pageCount) { Add-Failure 'STO17-4.3.1.1' 'not every page reports its size' }
foreach ($size in $sizes) {
    $w = [double]::Parse($size.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
    $h = [double]::Parse($size.Groups[2].Value, [Globalization.CultureInfo]::InvariantCulture)
    if ([math]::Abs($w - 595.276) -gt 0.6 -or [math]::Abs($h - 841.890) -gt 0.6) {
        Add-Failure 'STO17-4.3.1.1' ("non-A4 page: {0} x {1} pt" -f $w, $h)
    }
}

# STO17-4.3.1.2: the selected base font must be present and embedded.
$fontText = (@(& pdffonts $pdf 2>&1) -join "`n")
if ($fontText -notmatch 'TimesNewRoman') {
    Add-Failure 'STO17-4.3.1.2' 'Times New Roman is not present in PDF'
}

$plain = Join-Path $env:TEMP ("ank-referat-text-{0}.txt" -f $PID)
try {
    & pdftotext -layout -enc UTF-8 $pdf $plain
    if ($LASTEXITCODE -ne 0) { Add-Failure 'STO17-4.2.1' 'PDF text extraction failed' }
    $pdfText = if (Test-Path -LiteralPath $plain) {
        [System.IO.File]::ReadAllText($plain, [Text.Encoding]::UTF8)
    } else { '' }
    $positions = @{}
    foreach ($element in @($contract.structure.visible_elements)) {
        $position = $pdfText.IndexOf([string]$element.text, [StringComparison]::Ordinal)
        if ($position -lt 0 -and [bool]$element.required) {
            Add-Failure ([string]$element.diagnostic) ("not found: {0}" -f $element.text)
        }
        elseif ($position -ge 0) { $positions[[string]$element.element] = $position }
    }
    foreach ($edge in @($contract.structure.order)) {
        $first = [string]$edge.first
        $then = [string]$edge.then
        if ($positions.ContainsKey($first) -and $positions.ContainsKey($then) -and
            $positions[$first] -gt $positions[$then]) {
            Add-Failure ([string]$edge.diagnostic) ("$first must precede $then")
        }
    }
}
finally {
    if (Test-Path -LiteralPath $plain) { Remove-Item -LiteralPath $plain -Force }
}

$log = [System.IO.Path]::ChangeExtension($tex, '.log')
if (-not (Test-Path -LiteralPath $log -PathType Leaf)) {
    Add-Failure 'STO17-4.3.1.2' 'TeX log is missing'
}
else {
    $logText = [System.IO.File]::ReadAllText($log, [Text.Encoding]::UTF8)
    foreach ($pattern in @(
        'LaTeX Warning:.*undefined', 'There were undefined references',
        'Citation .* undefined', 'Overfull \\[hv]box', 'Missing character:',
        'LaTeX Font Warning:'
    )) {
        if ($logText -match $pattern) {
            Add-Failure 'STO17-4.3.1.2' ("TeX log contains: {0}" -f $pattern)
        }
    }
}

$report = [ordered]@{
    version = 1
    profile_id = 'susu-referat-v1'
    status = if ($failures.Count -eq 0) { 'pass' } else { 'fail' }
    pages = $pageCount
    failures = @($failures)
    pdf = [ordered]@{
        path = $PdfPath.Replace('\', '/')
        sha256 = (Get-FileHash -LiteralPath $pdf -Algorithm SHA256).Hash.ToLowerInvariant()
        bytes = (Get-Item -LiteralPath $pdf).Length
    }
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $reportFull) | Out-Null
[System.IO.File]::WriteAllText(
    $reportFull, (($report | ConvertTo-Json -Depth 8) + "`n"),
    (New-Object System.Text.UTF8Encoding($false))
)
if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Host "ERROR $failure" -ForegroundColor Red }
    exit 1
}
Write-Host ("Referat PDF postflight passed: {0} pages." -f $pageCount)
