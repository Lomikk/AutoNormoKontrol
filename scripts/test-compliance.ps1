[CmdletBinding()]
param(
    [switch]$SkipCoverage
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root
. (Join-Path $PSScriptRoot 'utf8-native.ps1')
. (Join-Path $PSScriptRoot 'profile.ps1')
$profileRelativePath = Get-AutoNormoKontrolDefaultProfilePath -Root $root
$activeProfile = Resolve-AutoNormoKontrolProfile -Root $root -ProfilePath $profileRelativePath
$profileConfig = $activeProfile.Data
$activeProfileId = $activeProfile.ProfileId

if (-not $SkipCoverage) {
    & (Join-Path $PSScriptRoot 'check-coverage.ps1') -ProfilePath $profileRelativePath
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
$validatorSourcePath = [string]@($profileConfig.render.lua_filters)[0]
$rendererSourcePath = [string]@($profileConfig.render.lua_filters)[1]
$templateSourcePath = [string]$profileConfig.render.template
$styleSourcePath = [string]@($profileConfig.render.style_files)[0]
$postflightSourcePath = [string]$profileConfig.render.postflight
$validatorPath = Join-Path $root $validatorSourcePath
$rendererPath = Join-Path $root $rendererSourcePath
$reviewInventoryPath = Join-Path $root ([string]$profileConfig.compliance.review_inventory)
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
        "--metadata-file=$reviewInventoryPath",
        "--metadata=active-profile-id:$activeProfileId",
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

    $arguments = @(
        $InputPath,
        '--from=markdown+smart+fenced_divs+tex_math_dollars+table_captions+raw_tex+raw_html+raw_attribute',
        '--to=latex',
        "--metadata-file=$reviewInventoryPath",
        "--metadata=active-profile-id:$activeProfileId",
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

function Invoke-PowerShellFile {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$Arguments = @()
    )

    $shellArguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $ScriptPath
    ) + $Arguments
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $messages = @(& powershell.exe @shellArguments 2>&1)
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

# R2/profile-contract: the active document profile is an exact, versioned and
# fail-closed build input. Test manifests live below build/ and cannot become
# an implicit alternative profile.
$profileFullPath = Join-Path $root $profileRelativePath
$profileSchemaPath = Join-Path $root 'schemas/profile-v1.schema.json'
$profileTestEncoding = New-Object System.Text.UTF8Encoding($false)

function Get-ProfileTestDocument {
    return ([System.IO.File]::ReadAllText(
        $profileFullPath,
        [System.Text.Encoding]::UTF8
    ) | ConvertFrom-Json)
}

function Write-ProfileTestDocument {
    param(
        [Parameter(Mandatory = $true)][object]$Document,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $relative = 'build/compliance-tests/' + $Name
    [System.IO.File]::WriteAllText(
        (Join-Path $root $relative),
        ($Document | ConvertTo-Json -Depth 20),
        $profileTestEncoding
    )
    return $relative
}

function Assert-ProfileFailure {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][object]$Document,
        [Parameter(Mandatory = $true)][string]$Expected
    )
    $relative = Write-ProfileTestDocument -Document $Document -Name ($Name + '.yaml')
    try {
        [void](Resolve-AutoNormoKontrolProfile -Root $root -ProfilePath $relative)
        $failures.Add("R2 profile contract: $Name was accepted; expected $Expected")
    }
    catch {
        if ($_.Exception.Message -notmatch [regex]::Escape($Expected)) {
            $failures.Add(("R2 profile contract: {0} failed for a different reason; " +
                "expected '{1}', got '{2}'" -f $Name, $Expected, $_.Exception.Message))
        }
        else {
            Write-Host ("PASS R2 profile {0} fails closed" -f $Name)
        }
    }
}

try {
    $resolvedProfile = Resolve-AutoNormoKontrolProfile `
        -Root $root -ProfilePath $profileRelativePath
    if ($resolvedProfile.ProfileId -ne $activeProfileId -or
        [string]::IsNullOrWhiteSpace($resolvedProfile.ProfileDigest)) {
        $failures.Add('R2 profile contract: active profile did not resolve to the expected ID and digest')
    }
    else {
        Write-Host 'PASS R2 active profile resolves with a digest'
    }
}
catch {
    $failures.Add("R2 profile contract: active profile did not resolve: $($_.Exception.Message)")
}

try {
    $schema = [System.IO.File]::ReadAllText(
        $profileSchemaPath,
        [System.Text.Encoding]::UTF8
    ) | ConvertFrom-Json
    $manifest = Get-ProfileTestDocument
    $schemaSections = @('<root>', 'inputs', 'compliance', 'render', 'assets',
        'outputs', 'reports', 'capabilities')
    foreach ($section in $schemaSections) {
        $schemaNode = if ($section -eq '<root>') { $schema } else { $schema.properties.$section }
        $manifestNode = if ($section -eq '<root>') { $manifest } else { $manifest.$section }
        $schemaRequired = @($schemaNode.required | ForEach-Object { [string]$_ } | Sort-Object)
        $schemaProperties = @($schemaNode.properties.PSObject.Properties.Name | Sort-Object)
        $manifestFields = @($manifestNode.PSObject.Properties.Name | Sort-Object)
        $requiredDifference = @(Compare-Object $schemaRequired $manifestFields)
        $propertyDifference = @(Compare-Object $schemaProperties $manifestFields)
        if ($schemaNode.additionalProperties -ne $false -or
            $requiredDifference.Count -ne 0 -or $propertyDifference.Count -ne 0) {
            $failures.Add("R2 profile schema: $section exact-set contract does not match the active manifest")
        }
    }
    if (-not ($failures | Where-Object { $_ -like 'R2 profile schema:*' })) {
        Write-Host 'PASS R2 profile schema exact-set contract'
    }
}
catch {
    $failures.Add("R2 profile schema could not be parsed: $($_.Exception.Message)")
}

# R3/profile-extraction: profile selection is one explicit versioned pointer.
# Missing/ambiguous targets fail closed; directory scanning is never a fallback.
$profileLoaderText = Get-SourceText 'scripts/profile.ps1'
if ($profileLoaderText.Contains('Get-ChildItem') -or
    $profileLoaderText.Contains($activeProfileId)) {
    $failures.Add('R3 active profile selection scans directories or hard-codes the current profile ID')
}
else {
    Write-Host 'PASS R3 active profile selection has no scan/fallback'
}

$ambiguousPointerPath = Join-Path $testBuild 'active-profile-ambiguous.txt'
[System.IO.File]::WriteAllText(
    $ambiguousPointerPath,
    "$profileRelativePath`n$profileRelativePath`n",
    $profileTestEncoding
)
try {
    [void](Get-AutoNormoKontrolDefaultProfilePath -Root $root `
        -PointerPath 'build/compliance-tests/active-profile-ambiguous.txt')
    $failures.Add('R3 active profile pointer accepted more than one manifest path')
}
catch {
    if ($_.Exception.Message -notmatch 'exactly one non-empty') {
        $failures.Add("R3 ambiguous pointer failed for a different reason: $($_.Exception.Message)")
    }
    else {
        Write-Host 'PASS R3 ambiguous active profile pointer fails closed'
    }
}

$missingPointerPath = Join-Path $testBuild 'active-profile-missing.txt'
[System.IO.File]::WriteAllText(
    $missingPointerPath,
    'profiles/missing-profile-v1/profile.yaml',
    $profileTestEncoding
)
try {
    [void](Get-AutoNormoKontrolDefaultProfilePath -Root $root `
        -PointerPath 'build/compliance-tests/active-profile-missing.txt')
    $failures.Add('R3 active profile pointer accepted a missing manifest')
}
catch {
    if ($_.Exception.Message -notmatch "Profile file 'active_profile' was not found") {
        $failures.Add("R3 missing pointer target failed for a different reason: $($_.Exception.Message)")
    }
    else {
        Write-Host 'PASS R3 missing active profile target fails closed'
    }
}

$profilePrefix = "profiles/$activeProfileId/"
$packagedPaths = @(
    [string]$profileConfig.compliance.canonical_inventory,
    [string]$profileConfig.compliance.requirements,
    [string]$profileConfig.compliance.review_inventory,
    [string]$profileConfig.compliance.semantic_review_template,
    [string]$profileConfig.compliance.external_acceptance_template,
    [string]$profileConfig.compliance.system_prompt,
    [string]$profileConfig.compliance.research_notes,
    [string]$profileConfig.render.template,
    [string]$profileConfig.render.postflight
) + @($profileConfig.render.style_files) + @($profileConfig.render.lua_filters)
foreach ($packagedPath in $packagedPaths) {
    if (-not ([string]$packagedPath).Replace('\', '/').StartsWith(
        $profilePrefix, [StringComparison]::Ordinal)) {
        $failures.Add("R3 profile-owned file remains outside the profile package: $packagedPath")
    }
}
foreach ($workspaceEvidencePath in @(
    [string]$profileConfig.compliance.format_spec,
    [string]$profileConfig.compliance.semantic_review,
    [string]$profileConfig.compliance.external_acceptance
)) {
    if ($workspaceEvidencePath.Replace('\', '/').StartsWith(
        $profilePrefix, [StringComparison]::Ordinal)) {
        $failures.Add("R3 workspace evidence was incorrectly packaged as immutable profile data: $workspaceEvidencePath")
    }
}
if (-not ($failures | Where-Object { $_ -like 'R3 profile-owned*' -or
    $_ -like 'R3 workspace evidence*' })) {
    Write-Host 'PASS R3 profile package and workspace evidence boundary'
}

$engineFiles = @(
    'scripts/autonormokontrol.ps1', 'scripts/build.ps1', 'scripts/check-coverage.ps1',
    'scripts/lint-content.ps1', 'scripts/profile.ps1', 'scripts/report-traceability.ps1',
    'scripts/workspace.ps1', 'scripts/write-document-snapshot.ps1'
)
foreach ($engineFile in $engineFiles) {
    $engineText = Get-SourceText $engineFile
    if ($engineText.Contains($activeProfileId) -or
        $engineText -match '(?i)[''"]coursework[''"]') {
        $failures.Add("R3 engine source knows the current profile ID or document type: $engineFile")
    }
}
if (-not ($failures | Where-Object { $_ -like 'R3 engine source*' })) {
    Write-Host 'PASS R3 engine is independent of current profile identity'
}

$missingIdProfile = Get-ProfileTestDocument
$missingIdProfile.PSObject.Properties.Remove('profile_id')
Assert-ProfileFailure -Name 'missing-required-id' -Document $missingIdProfile `
    -Expected "missing required field 'profile_id'"

$unknownFieldProfile = Get-ProfileTestDocument
$unknownFieldProfile | Add-Member -NotePropertyName 'fallback_profile' -NotePropertyValue 'first'
Assert-ProfileFailure -Name 'unknown-field' -Document $unknownFieldProfile `
    -Expected "contains unknown field 'fallback_profile'"

$unknownNestedFieldProfile = Get-ProfileTestDocument
$unknownNestedFieldProfile.outputs | Add-Member `
    -NotePropertyName 'fallback_pdf' -NotePropertyValue 'build/first.pdf'
Assert-ProfileFailure -Name 'unknown-nested-field' -Document $unknownNestedFieldProfile `
    -Expected "contains unknown field 'fallback_pdf'"

$unsupportedVersionProfile = Get-ProfileTestDocument
$unsupportedVersionProfile.schema_version = 2
Assert-ProfileFailure -Name 'unsupported-version' -Document $unsupportedVersionProfile `
    -Expected 'Unsupported profile schema_version: 2'

$missingTemplateProfile = Get-ProfileTestDocument
$missingTemplateProfile.render.template = 'build/compliance-tests/missing-template.tex'
Assert-ProfileFailure -Name 'missing-source' -Document $missingTemplateProfile `
    -Expected "Profile file 'render.template' was not found"

$traversalProfile = Get-ProfileTestDocument
$traversalProfile.inputs.metadata = '../metadata.yaml'
Assert-ProfileFailure -Name 'path-traversal' -Document $traversalProfile `
    -Expected "Profile path 'inputs.metadata' leaves the project root"

try {
    $probeStyleRelative = 'build/compliance-tests/profile-digest-probe.sty'
    $probeStyleFull = Join-Path $root $probeStyleRelative
    [System.IO.File]::WriteAllText(
        $probeStyleFull,
        '% profile digest mutation probe',
        $profileTestEncoding
    )
    $digestProfile = Get-ProfileTestDocument
    $digestProfile.render.style_files = @($probeStyleRelative)
    $digestProfileRelative = Write-ProfileTestDocument `
        -Document $digestProfile -Name 'profile-digest-mutation.yaml'
    $beforeDigest = (Resolve-AutoNormoKontrolProfile `
        -Root $root -ProfilePath $digestProfileRelative).ProfileDigest
    [System.IO.File]::AppendAllText(
        $probeStyleFull,
        "`n% mutated",
        [System.Text.Encoding]::UTF8
    )
    $afterDigest = (Resolve-AutoNormoKontrolProfile `
        -Root $root -ProfilePath $digestProfileRelative).ProfileDigest
    if ($beforeDigest -eq $afterDigest) {
        $failures.Add('R2 profile digest mutation: referenced implementation change was not detected')
    }
    else {
        Write-Host 'PASS R2 profile digest changes with referenced implementation'
    }
}
catch {
    $failures.Add("R2 profile digest mutation test failed: $($_.Exception.Message)")
}

$buildProfileText = Get-SourceText 'scripts/build.ps1'
foreach ($requiredLiteral in @(
    'Resolve-AutoNormoKontrolWorkspace',
    '$workspace.Profile',
    '$profile.ProfileId',
    '$profile.ProfileDigest',
    '$config.outputs.pdf',
    '$config.render.template'
)) {
    if (-not $buildProfileText.Contains($requiredLiteral)) {
        $failures.Add("R2 build integration contract: missing $requiredLiteral")
    }
}
foreach ($forbiddenLiteral in @(
    [string]$profileConfig.render.template,
    [string]$profileConfig.outputs.pdf,
    [string]@($profileConfig.inputs.content)[0]
)) {
    if ($buildProfileText.Contains($forbiddenLiteral)) {
        $failures.Add("R2 build integration contract: profile path remains hard-coded: $forbiddenLiteral")
    }
}
if ($failures.Count -eq 0) {
    Write-Host 'PASS R2 build integration uses the resolved profile'
}

# Static regression tests execute against the trusted implementation sources.
# They verify structure and exact centralised commands, not marker presence.

# STO-7.1.3, STO-A1: Appendix A1 title form fields and their order.
Assert-OrderedLiterals 'STO-A1' $templateSourcePath @(
    '$parent-organization$', '$university$', '$faculty-label$', '$school$',
    '$department$', '$title$', '$discipline$', '$document-code$',
    '$normal-controller.name$', '$supervisor.name$', '$student.group$',
    '$student.name$', '$city$', '$year$'
)

# STO-V: selected two-page coursework assignment form and signatures.
Assert-OrderedLiterals 'STO-V' $templateSourcePath @(
    '$if(include-assignment)$', '$assignment.head-of-department$',
    '$assignment.approval-date$', '$assignment.student-full-name$',
    '$discipline$', '$title$', '$assignment.due-date$',
    '$for(assignment.questions)$', '\clearpage', '$for(assignment.calendar)$',
    '$supervisor.name$', '$student.name$', '$if(abstract)$'
)

# STO-7.3.1: assignment, annotation and contents have a fixed order.
Assert-OrderedLiterals 'STO-7.3.1' $templateSourcePath @(
    '$if(include-assignment)$', '$if(abstract)$', '$abstract$', '\tableofcontents'
)

# STO-7.11.2, STO-7.11.4: one biblatex end-list backend, citation order,
# no hidden nocite-all path that could print an unreferenced source.
Assert-ContainsLiteral 'STO-7.11.2' $rendererSourcePath @('\printbibliography')
Assert-ContainsLiteral 'STO-7.11.4' $templateSourcePath @(
    'backend=biber', 'style=gost-numeric', 'sorting=none'
)
Assert-ContainsLiteral 'STO-7.11.4' 'scripts/build.ps1' @('--biblatex')
Assert-NotContainsLiteral 'STO-7.11.4' $templateSourcePath @('\nocite{*}')

# STO-7.12.7, STO-7.12.8: page counter stays global while the structural
# hierarchy and object counters become appendix-local.
Assert-ContainsLiteral 'STO-7.12.8' $styleSourcePath @(
    '\renewcommand{\thesection}{#1.\arabic{section}}',
    '\renewcommand{\thesubsection}{\thesection.\arabic{subsection}}'
)
Assert-NotContainsLiteral 'STO-7.12.7' $styleSourcePath @(
    '\setcounter{page}{0}', '\setcounter{page}{1}'
)

# STO-8.2.3, STO-8.2.6, STO-8.2.7, STO-8.2.9, STO-8.2.11: automatic
# hierarchy, heading layout, keep-with-next space and permitted list marker.
Assert-ContainsLiteral 'STO-8.2.3' $styleSourcePath @(
    '\setcounter{secnumdepth}{4}', '\setcounter{tocdepth}{4}'
)
Assert-ContainsLiteral 'STO-8.2.6' $styleSourcePath @(
    '\titleformat{\section}[block]', '{\thesection}{0.6em}{\MakeUppercase}'
)
Assert-ContainsLiteral 'STO-8.2.7' $styleSourcePath @(
    '\titlespacing*{\subsection}{\parindent}',
    '\titlespacing*{\subsubsection}{\parindent}'
)
Assert-ContainsLiteral 'STO-8.2.9' $styleSourcePath @(
    '\pretocmd{\section}{\Needspace{10\baselineskip}}',
    '\pretocmd{\subsection}{\Needspace{8\baselineskip}}'
)
Assert-ContainsLiteral 'STO-8.2.11' $styleSourcePath @(
    '\setlist{nosep,leftmargin=\parindent',
    '\setlist[enumerate,1]{label=\arabic*)}'
)

# STO-8.4.3, STO-8.4.5: central decimal/group/unit policy and nonbreaking
# object references in the trusted renderer.
Assert-ContainsLiteral 'STO-8.4.3' $styleSourcePath @(
    'output-decimal-marker={,}', 'per-mode=symbol'
)
Assert-ContainsLiteral 'STO-8.4.5' $styleSourcePath @(
    'group-separator={\,}', 'group-minimum-digits=5'
)
Assert-ContainsLiteral 'STO-8.4.5' $rendererSourcePath @("'~' .. command")

# STO-8.5.10: the single-object flag reaches a dedicated global-numbering
# command and the PDF postflight asserts the visible caption number.
Assert-ContainsLiteral 'STO-8.5.10' $templateSourcePath @(
    '$if(susu-single-figure)$', '\SUSUSingleFigureNumbering'
)
Assert-ContainsLiteral 'STO-8.5.10' $postflightSourcePath @(
    "Add-Failure 'STO-8.5.10'"
)

# STO-8.5.11, STO-8.7.10: appendix-local figure/equation number formats.
Assert-ContainsLiteral 'STO-8.5.11' $styleSourcePath @(
    '\renewcommand{\thefigure}{#1.\arabic{figure}}'
)
Assert-ContainsLiteral 'STO-8.7.10' $styleSourcePath @(
    '\renewcommand{\theequation}{#1.\arabic{equation}}'
)

# STO-8.6.7, STO-8.6.12, STO-8.6.13, STO-8.6.15: full-grid long tables,
# numeric policy and the permitted 12 point body size.
Assert-ContainsLiteral 'STO-8.6.7' $rendererSourcePath @('hlines, vlines,')
Assert-ContainsLiteral 'STO-8.6.12' $styleSourcePath @(
    '\RequirePackage{siunitx}', 'output-decimal-marker={,}'
)
Assert-ContainsLiteral 'STO-8.6.13' $rendererSourcePath @(
    'rows={font=\\fontsize{12pt}{14pt}\\selectfont}'
)
Assert-ContainsLiteral 'STO-8.6.15' $styleSourcePath @(
    'group-separator={\,}', 'group-minimum-digits=5'
)

# STO-8.7.6, STO-8.7.13, STO-8.7.17: one equation renderer and controlled
# upright/scalar/vector notation definitions.
Assert-ContainsLiteral 'STO-8.7.6' $rendererSourcePath @(
    '\begin{equation}', '\end{equation}'
)
Assert-ContainsLiteral 'STO-8.7.13' $rendererSourcePath @(
    "if has_class(div, 'equation') then", '\begin{equation}'
)
Assert-ContainsLiteral 'STO-8.7.17' $styleSourcePath @(
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
$registrySourcePath = Join-Path $root ([string]$profileConfig.compliance.requirements)
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
$semanticSourcePath = Join-Path $root ([string]$profileConfig.compliance.semantic_review)
$externalSourcePath = Join-Path $root ([string]$profileConfig.compliance.external_acceptance)
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

# R2/profile-contract, STO-AI-GATE: the canonical inventory is independent of
# the mutable review journal. Removing an expected ID from profile data must
# make the unchanged review invalid, not silently reduce the release gate.
$inventoryMissingPath = Join-Path $testBuild 'review-inventory-missing-id.yaml'
$inventoryText = [System.IO.File]::ReadAllText($reviewInventoryPath, [System.Text.Encoding]::UTF8)
$inventoryMissing = [regex]::Replace(
    $inventoryText,
    '(?m)^    - STO-5\.1\r?\n',
    '',
    1
)
[System.IO.File]::WriteAllText(
    $inventoryMissingPath,
    $inventoryMissing,
    (New-Object System.Text.UTF8Encoding($false))
)
$inventoryGateOutput = Join-Path $testBuild 'profile-inventory-gate.native'
$inventoryGate = Invoke-Validator -InputPath $basePath -OutputPath $inventoryGateOutput `
    -ExtraArguments @(
        "--metadata-file=$inventoryMissingPath",
        "--metadata-file=$semanticSourcePath",
        "--metadata-file=$externalSourcePath",
        '--metadata=compliance-mode:strict',
        '--metadata=content-hash:contract-test'
    )
if ($inventoryGate.ExitCode -eq 0 -or
    $inventoryGate.Text -notmatch 'STO-AI-GATE: semantic-review\.rules:.*STO-5\.1') {
    $failures.Add("profile review inventory mutation was not detected:`n$($inventoryGate.Text)")
}
else {
    Write-Host 'PASS profile review inventory exact-set mutation -> STO-AI-GATE'
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

# R1.1 asset pipeline: execute the real builder in an isolated project copy.
# The fixtures are generated below build/ and never become coursework inputs.
$assetBuilderPath = Join-Path $root 'scripts/build-assets.ps1'
$snapshotWriterPath = Join-Path $root 'scripts/write-document-snapshot.ps1'
$assetTestRoot = Join-Path $testBuild 'asset-pipeline'
$assetTestRootFull = [System.IO.Path]::GetFullPath($assetTestRoot)
$testBuildPrefix = [System.IO.Path]::GetFullPath($testBuild).TrimEnd('\', '/') + `
    [System.IO.Path]::DirectorySeparatorChar
if (-not $assetTestRootFull.StartsWith($testBuildPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    $failures.Add('R1.1 asset test root escaped build/compliance-tests')
}
else {
    if (Test-Path -LiteralPath $assetTestRootFull) {
        Remove-Item -LiteralPath $assetTestRootFull -Recurse -Force
    }
    foreach ($directory in @('assets', 'assets/data', 'assets/plots', 'content', 'build')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $assetTestRootFull $directory) | Out-Null
    }
    Copy-Item -LiteralPath (Join-Path $root 'assets/manifest.json') `
        -Destination (Join-Path $assetTestRootFull 'assets/manifest.json')
    Copy-Item -LiteralPath (Join-Path $root 'assets/data/extraction.csv') `
        -Destination (Join-Path $assetTestRootFull 'assets/data/extraction.csv')
    Copy-Item -LiteralPath (Join-Path $root 'assets/plots/extraction.tex') `
        -Destination (Join-Path $assetTestRootFull 'assets/plots/extraction.tex')
    [System.IO.File]::WriteAllText(
        (Join-Path $assetTestRootFull 'content/sample.md'),
        'snapshot fixture',
        (New-Object System.Text.UTF8Encoding($false))
    )

    $assetSuccess = Invoke-PowerShellFile -ScriptPath $assetBuilderPath `
        -Arguments @('-ProjectRoot', $assetTestRootFull)
    $assetPdf = Join-Path $assetTestRootFull 'build/assets/extraction.pdf'
    $assetReportPath = Join-Path $assetTestRootFull 'build/asset-report.json'
    if ($assetSuccess.ExitCode -ne 0 -or
        -not (Test-Path -LiteralPath $assetPdf -PathType Leaf) -or
        -not (Test-Path -LiteralPath $assetReportPath -PathType Leaf)) {
        $failures.Add("R1.1 successful asset build failed:`n$($assetSuccess.Text)")
    }
    else {
        $firstPdfHash = (Get-FileHash -LiteralPath $assetPdf -Algorithm SHA256).Hash
        $assetRepeat = Invoke-PowerShellFile -ScriptPath $assetBuilderPath `
            -Arguments @('-ProjectRoot', $assetTestRootFull)
        $secondPdfHash = if (Test-Path -LiteralPath $assetPdf -PathType Leaf) {
            (Get-FileHash -LiteralPath $assetPdf -Algorithm SHA256).Hash
        } else { '' }
        if ($assetRepeat.ExitCode -ne 0 -or $firstPdfHash -ne $secondPdfHash) {
            $failures.Add("R1.1 repeated build is not byte-reproducible:`n$($assetRepeat.Text)")
        }
        else {
            Write-Host 'PASS R1.1 successful and byte-reproducible asset build'
        }
    }

    $csvPath = Join-Path $assetTestRootFull 'assets/data/extraction.csv'
    $csvBackup = Join-Path $assetTestRootFull 'assets/data/extraction.csv.test-backup'
    Move-Item -LiteralPath $csvPath -Destination $csvBackup
    try {
        $missingCsv = Invoke-PowerShellFile -ScriptPath $assetBuilderPath `
            -Arguments @('-ProjectRoot', $assetTestRootFull)
        if ($missingCsv.ExitCode -eq 0 -or $missingCsv.Text -notmatch 'CSV data source\s+not found') {
            $failures.Add("R1.1 missing CSV did not fail closed:`n$($missingCsv.Text)")
        }
        else {
            Write-Host 'PASS R1.1 missing CSV fails closed'
        }
    }
    finally {
        Move-Item -LiteralPath $csvBackup -Destination $csvPath
    }

    $texPath = Join-Path $assetTestRootFull 'assets/plots/extraction.tex'
    $texBackup = Join-Path $assetTestRootFull 'assets/plots/extraction.tex.test-backup'
    Move-Item -LiteralPath $texPath -Destination $texBackup
    try {
        $missingTex = Invoke-PowerShellFile -ScriptPath $assetBuilderPath `
            -Arguments @('-ProjectRoot', $assetTestRootFull)
        if ($missingTex.ExitCode -eq 0 -or $missingTex.Text -notmatch '(?s)TeX source.*not.*found') {
            $failures.Add("R1.1 missing TeX source did not fail closed:`n$($missingTex.Text)")
        }
        else {
            Write-Host 'PASS R1.1 missing TeX source fails closed'
        }
    }
    finally {
        Move-Item -LiteralPath $texBackup -Destination $texPath
    }

    $unknownAsset = Invoke-PowerShellFile -ScriptPath $assetBuilderPath `
        -Arguments @('-ProjectRoot', $assetTestRootFull, '-Id', 'unknown-asset')
    if ($unknownAsset.ExitCode -eq 0 -or $unknownAsset.Text -notmatch 'Unknown asset ID') {
        $failures.Add("R1.1 unknown asset ID did not fail closed:`n$($unknownAsset.Text)")
    }
    else {
        Write-Host 'PASS R1.1 unknown asset ID fails closed'
    }

    # Rebuild after the negative fixtures, create a baseline snapshot, mutate
    # only CSV data, and prove that the review-bound content hash changes.
    $baselineBuild = Invoke-PowerShellFile -ScriptPath $assetBuilderPath `
        -Arguments @('-ProjectRoot', $assetTestRootFull)
    $baselineSnapshotPath = Join-Path $assetTestRootFull 'build/snapshot-before.json'
    $baselineSnapshot = Invoke-PowerShellFile -ScriptPath $snapshotWriterPath `
        -Arguments @(
            '-ProjectRoot', $assetTestRootFull,
            '-OutputPath', 'build/snapshot-before.json',
            '-ContentPaths', 'content/sample.md'
        )
    if ($baselineBuild.ExitCode -ne 0 -or $baselineSnapshot.ExitCode -ne 0) {
        $failures.Add("R1.1 baseline snapshot failed:`n$($baselineBuild.Text)`n$($baselineSnapshot.Text)")
    }
    else {
        $beforeHash = (Get-Content -Raw -Encoding UTF8 -LiteralPath $baselineSnapshotPath |
            ConvertFrom-Json).content_hash
        $csvText = [System.IO.File]::ReadAllText($csvPath, [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText(
            $csvPath,
            $csvText.Replace('5,100', '5,99'),
            (New-Object System.Text.UTF8Encoding($false))
        )
        $changedBuild = Invoke-PowerShellFile -ScriptPath $assetBuilderPath `
            -Arguments @('-ProjectRoot', $assetTestRootFull)
        $changedSnapshotPath = Join-Path $assetTestRootFull 'build/snapshot-after.json'
        $changedSnapshot = Invoke-PowerShellFile -ScriptPath $snapshotWriterPath `
            -Arguments @(
                '-ProjectRoot', $assetTestRootFull,
                '-OutputPath', 'build/snapshot-after.json',
                '-ContentPaths', 'content/sample.md'
            )
        if ($changedBuild.ExitCode -ne 0 -or $changedSnapshot.ExitCode -ne 0) {
            $failures.Add("R1.1 changed snapshot failed:`n$($changedBuild.Text)`n$($changedSnapshot.Text)")
        }
        else {
            $afterHash = (Get-Content -Raw -Encoding UTF8 -LiteralPath $changedSnapshotPath |
                ConvertFrom-Json).content_hash
            if ($beforeHash -eq $afterHash) {
                $failures.Add('R1.1 CSV mutation did not invalidate the document snapshot')
            }
            else {
                Write-Host 'PASS R1.1 input mutation invalidates semantic-review snapshot'
            }
        }
    }
}

$buildScriptText = Get-SourceText 'scripts/build.ps1'
if ($buildScriptText.Contains('fixtures/architecture.tex') -or
    -not $buildScriptText.Contains('build-assets.ps1') -or
    -not $buildScriptText.Contains('write-document-snapshot.ps1')) {
    $failures.Add('R1.1 Draft integration still uses fixture hardcode or omits the asset/snapshot pipeline')
}
else {
    Write-Host 'PASS R1.1 Draft integration contract'
}

# R0/remove-snapshot-content-fallback: the profile is the only source of the
# document input list. The snapshot writer must never restore coursework paths.
$snapshotWriterText = Get-SourceText 'scripts/write-document-snapshot.ps1'
$courseworkSnapshotPaths = @(
    'content/00-introduction.md', 'content/01-literature-review.md',
    'content/02-main.md', 'content/03-conclusion.md',
    'content/90-bibliography.md', 'content/99-appendix.md'
)
foreach ($path in $courseworkSnapshotPaths) {
    if ($snapshotWriterText.Contains($path)) {
        $failures.Add("R0 snapshot writer retains hard-coded coursework content path: $path")
    }
}
if ($snapshotWriterText -notmatch '\[Parameter\(Mandatory\s*=\s*\$true\)\]\s*\r?\n\s*\[ValidateNotNullOrEmpty\(\)\]\s*\r?\n\s*\[string\[\]\]\$ContentPaths') {
    $failures.Add('R0 snapshot writer does not require a non-empty ContentPaths argument')
}
if (-not $buildScriptText.Contains('-ContentPaths $snapshotInputs') -or
    -not $buildScriptText.Contains('$metadataPath') -or
    -not $buildScriptText.Contains('$bibliographyPath') -or
    -not $buildScriptText.Contains('$config.compliance.format_spec') -or
    -not $buildScriptText.Contains('$script:AutoNormoKontrolWorkspaceManifest')) {
    $failures.Add('R0 Draft integration does not pass content, metadata, bibliography, format spec, and project manifest to snapshot writer')
}
else {
    Write-Host 'PASS R0 profile-driven snapshot inputs are wired through Draft build'
}

if (Test-Path -LiteralPath $assetTestRootFull -PathType Container) {
    $missingContentPaths = Invoke-PowerShellFile -ScriptPath $snapshotWriterPath `
        -Arguments @('-ProjectRoot', $assetTestRootFull, '-OutputPath', 'build/snapshot-missing-content.json')
    if ($missingContentPaths.ExitCode -eq 0 -or $missingContentPaths.Text -notmatch 'ContentPaths') {
        $failures.Add("R0 missing ContentPaths did not fail closed:`n$($missingContentPaths.Text)")
    }
    else {
        Write-Host 'PASS R0 missing ContentPaths fails closed'
    }

    $emptyContentPaths = $null
    $emptyContentPathsExitCode = 0
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $snapshotWriterCommandPath = $snapshotWriterPath.Replace("'", "''")
        $assetTestCommandRoot = $assetTestRootFull.Replace("'", "''")
        $emptyContentPaths = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
            -Command "& '$snapshotWriterCommandPath' -ProjectRoot '$assetTestCommandRoot' -OutputPath 'build/snapshot-empty-content.json' -ContentPaths @(); if (`$?) { exit `$LASTEXITCODE }; exit 1" 2>&1)
        $emptyContentPathsExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $emptyContentPathsText = ($emptyContentPaths | Out-String)
    if ($emptyContentPathsExitCode -eq 0 -or $emptyContentPathsText -notmatch 'ContentPaths') {
        $failures.Add("R0 empty ContentPaths did not fail closed:`n$emptyContentPathsText")
    }
    else {
        Write-Host 'PASS R0 empty ContentPaths fails closed'
    }
}

# R1.4a/context-plan-v1 is an engine contract, not a document fixture. Keep its
# fail-closed permission and adapter tests in a focused script, but run them as
# part of the normal compliance suite so `check` cannot skip them.
$contextPlanTestPath = Join-Path $root 'scripts/test-context-plan.ps1'
if (-not (Test-Path -LiteralPath $contextPlanTestPath -PathType Leaf)) {
    $failures.Add('context-plan-v1 contract test script is missing')
}
else {
    $contextPlanTestResult = Invoke-PowerShellFile -ScriptPath $contextPlanTestPath
    if ($contextPlanTestResult.ExitCode -ne 0) {
        $failures.Add("context-plan-v1 contract tests failed:`n$($contextPlanTestResult.Text)")
    }
    else {
        Write-Host $contextPlanTestResult.Text.TrimEnd()
    }
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
    $cliAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $cliPath,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) {
        $failures.Add(('CLI smoke contract: parser errors: {0}' -f
            (($parseErrors | ForEach-Object Message) -join '; ')))
    }
    $bareElseCommands = @($cliAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'else'
    }, $true))
    if ($bareElseCommands.Count -gt 0) {
        $failures.Add('CLI smoke contract: a bare else command escaped structural parsing')
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
        $contextOutput = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
            -File $cliPath context edit-content ([string]@($profileConfig.inputs.content)[0]) 2>&1)
        $contextExitCode = $LASTEXITCODE
        $contextUsageOutput = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
            -File $cliPath context 2>&1)
        $contextUsageExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    $helpText = $helpOutput | Out-String
    if ($helpExitCode -ne 0 -or $helpText -notmatch '(?m)^\s+check\s+' -or
        $helpText -notmatch '(?m)^\s+draft\s+' -or
        $helpText -notmatch '(?m)^\s+install\s+' -or
        $helpText -notmatch '(?m)^\s+new\s+' -or
        $helpText -notmatch '(?m)^\s+export\s+' -or
        $helpText -notmatch '(?m)^\s+archive\s+' -or
        $helpText -notmatch '(?m)^\s+context\s+') {
        $failures.Add("CLI smoke contract: help failed or commands are missing`n$helpText")
    }
    if ($invalidExitCode -ne 2) {
        $failures.Add(('CLI smoke contract: unknown command returned {0}, expected 2' -f
            $invalidExitCode))
    }
    if ($contextExitCode -ne 0 -or
        -not (Test-Path -LiteralPath (Join-Path $root 'build/ai/context-plan.json') -PathType Leaf)) {
        $failures.Add("CLI smoke contract: context command failed`n$($contextOutput | Out-String)")
    }
    if ($contextUsageExitCode -ne 2) {
        $failures.Add(('CLI smoke contract: invalid context usage returned {0}, expected 2' -f
            $contextUsageExitCode))
    }

    if ($helpExitCode -eq 0 -and $invalidExitCode -eq 2 -and
        $contextExitCode -eq 0 -and $contextUsageExitCode -eq 2 -and
        $parseErrors.Count -eq 0) {
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

# R1/workspace + R1/publish: exercise the complete public lifecycle in a
# disposable Workspaces child. The helper owns fail-closed cleanup.
$lifecycleTest = Invoke-PowerShellFile `
    -ScriptPath (Join-Path $root 'scripts/test-workspace-lifecycle.ps1')
if ($lifecycleTest.ExitCode -ne 0) {
    $failures.Add("R1 workspace lifecycle integration failed:`n$($lifecycleTest.Text)")
}
else {
    Write-Host 'PASS R1 workspace lifecycle integration'
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
