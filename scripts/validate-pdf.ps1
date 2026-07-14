param(
    [Parameter(Mandatory = $true)]
    [string]$PdfPath,
    [Parameter(Mandatory = $true)]
    [string]$TexPath
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$pdf = (Resolve-Path -LiteralPath (Join-Path $root $PdfPath)).Path
$tex = (Resolve-Path -LiteralPath (Join-Path $root $TexPath)).Path
$log = [System.IO.Path]::ChangeExtension($tex, '.log')
$build = Split-Path -Parent $pdf
$bbox = Join-Path $env:TEMP ("susu-coursework-bbox-{0}.html" -f $PID)
$plain = Join-Path $env:TEMP ("susu-coursework-text-{0}.txt" -f $PID)
$failures = New-Object System.Collections.Generic.List[string]

function Add-Failure([string]$Clause, [string]$Message) {
    $failures.Add(("{0}: {1}" -f $Clause, $Message))
}

# STO-8.1.2: every physical page is A4 and unrotated.
$info = (& pdfinfo -f 1 -l 999 -box $pdf 2>&1) -join "`n"
$pageCountMatch = [regex]::Match($info, '(?m)^Pages:\s+(\d+)')
if (-not $pageCountMatch.Success) {
    Add-Failure 'STO-8.1.2' 'pdfinfo did not report a page count'
    $pageCount = 0
}
else {
    $pageCount = [int]$pageCountMatch.Groups[1].Value
}
$sizes = [regex]::Matches($info, '(?m)^Page\s+\d+ size:\s+([0-9.]+) x ([0-9.]+) pts')
if ($sizes.Count -ne $pageCount) {
    Add-Failure 'STO-8.1.2' 'not every page has an individually reported size'
}
foreach ($size in $sizes) {
    $width = [double]::Parse($size.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
    $height = [double]::Parse($size.Groups[2].Value, [Globalization.CultureInfo]::InvariantCulture)
    if ([math]::Abs($width - 595.276) -gt 0.6 -or [math]::Abs($height - 841.890) -gt 0.6) {
        Add-Failure 'STO-8.1.2' ("non-A4 page: {0} x {1} pt" -f $width, $height)
    }
}
foreach ($rotation in [regex]::Matches($info, '(?m)^Page\s+\d+ rot:\s+(\d+)')) {
    if ([int]$rotation.Groups[1].Value -ne 0) {
        Add-Failure 'STO-8.1.2' 'a PDF page is rotated'
    }
}

# STO-8.1.3: the main Times New Roman face must be embedded.  Mathematical
# and monospaced semantic spans may use their dedicated embedded fonts.
$fontLines = @(& pdffonts $pdf 2>&1)
if (-not (($fontLines -join "`n") -match 'TimesNewRoman')) {
    Add-Failure 'STO-8.1.3' 'Times New Roman is not present in the PDF'
}
foreach ($fontLine in ($fontLines | Select-Object -Skip 2)) {
    if ($fontLine -match '^\S+' -and $fontLine -notmatch '\s+yes\s+(yes|no)\s+(yes|no)\s+\d+\s+\d+\s*$') {
        Add-Failure 'STO-8.1.3' ("font is not embedded: {0}" -f $fontLine.Trim())
    }
}

# STO-8.1.4, STO-8.3.1, STO-8.3.2, STO-8.3.3, STO-7.12.7: inspect word
# coordinates, margins, hidden front-matter numbers, physical-page-centred
# footers and uninterrupted numbering through every appendix page.
& pdftotext -bbox-layout $pdf $bbox
if ($LASTEXITCODE -ne 0) { Add-Failure 'STO-8.1.4' 'pdftotext bbox extraction failed' }
[xml]$bboxXml = [System.IO.File]::ReadAllText($bbox, [Text.Encoding]::UTF8)
$namespace = New-Object System.Xml.XmlNamespaceManager($bboxXml.NameTable)
$namespace.AddNamespace('x', 'http://www.w3.org/1999/xhtml')
$pages = @($bboxXml.SelectNodes('//x:page', $namespace))
$firstNumberedPage = $null
$allWordRecords = New-Object System.Collections.Generic.List[object]
for ($pageIndex = 0; $pageIndex -lt $pages.Count; $pageIndex++) {
    $words = @($pages[$pageIndex].SelectNodes('.//x:word', $namespace))
    for ($wordIndex = 0; $wordIndex -lt $words.Count; $wordIndex++) {
        $word = $words[$wordIndex]
        $xMin = [double]::Parse($word.xMin, [Globalization.CultureInfo]::InvariantCulture)
        $xMax = [double]::Parse($word.xMax, [Globalization.CultureInfo]::InvariantCulture)
        $yMin = [double]::Parse($word.yMin, [Globalization.CultureInfo]::InvariantCulture)
        $yMax = [double]::Parse($word.yMax, [Globalization.CultureInfo]::InvariantCulture)
        $allWordRecords.Add([pscustomobject]@{
            Page = $pageIndex + 1
            Index = $wordIndex
            Text = $word.InnerText
            XMin = $xMin
            XMax = $xMax
            YMin = $yMin
            YMax = $yMax
        })
        # Footer/header fields are checked separately. Ordinary content must
        # stay inside the 25 mm left and 10 mm right text limits.
        if ($yMin -ge 55 -and $yMin -lt 760 -and ($xMin -lt 69.8 -or $xMax -gt 568.0)) {
            Add-Failure 'STO-8.1.4' ("page {0}: text crosses a horizontal margin: {1}" -f ($pageIndex + 1), $word.InnerText)
        }
        if ($yMin -lt 55.0 -or ($yMax -gt 769.5 -and $yMin -lt 770.0)) {
            Add-Failure 'STO-8.1.4' ("page {0}: text crosses a vertical margin: {1}" -f ($pageIndex + 1), $word.InnerText)
        }
    }
    $footerWords = @($words | Where-Object {
        $_.InnerText -match '^\d{1,3}$' -and
        [double]::Parse($_.yMin, [Globalization.CultureInfo]::InvariantCulture) -ge 770 -and
        [double]::Parse($_.yMin, [Globalization.CultureInfo]::InvariantCulture) -le 792
    })
    if ($footerWords.Count -gt 1) {
        Add-Failure 'STO-8.3.3' ("page {0}: ambiguous footer number" -f ($pageIndex + 1))
    }
    elseif ($footerWords.Count -eq 1) {
        if ($null -eq $firstNumberedPage) { $firstNumberedPage = $pageIndex + 1 }
        $footer = $footerWords[0]
        $centre = ([double]::Parse($footer.xMin, [Globalization.CultureInfo]::InvariantCulture) +
                   [double]::Parse($footer.xMax, [Globalization.CultureInfo]::InvariantCulture)) / 2.0
        if ([math]::Abs($centre - 297.638) -gt 3.0) {
            Add-Failure 'STO-8.3.3' ("page {0}: footer is not at physical page centre (x={1:N2})" -f ($pageIndex + 1), $centre)
        }
        $footerY = [double]::Parse($footer.yMin, [Globalization.CultureInfo]::InvariantCulture)
        if ([math]::Abs($footerY - 775.24) -gt 3.0) {
            Add-Failure 'STO-8.1.4' ("page {0}: footer is not 20 mm from the lower edge" -f ($pageIndex + 1))
        }
        if ([int]$footer.InnerText -ne ($pageIndex + 1)) {
            Add-Failure 'STO-8.3.1' ("PDF page {0} prints number {1}" -f ($pageIndex + 1), $footer.InnerText)
        }
    }
    elseif ($null -ne $firstNumberedPage) {
        Add-Failure 'STO-8.3.1' ("page {0}: page number disappeared after numbering began" -f ($pageIndex + 1))
    }
}
if ($null -eq $firstNumberedPage -or $firstNumberedPage -le 1) {
    Add-Failure 'STO-8.3.2' 'front matter page numbers were not hidden or main numbering was not found'
}

# STO-6, STO-7.3.1, STO-7.4.1, STO-7.4.2, STO-7.11.2, STO-7.11.3,
# STO-7.12.5: postflight checks the mandatory visible sequence and selected
# numbering forms.
& pdftotext -layout -enc UTF-8 $pdf $plain
if ($LASTEXITCODE -ne 0) { Add-Failure 'STO-6' 'plain-text PDF extraction failed' }
$pdfText = [System.IO.File]::ReadAllText($plain, [Text.Encoding]::UTF8)
$texText = [System.IO.File]::ReadAllText($tex, [Text.Encoding]::UTF8)
$requiredSequence = @(
    @{ Clause = 'STO-7.1.1'; Text = 'ПОЯСНИТЕЛЬНАЯ ЗАПИСКА К КУРСОВОЙ РАБОТЕ' },
    @{ Clause = 'STO-7.2.1'; Text = 'ЗАДАНИЕ' },
    @{ Clause = 'STO-7.3.1'; Text = 'АННОТАЦИЯ' },
    @{ Clause = 'STO-7.4.1'; Text = 'ОГЛАВЛЕНИЕ' },
    @{ Clause = 'STO-6'; Text = 'ВВЕДЕНИЕ' },
    @{ Clause = 'STO-6'; Text = 'ЗАКЛЮЧЕНИЕ' },
    @{ Clause = 'STO-7.11.2'; Text = 'БИБЛИОГРАФИЧЕСКИЙ СПИСОК' },
    @{ Clause = 'STO-7.12.5'; Text = 'ПРИЛОЖЕНИЕ А' }
)
$lastPosition = -1
foreach ($required in $requiredSequence) {
    $position = $pdfText.IndexOf($required.Text, [StringComparison]::Ordinal)
    if ($position -lt 0) {
        Add-Failure $required.Clause ("missing visible element: {0}" -f $required.Text)
    }
    elseif ($position -lt $lastPosition) {
        Add-Failure $required.Clause ("visible element is out of order: {0}" -f $required.Text)
    }
    else {
        $lastPosition = $position
    }
}
# STO-8.5.10: the integration fixture has exactly one main figure, so its
# generated caption must use the global number 1 rather than a section number.
if ($texText -match '\\SUSUSingleFigureNumbering' -and
    $pdfText -notmatch 'Рисунок\s+1\s+[–-]') {
    Add-Failure 'STO-8.5.10' 'one main figure was not printed as Figure 1'
}
if ($texText -match '\\SUSUSingleTableNumbering' -and
    $pdfText -notmatch 'Таблица\s+1\s+[–-]') {
    Add-Failure 'STO-8.6.3' 'one main table was not printed as Table 1'
}
if ($texText -match '\\SUSUSingleEquationNumbering' -and
    $pdfText -notmatch 'формуле\s+\(1\)') {
    Add-Failure 'STO-8.7.5' 'one main formula was not referenced as (1)'
}

# STO-8.6.3: every generated table caption starts at the left text boundary.
foreach ($captionWord in ($allWordRecords | Where-Object { $_.Text -eq 'Таблица' })) {
    if ([math]::Abs($captionWord.XMin - 70.866) -gt 3.0) {
        Add-Failure 'STO-8.6.3' ("page {0}: table caption is not left aligned" -f $captionWord.Page)
    }
}

# STO-8.7.7: a generated structured explanation emits the word 'where'; it
# must start exactly at the left text boundary.
if ($texText -match '\\begin\{SUSUWhere\}') {
    $whereFound = $false
    foreach ($record in ($allWordRecords | Where-Object { $_.Text -eq 'где' })) {
        if ([math]::Abs($record.XMin - 70.866) -le 3.0) {
            $whereFound = $true
        }
    }
    if (-not $whereFound) { Add-Failure 'STO-8.7.7' 'structured where block was not found in PDF text' }
}

# STO-8.1.1: warnings indicating unstable layout or unresolved references are
# release failures, even if the TeX engine returned exit code zero.
if (Test-Path -LiteralPath $log) {
    $logText = [System.IO.File]::ReadAllText($log, [Text.Encoding]::UTF8)
    $fatalWarningPatterns = @(
        'LaTeX Warning:.*undefined',
        'There were undefined references',
        'Citation .* undefined',
        'Overfull \\[hv]box',
        'Missing character:',
        'LaTeX Font Warning:'
    )
    foreach ($pattern in $fatalWarningPatterns) {
        if ($logText -match $pattern) {
            Add-Failure 'STO-8.1.1' ("TeX log contains: {0}" -f $pattern)
        }
    }
}
else {
    Add-Failure 'STO-8.1.1' 'TeX log is missing'
}

$report = [ordered]@{
    generated_at = (Get-Date).ToString('o')
    pdf = $pdf
    pages = $pageCount
    first_numbered_page = $firstNumberedPage
    status = if ($failures.Count -eq 0) { 'pass' } else { 'fail' }
    failures = @($failures)
}
$reportPath = Join-Path $build 'compliance-report.json'
[System.IO.File]::WriteAllText(
    $reportPath,
    ($report | ConvertTo-Json -Depth 5),
    (New-Object System.Text.UTF8Encoding($false))
)

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Host ("ERROR {0}" -f $failure) -ForegroundColor Red }
    exit 1
}

Write-Host ("PDF postflight passed: {0} pages; numbering starts on PDF page {1}." -f $pageCount, $firstNumberedPage)
