[CmdletBinding()]
param(
    [switch]$SkipCoverage
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root
. (Join-Path $PSScriptRoot 'utf8-native.ps1')

if (-not $SkipCoverage) {
    & (Join-Path $PSScriptRoot 'check-coverage.ps1')
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

$pandocPath = try { Resolve-PandocExecutable } catch { $null }
if ($null -eq $pandocPath) {
    Write-Error 'pandoc was not found in PATH or a standard Windows installation directory.'
    exit 1
}
$pandoc = [pscustomobject]@{ Source = $pandocPath }

$basePath = Join-Path $root 'tests/valid/minimal.md'
$invalidDirectory = Join-Path $root 'tests/invalid'
$validatorPath = Join-Path $root 'filters/sto-validate.lua'
$testBuild = Join-Path $root 'build/compliance-tests'
New-Item -ItemType Directory -Force -Path $testBuild | Out-Null

if (-not (Test-Path -LiteralPath $basePath -PathType Leaf)) {
    Write-Error "Positive fixture not found: $basePath"
    exit 1
}

function Invoke-Validator {
    param(
        [string]$InputPath,
        [string]$OutputPath,
        [string[]]$ExtraArguments = @()
    )

    $arguments = @(
        $InputPath,
        '--from=markdown+smart+fenced_divs+tex_math_dollars+table_captions+raw_tex+raw_html+raw_attribute',
        '--to=native',
        "--lua-filter=$validatorPath",
        "--output=$OutputPath"
    )
    $arguments += $ExtraArguments
    $result = Invoke-Utf8NativeCommand `
        -FilePath $pandoc.Source `
        -Arguments $arguments `
        -WorkingDirectory $root
    return [pscustomobject]@{
        ExitCode = $result.ExitCode
        Text = $result.StandardOutput + $result.StandardError
    }
}

function Invoke-Renderer {
    param(
        [string]$InputPath,
        [string]$OutputPath
    )

    $rendererPath = Join-Path $root 'filters/susu.lua'
    $arguments = @(
        $InputPath,
        '--from=markdown+smart+fenced_divs+tex_math_dollars+table_captions+raw_tex+raw_html+raw_attribute',
        '--to=latex',
        "--lua-filter=$validatorPath",
        "--lua-filter=$rendererPath",
        "--output=$OutputPath"
    )
    $result = Invoke-Utf8NativeCommand `
        -FilePath $pandoc.Source `
        -Arguments $arguments `
        -WorkingDirectory $root
    return [pscustomobject]@{
        ExitCode = $result.ExitCode
        Text = $result.StandardOutput + $result.StandardError
    }
}

function Invoke-CoverageGate {
    param([string]$RegistryPath)

    $coveragePath = Join-Path $root 'scripts/check-coverage.ps1'
    $arguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $coveragePath, '-RegistryPath', $RegistryPath
    )
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $messages = @(& powershell.exe @arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Text = ($messages | Out-String)
    }
}

$failures = New-Object System.Collections.Generic.List[string]

function Get-SourceText {
    param([string]$RelativePath)
    $path = Join-Path $root $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $failures.Add("static assertion source is missing: $RelativePath")
        return ''
    }
    return [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
}

function Assert-ContainsLiteral {
    param(
        [string]$Clause,
        [string]$RelativePath,
        [string[]]$Literals
    )
    $source = Get-SourceText $RelativePath
    foreach ($literal in $Literals) {
        if (-not $source.Contains($literal)) {
            $failures.Add("$Clause static assertion failed in ${RelativePath}: missing $literal")
        }
    }
}

function Assert-NotContainsLiteral {
    param(
        [string]$Clause,
        [string]$RelativePath,
        [string[]]$Literals
    )
    $source = Get-SourceText $RelativePath
    foreach ($literal in $Literals) {
        if ($source.Contains($literal)) {
            $failures.Add("$Clause static assertion failed in ${RelativePath}: forbidden $literal")
        }
    }
}

function Assert-OrderedLiterals {
    param(
        [string]$Clause,
        [string]$RelativePath,
        [string[]]$Literals
    )
    $source = Get-SourceText $RelativePath
    $offset = 0
    foreach ($literal in $Literals) {
        $position = $source.IndexOf($literal, $offset, [StringComparison]::Ordinal)
        if ($position -lt 0) {
            $failures.Add("$Clause order assertion failed in ${RelativePath}: missing/out-of-order $literal")
            return
        }
        $offset = $position + $literal.Length
    }
}

# Static regression tests execute against the trusted implementation sources.
# They verify structure and exact centralised commands, not marker presence.

# STO-7.1.3, STO-A1: Appendix A1 title form fields and their order.
Assert-OrderedLiterals 'STO-A1' 'templates/susu-coursework.tex' @(
    '$parent-organization$', '$university$', '$faculty-label$', '$school$',
    '$department$', '$title$', '$discipline$', '$document-code$',
    '$normal-controller.name$', '$supervisor.name$', '$student.group$',
    '$student.name$', '$city$', '$year$'
)

# STO-V: selected two-page coursework assignment form and signatures.
Assert-OrderedLiterals 'STO-V' 'templates/susu-coursework.tex' @(
    '$if(include-assignment)$', '$assignment.head-of-department$',
    '$assignment.approval-date$', '$assignment.student-full-name$',
    '$discipline$', '$title$', '$assignment.due-date$',
    '$for(assignment.questions)$', '\clearpage', '$for(assignment.calendar)$',
    '$supervisor.name$', '$student.name$', '$if(abstract)$'
)

# STO-7.3.1: assignment, annotation and contents have a fixed order.
Assert-OrderedLiterals 'STO-7.3.1' 'templates/susu-coursework.tex' @(
    '$if(include-assignment)$', '$if(abstract)$', '$abstract$', '\tableofcontents'
)

# STO-7.11.2, STO-7.11.4: one biblatex end-list backend, citation order,
# no hidden nocite-all path that could print an unreferenced source.
Assert-ContainsLiteral 'STO-7.11.2' 'filters/susu.lua' @('\printbibliography')
Assert-ContainsLiteral 'STO-7.11.4' 'templates/susu-coursework.tex' @(
    'backend=biber', 'style=gost-numeric', 'sorting=none'
)
Assert-ContainsLiteral 'STO-7.11.4' 'scripts/build.ps1' @('--biblatex')
Assert-NotContainsLiteral 'STO-7.11.4' 'templates/susu-coursework.tex' @('\nocite{*}')

# STO-7.12.7, STO-7.12.8: page counter stays global while the structural
# hierarchy and object counters become appendix-local.
Assert-ContainsLiteral 'STO-7.12.8' 'styles/susu-coursework.sty' @(
    '\renewcommand{\thesection}{#1.\arabic{section}}',
    '\renewcommand{\thesubsection}{\thesection.\arabic{subsection}}'
)
Assert-NotContainsLiteral 'STO-7.12.7' 'styles/susu-coursework.sty' @(
    '\setcounter{page}{0}', '\setcounter{page}{1}'
)

# STO-8.2.3, STO-8.2.6, STO-8.2.7, STO-8.2.9, STO-8.2.11: automatic
# hierarchy, heading layout, keep-with-next space and permitted list marker.
Assert-ContainsLiteral 'STO-8.2.3' 'styles/susu-coursework.sty' @(
    '\setcounter{secnumdepth}{4}', '\setcounter{tocdepth}{4}'
)
Assert-ContainsLiteral 'STO-8.2.6' 'styles/susu-coursework.sty' @(
    '\titleformat{\section}[block]', '{\thesection}{0.6em}{\MakeUppercase}'
)
Assert-ContainsLiteral 'STO-8.2.7' 'styles/susu-coursework.sty' @(
    '\titlespacing*{\subsection}{\parindent}',
    '\titlespacing*{\subsubsection}{\parindent}'
)
Assert-ContainsLiteral 'STO-8.2.9' 'styles/susu-coursework.sty' @(
    '\pretocmd{\section}{\Needspace{10\baselineskip}}',
    '\pretocmd{\subsection}{\Needspace{8\baselineskip}}'
)
Assert-ContainsLiteral 'STO-8.2.11' 'styles/susu-coursework.sty' @(
    '\setlist{nosep,leftmargin=\parindent',
    '\setlist[enumerate,1]{label=\arabic*)}'
)

# STO-8.4.3, STO-8.4.5: central decimal/group/unit policy and nonbreaking
# object references in the trusted renderer.
Assert-ContainsLiteral 'STO-8.4.3' 'styles/susu-coursework.sty' @(
    'output-decimal-marker={,}', 'per-mode=symbol'
)
Assert-ContainsLiteral 'STO-8.4.5' 'styles/susu-coursework.sty' @(
    'group-separator={\,}', 'group-minimum-digits=5'
)
Assert-ContainsLiteral 'STO-8.4.5' 'filters/susu.lua' @("'~' .. command")

# STO-8.5.10: the single-object flag reaches a dedicated global-numbering
# command and the PDF postflight asserts the visible caption number.
Assert-ContainsLiteral 'STO-8.5.10' 'templates/susu-coursework.tex' @(
    '$if(susu-single-figure)$', '\SUSUSingleFigureNumbering'
)
Assert-ContainsLiteral 'STO-8.5.10' 'scripts/validate-pdf.ps1' @(
    "Add-Failure 'STO-8.5.10'"
)

# STO-8.5.11, STO-8.7.10: appendix-local figure/equation number formats.
Assert-ContainsLiteral 'STO-8.5.11' 'styles/susu-coursework.sty' @(
    '\renewcommand{\thefigure}{#1.\arabic{figure}}'
)
Assert-ContainsLiteral 'STO-8.7.10' 'styles/susu-coursework.sty' @(
    '\renewcommand{\theequation}{#1.\arabic{equation}}'
)

# STO-8.6.7, STO-8.6.12, STO-8.6.13, STO-8.6.15: full-grid long tables,
# numeric policy and the permitted 12 point body size.
Assert-ContainsLiteral 'STO-8.6.7' 'filters/susu.lua' @('hlines, vlines,')
Assert-ContainsLiteral 'STO-8.6.12' 'styles/susu-coursework.sty' @(
    '\RequirePackage{siunitx}', 'output-decimal-marker={,}'
)
Assert-ContainsLiteral 'STO-8.6.13' 'filters/susu.lua' @(
    'rows={font=\\fontsize{12pt}{14pt}\\selectfont}'
)
Assert-ContainsLiteral 'STO-8.6.15' 'styles/susu-coursework.sty' @(
    'group-separator={\,}', 'group-minimum-digits=5'
)

# STO-8.7.6, STO-8.7.13, STO-8.7.17: one equation renderer and controlled
# upright/scalar/vector notation definitions.
Assert-ContainsLiteral 'STO-8.7.6' 'filters/susu.lua' @(
    '\begin{equation}', '\end{equation}'
)
Assert-ContainsLiteral 'STO-8.7.13' 'filters/susu.lua' @(
    "if has_class(div, 'equation') then", '\begin{equation}'
)
Assert-ContainsLiteral 'STO-8.7.17' 'styles/susu-coursework.sty' @(
    '\newcommand{\scalar}[1]{\symit{#1}}',
    '\newcommand{\greekscalar}[1]{\symup{#1}}'
)

# Positive integration contract: mandatory structure and a clean semantic
# source must pass. STO-6, STO-7.1.1, STO-7.2.1, STO-8.2.4, STO-8.2.5.
$positiveOutput = Join-Path $testBuild 'minimal.native'
$positive = Invoke-Validator -InputPath $basePath -OutputPath $positiveOutput
if ($positive.ExitCode -ne 0) {
    $failures.Add("valid/minimal.md failed unexpectedly:`n$($positive.Text)")
}
else {
    Write-Host 'PASS valid/minimal.md'
}

$baseText = [System.IO.File]::ReadAllText($basePath, [System.Text.Encoding]::UTF8)
$insertToken = 'INVALID_CASE_INSERTION_POINT'
if (-not $baseText.Contains($insertToken)) {
    Write-Error "Insertion token is missing from $basePath"
    exit 1
}

# Coverage gate contract: one controlled registry mutation simultaneously
# removes a canonical id, adds an extra id, removes a required field and
# breaks mechanism/status correspondence. Every independent guard must fire.
$registrySourcePath = Join-Path $root 'compliance/requirements.json'
$mutatedRegistryPath = Join-Path $testBuild 'requirements-mutated.json'
$mutatedRegistry = ([System.IO.File]::ReadAllText(
    $registrySourcePath,
    [System.Text.Encoding]::UTF8
)) | ConvertFrom-Json
$mutatedRegistry.requirements = @($mutatedRegistry.requirements | Select-Object -Skip 1)
$mutatedRegistry.requirements[0].PSObject.Properties.Remove('notes')
$mutatedRegistry.requirements[1].status = 'specified'
$extraRequirement = [pscustomobject][ordered]@{
    id = 'STO-FAKE-EXTRA'
    summary = 'Controlled non-canonical test record'
    applicability = 'test-only'
    mechanism = 'informational'
    status = 'indexed'
    implementation_markers = @()
    test_markers = @()
    notes = 'Must be rejected by the canonical inventory gate'
}
$mutatedRegistry.requirements = @($mutatedRegistry.requirements) + @($extraRequirement)
[System.IO.File]::WriteAllText(
    $mutatedRegistryPath,
    ($mutatedRegistry | ConvertTo-Json -Depth 12),
    (New-Object System.Text.UTF8Encoding($false))
)
$coverageMutation = Invoke-CoverageGate -RegistryPath $mutatedRegistryPath
$coverageExpected = @(
    'canonical requirement is missing from registry',
    'non-canonical extra requirement in registry',
    'missing required registry field: notes',
    'does not match informational; expected indexed'
)
if ($coverageMutation.ExitCode -eq 0) {
    $failures.Add('mutated requirements registry was accepted')
}
foreach ($message in $coverageExpected) {
    if (-not $coverageMutation.Text.Contains($message)) {
        $failures.Add("coverage mutation did not trigger: $message")
    }
}
if ($coverageMutation.ExitCode -ne 0 -and
    @($coverageExpected | Where-Object { -not $coverageMutation.Text.Contains($_) }).Count -eq 0) {
    Write-Host 'PASS canonical registry/schema mutation contract'
}

# STO-AI-GATE: deleting one semantic rule must be reported as an exact-set
# violation even though other strict-review fields are also intentionally open.
$semanticSourcePath = Join-Path $root 'compliance/semantic-review.yaml'
$externalSourcePath = Join-Path $root 'compliance/external-acceptance.yaml'
$semanticMissingPath = Join-Path $testBuild 'semantic-review-missing-rule.yaml'
$semanticText = [System.IO.File]::ReadAllText($semanticSourcePath, [System.Text.Encoding]::UTF8)
$semanticPattern = '(?ms)^    # STO-5\.1\r?\n    - id: STO-5\.1\r?\n.*?(?=^    # STO-5\.4\r?$)'
$semanticMissing = [regex]::Replace($semanticText, $semanticPattern, '')
[System.IO.File]::WriteAllText(
    $semanticMissingPath,
    $semanticMissing,
    (New-Object System.Text.UTF8Encoding($false))
)
$semanticGateOutput = Join-Path $testBuild 'semantic-gate.native'
$semanticGate = Invoke-Validator -InputPath $basePath -OutputPath $semanticGateOutput `
    -ExtraArguments @(
        "--metadata-file=$semanticMissingPath",
        "--metadata-file=$externalSourcePath",
        '--metadata=compliance-mode:strict',
        '--metadata=content-hash:contract-test'
    )
if ($semanticGate.ExitCode -eq 0 -or
    $semanticGate.Text -notmatch 'STO-AI-GATE: semantic-review\.rules:.*STO-5\.1') {
    $failures.Add("semantic exact-set mutation was not detected:`n$($semanticGate.Text)")
}
else {
    Write-Host 'PASS semantic-review exact-set mutation -> STO-AI-GATE'
}

# STO-EXT-GATE: the same fail-closed exact-set contract applies to external
# decisions; removal cannot be hidden by leaving the top-level status pending.
$externalMissingPath = Join-Path $testBuild 'external-acceptance-missing-item.yaml'
$externalText = [System.IO.File]::ReadAllText($externalSourcePath, [System.Text.Encoding]::UTF8)
$externalPattern = '(?ms)^    # STO-1:.*?\r?\n    - id: STO-1\r?\n.*?(?=^    # STO-2:)'
$externalMissing = [regex]::Replace($externalText, $externalPattern, '')
[System.IO.File]::WriteAllText(
    $externalMissingPath,
    $externalMissing,
    (New-Object System.Text.UTF8Encoding($false))
)
$externalGateOutput = Join-Path $testBuild 'external-gate.native'
$externalGate = Invoke-Validator -InputPath $basePath -OutputPath $externalGateOutput `
    -ExtraArguments @(
        "--metadata-file=$semanticSourcePath",
        "--metadata-file=$externalMissingPath",
        '--metadata=compliance-mode:strict',
        '--metadata=content-hash:contract-test'
    )
if ($externalGate.ExitCode -eq 0 -or
    $externalGate.Text -notmatch 'STO-EXT-GATE: external-acceptance\.items:.*STO-1') {
    $failures.Add("external exact-set mutation was not detected:`n$($externalGate.Text)")
}
else {
    Write-Host 'PASS external-acceptance exact-set mutation -> STO-EXT-GATE'
}

# STO-7.3.4: the recommended annotation length is a non-fatal diagnostic.
$annotationOutput = Join-Path $testBuild 'annotation-warning.native'
$annotationResult = Invoke-Validator -InputPath $basePath -OutputPath $annotationOutput `
    -ExtraArguments @('--metadata=abstract:x')
if ($annotationResult.ExitCode -ne 0 -or $annotationResult.Text -notmatch 'STO-7\.3\.4') {
    $failures.Add("STO-7.3.4 warning contract failed:`n$($annotationResult.Text)")
}
else {
    Write-Host 'PASS annotation length warning -> STO-7.3.4'
}

# STO-8.4.9: controlled mutation proves that a non-dd.mm.yyyy metadata date
# is rejected by the validator rather than merely documented in the template.
$badDateInput = Join-Path $testBuild 'invalid-date.md'
$badDateOutput = Join-Path $testBuild 'invalid-date.native'
$badDateText = $baseText.Replace('due-date: "31.05.2026"', 'due-date: "2026-05-31"')
[System.IO.File]::WriteAllText(
    $badDateInput,
    $badDateText,
    (New-Object System.Text.UTF8Encoding($false))
)
$badDateResult = Invoke-Validator -InputPath $badDateInput -OutputPath $badDateOutput
if ($badDateResult.ExitCode -eq 0 -or $badDateResult.Text -notmatch 'STO-8\.4\.9') {
    $failures.Add("STO-8.4.9 invalid-date mutation was not rejected:`n$($badDateResult.Text)")
}
else {
    Write-Host 'PASS invalid metadata date -> STO-8.4.9'
}

# STO-8.5.11, STO-8.6.7, STO-8.6.13, STO-8.7.10, STO-8.7.13:
# a valid semantic fragment is passed through both real Lua filters; generated
# LaTeX must use the typed appendix, grid-table and equation renderers.
$renderFragmentPath = Join-Path $root 'tests/valid/render-contract.md'
$renderFragment = [System.IO.File]::ReadAllText($renderFragmentPath, [System.Text.Encoding]::UTF8)
$renderFragment = [regex]::Replace($renderFragment, '<!--.*?-->', '', 'Singleline')
$renderInput = Join-Path $testBuild 'render-contract.md'
$renderOutput = Join-Path $testBuild 'render-contract.tex'
$renderText = $baseText.Replace($insertToken, $renderFragment)
[System.IO.File]::WriteAllText(
    $renderInput,
    $renderText,
    (New-Object System.Text.UTF8Encoding($false))
)
$renderResult = Invoke-Renderer -InputPath $renderInput -OutputPath $renderOutput
if ($renderResult.ExitCode -ne 0) {
    $failures.Add("semantic renderer contract failed:`n$($renderResult.Text)")
}
else {
    $generatedLatex = [System.IO.File]::ReadAllText($renderOutput, [System.Text.Encoding]::UTF8)
    $requiredLatex = @(
        '\begin{SUSUAppendix}',
        '\label{fig:appendix-contract}',
        '\label{eq:appendix-contract}',
        '\begin{longtblr}',
        'hlines, vlines,',
        'rows={font=\fontsize{12pt}{14pt}\selectfont}',
        '\begin{equation}',
        '\label{eq:render-contract}'
    )
    foreach ($literal in $requiredLatex) {
        if (-not $generatedLatex.Contains($literal)) {
            $failures.Add("semantic renderer contract is missing $literal")
        }
    }
    if (($generatedLatex.Split(@('\begin{equation}'), [StringSplitOptions]::None).Count - 1) -lt 2) {
        $failures.Add('semantic renderer did not use the same equation backend in main text and appendix')
    }
    Write-Host 'PASS semantic renderer integration contract'
}

foreach ($caseFile in (Get-ChildItem -LiteralPath $invalidDirectory -Filter '*.md' -File | Sort-Object Name)) {
    $fragment = [System.IO.File]::ReadAllText($caseFile.FullName, [System.Text.Encoding]::UTF8)
    $expect = [regex]::Match($fragment, '<!--\s*EXPECT:\s*(STO-[A-Za-z0-9.-]+)\s*-->')
    if (-not $expect.Success) {
        $failures.Add("$($caseFile.Name): missing <!-- EXPECT: STO-x --> marker")
        continue
    }

    $expectedClause = $expect.Groups[1].Value
    $caseInput = Join-Path $testBuild ($caseFile.BaseName + '.md')
    $caseOutput = Join-Path $testBuild ($caseFile.BaseName + '.native')
    # The EXPECT comment is test metadata, not document content. Removing it
    # prevents every negative case from also failing STO-NOTATION.
    $documentFragment = [regex]::Replace(
        $fragment,
        '<!--\s*EXPECT:\s*STO-[A-Za-z0-9.-]+\s*-->',
        ''
    )
    $combined = $baseText.Replace($insertToken, $documentFragment)
    [System.IO.File]::WriteAllText($caseInput, $combined, (New-Object System.Text.UTF8Encoding($false)))

    $result = Invoke-Validator -InputPath $caseInput -OutputPath $caseOutput
    if ($result.ExitCode -eq 0) {
        $failures.Add("$($caseFile.Name): validator accepted an invalid document; expected $expectedClause")
        continue
    }
    if ($result.Text -notmatch [regex]::Escape($expectedClause)) {
        $failures.Add("$($caseFile.Name): failed for a different reason; expected $expectedClause`n$($result.Text)")
        continue
    }
    Write-Host ("PASS {0} -> {1}" -f $caseFile.Name, $expectedClause)
}

foreach ($caseFile in (Get-ChildItem -LiteralPath (Join-Path $root 'tests/warnings') -Filter '*.md' -File | Sort-Object Name)) {
    $fragment = [System.IO.File]::ReadAllText($caseFile.FullName, [System.Text.Encoding]::UTF8)
    $expect = [regex]::Match($fragment, '<!--\s*EXPECT-WARNING:\s*(STO-[A-Za-z0-9.-]+)\s*-->')
    if (-not $expect.Success) {
        $failures.Add("$($caseFile.Name): missing EXPECT-WARNING marker")
        continue
    }
    $expectedClause = $expect.Groups[1].Value
    $documentFragment = [regex]::Replace(
        $fragment,
        '<!--\s*EXPECT-WARNING:\s*STO-[A-Za-z0-9.-]+\s*-->',
        ''
    )
    $caseInput = Join-Path $testBuild ($caseFile.BaseName + '-warning.md')
    $caseOutput = Join-Path $testBuild ($caseFile.BaseName + '-warning.native')
    [System.IO.File]::WriteAllText(
        $caseInput,
        $baseText.Replace($insertToken, $documentFragment),
        (New-Object System.Text.UTF8Encoding($false))
    )
    $result = Invoke-Validator -InputPath $caseInput -OutputPath $caseOutput
    if ($result.ExitCode -ne 0 -or $result.Text -notmatch [regex]::Escape($expectedClause)) {
        $failures.Add("$($caseFile.Name): warning contract failed for $expectedClause`n$($result.Text)")
        continue
    }
    Write-Host ("PASS {0} -> warning {1}" -f $caseFile.Name, $expectedClause)
}

# The CLI is the public entry point for users who should not need to know the
# internal PowerShell scripts. Keep a small smoke contract in the normal suite.
$cliPath = Join-Path $root 'scripts/autonormokontrol.ps1'
$launcherPath = Join-Path $root 'AutoNormoKontrol.cmd'
if (-not (Test-Path -LiteralPath $cliPath -PathType Leaf)) {
    $failures.Add('CLI smoke contract: scripts/autonormokontrol.ps1 is missing')
}
if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
    $failures.Add('CLI smoke contract: AutoNormoKontrol.cmd is missing')
}

if ((Test-Path -LiteralPath $cliPath -PathType Leaf) -and
    (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $cliPath,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) {
        $failures.Add(('CLI smoke contract: parser errors: {0}' -f
            (($parseErrors | ForEach-Object Message) -join '; ')))
    }

    $launcherText = [System.IO.File]::ReadAllText($launcherPath, [System.Text.Encoding]::UTF8)
    foreach ($literal in @('-ExecutionPolicy Bypass', 'scripts\autonormokontrol.ps1')) {
        if (-not $launcherText.Contains($literal)) {
            $failures.Add("CLI smoke contract: launcher is missing $literal")
        }
    }
    if ($launcherText -match '(?i)\bchcp\b') {
        $failures.Add('CLI smoke contract: launcher must not change the global console code page')
    }

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $helpOutput = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
            -File $cliPath help 2>&1)
        $helpExitCode = $LASTEXITCODE
        $invalidOutput = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
            -File $cliPath does-not-exist 2>&1)
        $invalidExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    $helpText = $helpOutput | Out-String
    if ($helpExitCode -ne 0 -or $helpText -notmatch '(?m)^\s+check\s+' -or
        $helpText -notmatch '(?m)^\s+draft\s+' -or
        $helpText -notmatch '(?m)^\s+install\s+') {
        $failures.Add("CLI smoke contract: help failed or commands are missing`n$helpText")
    }
    if ($invalidExitCode -ne 2) {
        $failures.Add(('CLI smoke contract: unknown command returned {0}, expected 2' -f
            $invalidExitCode))
    }

    if ($helpExitCode -eq 0 -and $invalidExitCode -eq 2 -and $parseErrors.Count -eq 0) {
        Write-Host 'PASS AutoNormoKontrol CLI smoke contract'
    }

    $cliText = [System.IO.File]::ReadAllText($cliPath, [System.Text.Encoding]::UTF8)
    foreach ($literal in @(
        'JohnMacFarlane.Pandoc',
        '--exact',
        '--source winget',
        'https://tug.org/texlive/windows.html'
    )) {
        if (-not $cliText.Contains($literal)) {
            $failures.Add("CLI dependency installer contract: missing $literal")
        }
    }
}

# Native stderr decoding must not depend on the active Windows console code
# page. This reproduces the exact Pandoc/Lua path used by the normal build.
$utf8ProbeFilter = Join-Path $root 'tests/utf8/emit-stderr.lua'
$utf8ProbeOutput = Join-Path $testBuild 'utf8-probe.native'
if (-not (Test-Path -LiteralPath $utf8ProbeFilter -PathType Leaf)) {
    $failures.Add('UTF-8 native stderr contract: probe filter is missing')
}
else {
    $utf8ProbeResult = Invoke-Utf8NativeCommand `
        -FilePath $pandoc.Source `
        -Arguments @(
            $basePath,
            '--from=markdown',
            '--to=native',
            "--lua-filter=$utf8ProbeFilter",
            "--output=$utf8ProbeOutput"
        ) `
        -WorkingDirectory $root
    $probeSource = [System.IO.File]::ReadAllText($utf8ProbeFilter, [System.Text.Encoding]::UTF8)
    $expectedProbeMatch = [regex]::Match($probeSource, "io\.stderr:write\('([^']+)\\n'\)")
    $expectedProbe = if ($expectedProbeMatch.Success) { $expectedProbeMatch.Groups[1].Value } else { '' }
    if ($utf8ProbeResult.ExitCode -ne 0 -or
        [string]::IsNullOrEmpty($expectedProbe) -or
        -not $utf8ProbeResult.StandardError.Contains($expectedProbe)) {
        $failures.Add(("UTF-8 native stderr contract failed:`n{0}" -f
            $utf8ProbeResult.StandardError))
    }
    else {
        Write-Host 'PASS Pandoc UTF-8 stderr decoding contract'
    }
}

if ($failures.Count -gt 0) {
    Write-Host ('Compliance tests failed: {0} problem(s).' -f $failures.Count) -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host ('  - ' + $failure) }
    exit 1
}

Write-Host 'All compliance validator tests passed.' -ForegroundColor Green
exit 0
