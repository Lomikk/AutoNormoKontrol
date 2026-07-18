# R0/maintainability: Pandoc semantic validator, mutation and fixture tests.
# Dot-sourced by test-compliance.ps1; requires the runner Pandoc helpers.

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
$semanticSourcePath = Join-Path $root ([string]$profileConfig.compliance.semantic_review_template)
$externalSourcePath = Join-Path $root ([string]$profileConfig.compliance.external_acceptance_template)
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
