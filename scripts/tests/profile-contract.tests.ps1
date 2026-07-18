# R0/maintainability: this suite is dot-sourced by test-compliance.ps1.
# Required runner context: $root, $profileRelativePath, $activeProfileId,
# $profileConfig, $testBuild, $failures, Get-SourceText and profile.ps1 functions.
# Keep profile resolver/catalog/schema tests here; do not add STO rendering
# fixtures or workspace lifecycle scenarios to this file.

# R2/profile-contract: the active document profile is an exact, versioned and
# fail-closed build input. Test manifests live below build/ and cannot become
# an implicit alternative profile.
$profileFullPath = Join-Path $root $profileRelativePath
$profileSchemaPath = Join-Path $root 'schemas/profile-v2.schema.json'
$profileCatalogSchemaPath = Join-Path $root 'schemas/profile-catalog-v1.schema.json'
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

# R4/profile-catalog: profiles are explicitly registered trusted packages, not
# executable directories discovered by scanning the filesystem.
try {
    $catalog = Get-AutoNormoKontrolProfileCatalog -Root $root
    $catalogSchema = [System.IO.File]::ReadAllText(
        $profileCatalogSchemaPath,
        [System.Text.Encoding]::UTF8
    ) | ConvertFrom-Json
    $catalogDocument = [System.IO.File]::ReadAllText(
        (Join-Path $root $catalog.CatalogPath),
        [System.Text.Encoding]::UTF8
    ) | ConvertFrom-Json
    $rootFieldsMatch = @(
        Compare-Object `
            @($catalogSchema.required | Sort-Object) `
            @($catalogDocument.PSObject.Properties.Name | Sort-Object)
    ).Count -eq 0
    $entrySchema = $catalogSchema.properties.profiles.items
    $entryFieldsMatch = @(
        Compare-Object `
            @($entrySchema.required | Sort-Object) `
            @($catalogDocument.profiles[0].PSObject.Properties.Name | Sort-Object)
    ).Count -eq 0
    $defaultEntries = @($catalog.Entries | Where-Object IsDefault)
    if (-not $rootFieldsMatch -or -not $entryFieldsMatch -or
        $catalogSchema.additionalProperties -ne $false -or
        $entrySchema.additionalProperties -ne $false -or
        $defaultEntries.Count -ne 1 -or
        $defaultEntries[0].Manifest -cne $profileRelativePath) {
        $failures.Add('R4 profile catalog schema/default contract is inconsistent')
    }
    else {
        Write-Host 'PASS R4 explicit profile catalog and default pointer contract'
    }

    $unknownProfileFailed = $false
    try {
        [void](Get-AutoNormoKontrolCatalogProfile `
            -Root $root -ProfileId 'missing-profile-v2')
    }
    catch { $unknownProfileFailed = $_.Exception.Message -match 'not registered' }
    if (-not $unknownProfileFailed) {
        $failures.Add('R4 profile catalog accepted an unregistered profile id')
    }
    else {
        Write-Host 'PASS R4 unregistered profile id fails closed'
    }
}
catch {
    $failures.Add("R4 profile catalog could not be validated: $($_.Exception.Message)")
}

try {
    $schema = [System.IO.File]::ReadAllText(
        $profileSchemaPath,
        [System.Text.Encoding]::UTF8
    ) | ConvertFrom-Json
    $manifest = Get-ProfileTestDocument
    $schemaSections = @('<root>', 'starter', 'inputs', 'compliance', 'render', 'assets',
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
    'profiles/missing-profile-v2/profile.yaml',
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
    [string]$profileConfig.compliance.requirements,
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
$inventoryPath = ([string]$profileConfig.compliance.inventory).Replace('\', '/')
if (-not $inventoryPath.StartsWith('sources/', [StringComparison]::Ordinal)) {
    $failures.Add("R3 canonical inventory is not source-owned: $inventoryPath")
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
$unsupportedVersionProfile.schema_version = 3
Assert-ProfileFailure -Name 'unsupported-version' -Document $unsupportedVersionProfile `
    -Expected 'Unsupported profile schema_version: 3'

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
    [string]@($profileConfig.starter.content)[0]
)) {
    if ($buildProfileText.Contains($forbiddenLiteral)) {
        $failures.Add("R2 build integration contract: profile path remains hard-coded: $forbiddenLiteral")
    }
}
if ($failures.Count -eq 0) {
    Write-Host 'PASS R2 build integration uses the resolved profile'
}
