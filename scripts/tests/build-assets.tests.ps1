# R0/maintainability: asset builder, snapshot and build wiring tests.
# Dot-sourced by test-compliance.ps1; generated data stays below build/.

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
    $assetFixtureRoot = Join-Path $root 'tests/fixtures/asset-pipeline'
    Copy-Item -LiteralPath (Join-Path $assetFixtureRoot 'assets/manifest.json') `
        -Destination (Join-Path $assetTestRootFull 'assets/manifest.json')
    Copy-Item -LiteralPath (Join-Path $assetFixtureRoot 'assets/data/extraction.csv') `
        -Destination (Join-Path $assetTestRootFull 'assets/data/extraction.csv')
    Copy-Item -LiteralPath (Join-Path $assetFixtureRoot 'assets/plots/extraction.tex') `
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
