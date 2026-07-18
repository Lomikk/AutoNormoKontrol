# R0/maintainability: disposable workspace, registered profile and UTF-8 integration.
# Dot-sourced by test-compliance.ps1; this is the intentionally expensive suite.

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

# R4/profile-conformance-spike: trusted profiles may provide a self-contained
# tests/run.ps1. The engine discovers runners only through catalog manifests;
# unregistered profile directories are never executed.
$profileCatalog = Get-AutoNormoKontrolProfileCatalog -Root $root
foreach ($entry in @($profileCatalog.Entries)) {
    $profileDirectory = Split-Path -Parent $entry.Profile.ManifestFullPath
    $profileTestRunner = Join-Path $profileDirectory 'tests/run.ps1'
    if (-not (Test-Path -LiteralPath $profileTestRunner -PathType Leaf)) {
        continue
    }

    $profileTest = Invoke-PowerShellFile -ScriptPath $profileTestRunner `
        -Arguments @('-EngineRoot', $root)
    if ($profileTest.ExitCode -ne 0) {
        $failures.Add(("Profile test failed for {0}:`n{1}" -f
            $entry.Id, $profileTest.Text))
    }
    else {
        Write-Host ("PASS profile test: {0}" -f $entry.Id)
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
