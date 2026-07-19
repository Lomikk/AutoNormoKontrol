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

# STO-6, R0/requirements-v2: the Lua handler executes the compiled graph and
# resolves message/hint through the diagnostic catalog rather than a hidden
# hard-coded sentence.
$reorderedPath = Join-Path $testBuild 'structure-reordered.md'
$levelOneHeaders = @([regex]::Matches($baseText, '(?m)^# [^#].+$'))
if ($levelOneHeaders.Count -lt 4) {
    Write-Error 'The positive fixture does not contain four level-one headers.'
    exit 1
}
$mainHeader = $levelOneHeaders[1].Value
$conclusionHeader = $levelOneHeaders[2].Value
$reorderedText = $baseText.Replace($mainHeader, '# TEMP-STRUCTURE')
$reorderedText = $reorderedText.Replace($conclusionHeader, $mainHeader)
$reorderedText = $reorderedText.Replace('# TEMP-STRUCTURE', $conclusionHeader)
[System.IO.File]::WriteAllText($reorderedPath, $reorderedText,
    (New-Object Text.UTF8Encoding($false)))
$reorderedResult = Invoke-Validator `
    -InputPath $reorderedPath -OutputPath (Join-Path $testBuild 'structure-reordered.native')
if ($reorderedResult.ExitCode -eq 0 -or
    $reorderedResult.Text -notmatch 'STO-6/ELEMENT_ORDER') {
    $failures.Add("compiled document.element-order was not enforced:`n$($reorderedResult.Text)")
}
else { Write-Host 'PASS requirements v2 structure order -> STO-6/ELEMENT_ORDER' }

$missingIntroductionPath = Join-Path $testBuild 'structure-missing-introduction.md'
$introductionHeader = $levelOneHeaders[0].Value
$missingIntroductionText = $baseText.Replace($introductionHeader, $introductionHeader.Substring(2))
[System.IO.File]::WriteAllText($missingIntroductionPath, $missingIntroductionText,
    (New-Object Text.UTF8Encoding($false)))
$missingIntroductionResult = Invoke-Validator `
    -InputPath $missingIntroductionPath `
    -OutputPath (Join-Path $testBuild 'structure-missing-introduction.native')
if ($missingIntroductionResult.ExitCode -eq 0 -or
    $missingIntroductionResult.Text -notmatch 'STO-6/MISSING_REQUIRED_ELEMENT') {
    $failures.Add("compiled document.required-elements was not enforced:`n$($missingIntroductionResult.Text)")
}
else { Write-Host 'PASS requirements v2 required element -> STO-6/MISSING_REQUIRED_ELEMENT' }

# R0/requirements-v2: the canonical source inventory and the profile registry
# are independent. Removing one profile decision cannot shorten the standard.
$registrySourcePath = Join-Path $root ([string]$profileConfig.compliance.requirements)
$mutatedRegistryPath = Join-Path $testBuild 'requirements-mutated.json'
$mutatedRegistry = ([System.IO.File]::ReadAllText(
    $registrySourcePath,
    [System.Text.Encoding]::UTF8
)) | ConvertFrom-Json
$removedRequirementId = [string]$mutatedRegistry.requirements[0].id
$mutatedRegistry.requirements = @($mutatedRegistry.requirements | Select-Object -Skip 1)
[System.IO.File]::WriteAllText(
    $mutatedRegistryPath,
    ($mutatedRegistry | ConvertTo-Json -Depth 12),
    (New-Object System.Text.UTF8Encoding($false))
)
$coverageMutation = Invoke-CoverageGate -RequirementsPath $mutatedRegistryPath
$coverageMutationText = $coverageMutation.Text -replace '\s+', ' '
if ($coverageMutation.ExitCode -eq 0 -or
    $coverageMutationText -notmatch ([regex]::Escape("$removedRequirementId`: canonical") +
        '.*inventory entry is missing from profile requirements')) {
    $failures.Add("requirements v2 exact-set mutation was not rejected:`n$($coverageMutation.Text)")
}
else {
    Write-Host 'PASS requirements v2 exact-set mutation contract'
}

# R0/requirements-v2: source identity and artifact location are normalized at
# inventory.source. Entries carry only their stable clause and may not restore
# the removed per-entry source/document_id/locator duplication.
$inventorySourcePath = Join-Path $root ([string]$profileConfig.compliance.inventory)
$legacyInventoryPath = Join-Path $testBuild 'inventory-legacy-source.json'
$legacyInventory = ([System.IO.File]::ReadAllText(
    $inventorySourcePath,
    [System.Text.Encoding]::UTF8
)) | ConvertFrom-Json
$legacyInventory.entries[0] | Add-Member -NotePropertyName source -NotePropertyValue `
    ([pscustomobject]@{ document_id = 'STO-21-2008'; clause = '1'; locator = 'duplicate' })
[System.IO.File]::WriteAllText(
    $legacyInventoryPath,
    ($legacyInventory | ConvertTo-Json -Depth 20),
    (New-Object System.Text.UTF8Encoding($false))
)
$legacyInventoryResult = Invoke-CoverageGate -InventoryPath $legacyInventoryPath
if ($legacyInventoryResult.ExitCode -eq 0 -or
    ($legacyInventoryResult.Text -replace '\s+', ' ') -notmatch 'unknown field.*source') {
    $failures.Add("legacy per-entry source duplication was accepted:`n$($legacyInventoryResult.Text)")
}
else { Write-Host 'PASS requirements v2 normalized source entry contract' }

# R0/requirements-v2: an additional profile rule is allowed only with explicit
# local provenance. It cannot pretend to be another canonical source clause.
$localRulePath = Join-Path $testBuild 'requirements-local-origin.json'
$localRuleRegistry = ([System.IO.File]::ReadAllText($registrySourcePath, [Text.Encoding]::UTF8)) |
    ConvertFrom-Json
$localRuleRegistry.requirements = @($localRuleRegistry.requirements) + @(
    [pscustomobject][ordered]@{
        id = 'PROFILE-LOCAL-CONTRACT-TEST'
        origin = [pscustomobject][ordered]@{
            kind = 'profile'
            source = 'Controlled test decision'
            locator = 'scripts/tests/semantic-validator.tests.ps1'
        }
        summary = 'Controlled local formal rule'
        disposition = 'formal'
        scope = 'test-only'
        verification = @()
        notes = 'Proves that local rules do not alter the source inventory.'
    }
)
[System.IO.File]::WriteAllText($localRulePath, ($localRuleRegistry | ConvertTo-Json -Depth 30),
    (New-Object Text.UTF8Encoding($false)))
$localRuleResult = Invoke-CoverageGate -RequirementsPath $localRulePath
if ($localRuleResult.ExitCode -ne 0) {
    $failures.Add("requirements v2 local origin was rejected:`n$($localRuleResult.Text)")
}
else { Write-Host 'PASS requirements v2 local origin stays outside source exact-set' }

$fakeSourcePath = Join-Path $testBuild 'requirements-fake-source-ref.json'
$fakeSourceRegistry = ([System.IO.File]::ReadAllText($registrySourcePath, [Text.Encoding]::UTF8)) |
    ConvertFrom-Json
$fakeSourceRegistry.requirements = @($fakeSourceRegistry.requirements) + @(
    [pscustomobject][ordered]@{
        id = 'STO-FAKE-EXTRA'
        source_ref = 'STO-FAKE-EXTRA'
        disposition = 'formal'
        scope = 'test-only'
        verification = @()
        notes = 'Must not invent a canonical source entry.'
    }
)
[System.IO.File]::WriteAllText($fakeSourcePath, ($fakeSourceRegistry | ConvertTo-Json -Depth 30),
    (New-Object Text.UTF8Encoding($false)))
$fakeSourceResult = Invoke-CoverageGate -RequirementsPath $fakeSourcePath
$fakeSourceText = $fakeSourceResult.Text -replace '\s+', ' '
if ($fakeSourceResult.ExitCode -eq 0 -or
    $fakeSourceText -notmatch 'STO-FAKE-EXTRA\.s.*ource_ref must resolve.*canonical') {
    $failures.Add("requirements v2 fake source_ref was accepted:`n$($fakeSourceResult.Text)")
}
else { Write-Host 'PASS requirements v2 fake source_ref fails closed' }

# R0/requirements-v2: check names are data, but only a fixed engine allow-list
# is executable. A registry may never smuggle a script or shell command.
$unknownCheckPath = Join-Path $testBuild 'requirements-unknown-check.json'
$unknownCheck = ([System.IO.File]::ReadAllText($registrySourcePath, [Text.Encoding]::UTF8)) |
    ConvertFrom-Json
$programmaticRequirement = @($unknownCheck.requirements | Where-Object {
    @($_.verification | Where-Object kind -eq 'programmatic').Count -gt 0
})[0]
@($programmaticRequirement.verification | Where-Object kind -eq 'programmatic')[0].check =
    'shell.execute'
[System.IO.File]::WriteAllText($unknownCheckPath, ($unknownCheck | ConvertTo-Json -Depth 30),
    (New-Object Text.UTF8Encoding($false)))
$unknownCheckResult = Invoke-CoverageGate -RequirementsPath $unknownCheckPath
$unknownCheckText = $unknownCheckResult.Text -replace '\s+', ' '
if ($unknownCheckResult.ExitCode -eq 0 -or
    $unknownCheckText -notmatch 'uses unk.*nown programmatic check') {
    $failures.Add("unknown requirements v2 check was accepted:`n$($unknownCheckResult.Text)")
}
else { Write-Host 'PASS requirements v2 check allow-list' }

# R0/requirements-v2: every declarative check must resolve to a diagnostic
# owned by the same requirement; otherwise error text could fall back to a
# hidden handler string.
$unknownDiagnosticPath = Join-Path $testBuild 'requirements-unknown-diagnostic.json'
$unknownDiagnostic = ([System.IO.File]::ReadAllText($registrySourcePath, [Text.Encoding]::UTF8)) |
    ConvertFrom-Json
$requiredElementsCheck = @(
    (@($unknownDiagnostic.requirements | Where-Object id -eq 'STO-6')[0]).verification |
        Where-Object check -eq 'document.required-elements'
)[0]
$requiredElementsCheck.diagnostic = 'STO-6/UNKNOWN_DIAGNOSTIC'
[System.IO.File]::WriteAllText(
    $unknownDiagnosticPath,
    ($unknownDiagnostic | ConvertTo-Json -Depth 30),
    (New-Object Text.UTF8Encoding($false))
)
$unknownDiagnosticResult = Invoke-CoverageGate -RequirementsPath $unknownDiagnosticPath
$unknownDiagnosticText = $unknownDiagnosticResult.Text -replace '\s+', ' '
if ($unknownDiagnosticResult.ExitCode -eq 0 -or
    $unknownDiagnosticText -notmatch 'references unknown diagnostic') {
    $failures.Add("unknown requirements v2 diagnostic was accepted:`n$($unknownDiagnosticResult.Text)")
}
else { Write-Host 'PASS requirements v2 diagnostic lookup fails closed' }

# R0/requirements-v2: declarative ordering is validated as an acyclic graph.
$cyclePath = Join-Path $testBuild 'requirements-order-cycle.json'
$cycle = ([System.IO.File]::ReadAllText($registrySourcePath, [Text.Encoding]::UTF8)) | ConvertFrom-Json
$sto6 = @($cycle.requirements | Where-Object id -eq 'STO-6')[0]
$sto6.verification = @($sto6.verification) + @([pscustomobject][ordered]@{
    kind = 'programmatic'
    check = 'document.element-order'
    parameters = [pscustomobject][ordered]@{ first = 'conclusion'; then = 'introduction' }
    diagnostic = 'STO-6/ELEMENT_ORDER'
    severity = 'error'
})
[System.IO.File]::WriteAllText($cyclePath, ($cycle | ConvertTo-Json -Depth 30),
    (New-Object Text.UTF8Encoding($false)))
$cycleResult = Invoke-CoverageGate -RequirementsPath $cyclePath
if ($cycleResult.ExitCode -eq 0 -or $cycleResult.Text -notmatch 'contain a cycle') {
    $failures.Add("cyclic document.element-order was accepted:`n$($cycleResult.Text)")
}
else { Write-Host 'PASS requirements v2 element-order cycle fails closed' }

# STO-AI-GATE: deleting one semantic rule must be reported as an exact-set
# violation even though other strict-review fields are also intentionally open.
$semanticSourcePath = Join-Path $testBuild 'semantic-review-generated.yaml'
$externalSourcePath = Join-Path $testBuild 'external-acceptance-generated.yaml'
Remove-Item -LiteralPath $semanticSourcePath, $externalSourcePath -Force -ErrorAction SilentlyContinue
New-AutoNormoKontrolReviewJournals `
    -Contract $requirementContract `
    -DocumentType ([string]$profileConfig.document_type) `
    -SemanticPath $semanticSourcePath `
    -ExternalPath $externalSourcePath
$semanticMissingPath = Join-Path $testBuild 'semantic-review-missing-rule.yaml'
$semanticText = [System.IO.File]::ReadAllText($semanticSourcePath, [System.Text.Encoding]::UTF8)
$semanticPattern = '(?ms)^    - id: "STO-5\.1"\r?\n.*?(?=^    - id: )'
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
$externalPattern = '(?ms)^    - id: "STO-1"\r?\n.*?(?=^    - id: )'
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

# R0/requirements-v2, STO-AI-GATE: generated exact sets are immutable build
# data. A mutated effective contract cannot silently change a review journal.
$inventoryMissingPath = Join-Path $testBuild 'review-inventory-missing-id.yaml'
$inventoryText = [System.IO.File]::ReadAllText($reviewInventoryPath, [System.Text.Encoding]::UTF8)
$inventoryMissing = [regex]::Replace(
    $inventoryText,
    '(?m)^    - "STO-5\.1"\r?\n',
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
    Write-Host 'PASS generated review inventory exact-set mutation -> STO-AI-GATE'
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
