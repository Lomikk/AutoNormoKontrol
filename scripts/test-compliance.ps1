[CmdletBinding()]
param(
    [switch]$SkipCoverage,
    [ValidateSet(
        'all',
        'fast',
        'profile-contract',
        'static-render-contract',
        'semantic-validator',
        'build-assets',
        'engine-cli',
        'engine-integration'
    )]
    [string]$Suite = 'all'
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

if (-not $SkipCoverage -and $Suite -in @('all', 'fast')) {
    & (Join-Path $PSScriptRoot 'check-coverage.ps1') -ProfilePath $profileRelativePath
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

$pandoc = $null
if ($Suite -in @('all', 'fast', 'semantic-validator', 'engine-integration')) {
    $pandocPath = try { Resolve-PandocExecutable } catch { $null }
    if ($null -eq $pandocPath) {
        Write-Error 'pandoc was not found in PATH or a standard Windows installation directory.'
        exit 1
    }
    $pandoc = [pscustomobject]@{ Source = $pandocPath }
}

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

if ($Suite -in @('all', 'fast', 'semantic-validator', 'engine-integration') -and
    -not (Test-Path -LiteralPath $basePath -PathType Leaf)) {
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

function Complete-ComplianceTestRun {
    $testBuildFull = [System.IO.Path]::GetFullPath($testBuild)
    $expectedTestBuild = [System.IO.Path]::GetFullPath(
        (Join-Path $root 'build/compliance-tests')
    )
    if ($testBuildFull.Equals($expectedTestBuild, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $testBuildFull -PathType Container)) {
        Remove-Item -LiteralPath $testBuildFull -Recurse -Force
    }
    $engineBuild = Join-Path $root 'build'
    if ((Test-Path -LiteralPath $engineBuild -PathType Container) -and
        @(Get-ChildItem -Force -LiteralPath $engineBuild).Count -eq 0) {
        Remove-Item -LiteralPath $engineBuild -Force
    }

    if ($failures.Count -gt 0) {
        Write-Host ('Compliance tests failed: {0} problem(s).' -f $failures.Count) -ForegroundColor Red
        foreach ($failure in $failures) { Write-Host ('  - ' + $failure) }
        exit 1
    }

    if ($Suite -eq 'all') {
        Write-Host 'All compliance validator tests passed.' -ForegroundColor Green
    }
    else {
        Write-Host ("Compliance test suite passed: $Suite") -ForegroundColor Green
    }
    exit 0
}

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

# R0/maintainability: profile resolver, catalog and schema tests are isolated so
# engine-only work does not require loading every normative fixture.
if ($Suite -in @('all', 'fast', 'profile-contract')) {
    . (Join-Path $PSScriptRoot 'tests/profile-contract.tests.ps1')
}

if ($Suite -eq 'profile-contract') {
    Complete-ComplianceTestRun
}
# R0/maintainability: exact source-level renderer assertions are isolated from
# semantic fixtures and the profile resolver contract.
if ($Suite -in @('all', 'fast', 'static-render-contract')) {
    . (Join-Path $PSScriptRoot 'tests/static-render-contract.tests.ps1')
}

if ($Suite -eq 'static-render-contract') {
    Complete-ComplianceTestRun
}
# R0/maintainability: semantic Pandoc fixtures are isolated from source-text
# assertions and asset/lifecycle integration tests.
if ($Suite -in @('all', 'fast', 'semantic-validator')) {
    . (Join-Path $PSScriptRoot 'tests/semantic-validator.tests.ps1')
}

if ($Suite -eq 'semantic-validator') {
    Complete-ComplianceTestRun
}
# R0/maintainability: asset and document-snapshot contracts form one suite.
if ($Suite -in @('all', 'fast', 'build-assets')) {
    . (Join-Path $PSScriptRoot 'tests/build-assets.tests.ps1')
}

if ($Suite -eq 'build-assets') {
    Complete-ComplianceTestRun
}
# R0/maintainability: public CLI structure and wrong-mode behavior are isolated
# from the expensive disposable-workspace lifecycle.
if ($Suite -in @('all', 'fast', 'engine-cli')) {
    . (Join-Path $PSScriptRoot 'tests/engine-cli.tests.ps1')
}

if ($Suite -in @('fast', 'engine-cli')) {
    Complete-ComplianceTestRun
}
# R0/maintainability: expensive end-to-end checks remain last in the full run.
if ($Suite -in @('all', 'engine-integration')) {
    . (Join-Path $PSScriptRoot 'tests/engine-integration.tests.ps1')
}

if ($Suite -eq 'engine-integration') {
    Complete-ComplianceTestRun
}
Complete-ComplianceTestRun
