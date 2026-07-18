# R0/maintainability: central/workspace CLI mode and installer contracts.
# Dot-sourced by test-compliance.ps1; no document lifecycle is built here.

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

    # R1/workspace-only: the central launcher manages the engine. Document
    # commands are accepted only through a thin launcher in a real workspace.
    $rootDocumentArtifacts = @(
        'build/coursework.pdf',
        'build/coursework.tex',
        'build/build-report.json',
        'build/document-snapshot.json',
        'build/compliance-report.json',
        'output/document.pdf',
        'output/export-report.json'
    )
    $rootArtifactState = @{}
    foreach ($relative in $rootDocumentArtifacts) {
        $full = Join-Path $root $relative
        $rootArtifactState[$relative] = if (Test-Path -LiteralPath $full -PathType Leaf) {
            (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
        }
        else { '<missing>' }
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

        $centralWrongModeResults = [ordered]@{}
        foreach ($workspaceOnlyCommand in @(
            'draft', 'strict', 'status', 'open', 'export', 'archive'
        )) {
            $commandOutput = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
                -File $cliPath $workspaceOnlyCommand 2>&1)
            $centralWrongModeResults[$workspaceOnlyCommand] = [pscustomobject]@{
                ExitCode = $LASTEXITCODE
                Text = ($commandOutput | Out-String)
            }
        }

        $buildWithoutWorkspace = @(& powershell.exe -NoLogo -NoProfile -NonInteractive `
            -ExecutionPolicy Bypass -File (Join-Path $root 'scripts/build.ps1') 2>&1)
        $buildWithoutWorkspaceExitCode = $LASTEXITCODE
        $buildAtEngineRoot = @(& powershell.exe -NoLogo -NoProfile -NonInteractive `
            -ExecutionPolicy Bypass -File (Join-Path $root 'scripts/build.ps1') `
            -WorkspaceRoot $root 2>&1)
        $buildAtEngineRootExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    $helpText = $helpOutput | Out-String
    $actualCentralCommands = @([regex]::Matches(
        $helpText,
        '(?m)^\s{2}([a-z][a-z0-9-]*)(?:\s+\[[^]]+\])?\s{2,}'
    ) | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $expectedCentralCommands = @(
        'new', 'list-profiles', 'check', 'doctor', 'install', 'help'
    ) | Sort-Object
    if ($helpExitCode -ne 0 -or
        @(Compare-Object $expectedCentralCommands $actualCentralCommands).Count -ne 0) {
        $failures.Add(("CLI central help must expose exactly [{0}], got [{1}]`n{2}" -f
            ($expectedCentralCommands -join ', '), ($actualCentralCommands -join ', '), $helpText))
    }
    if ($invalidExitCode -ne 2) {
        $failures.Add(('CLI smoke contract: unknown command returned {0}, expected 2' -f
            $invalidExitCode))
    }
    foreach ($entry in $centralWrongModeResults.GetEnumerator()) {
        if ($entry.Value.ExitCode -ne 2 -or
            $entry.Value.Text -notmatch '(?i)workspace') {
            $failures.Add(("CLI central mode accepted workspace command '{0}' or omitted " +
                "a mode diagnostic (exit {1}):`n{2}" -f
                $entry.Key, $entry.Value.ExitCode, $entry.Value.Text))
        }
    }
    if ($buildWithoutWorkspaceExitCode -eq 0) {
        $failures.Add("build.ps1 accepted a missing WorkspaceRoot:`n$($buildWithoutWorkspace | Out-String)")
    }
    if ($buildAtEngineRootExitCode -eq 0) {
        $failures.Add("build.ps1 accepted the engine root as a workspace:`n$($buildAtEngineRoot | Out-String)")
    }

    foreach ($relative in $rootDocumentArtifacts) {
        $full = Join-Path $root $relative
        $after = if (Test-Path -LiteralPath $full -PathType Leaf) {
            (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
        }
        else { '<missing>' }
        if ($after -ne $rootArtifactState[$relative]) {
            $failures.Add("central wrong-mode command modified engine-root document artifact: $relative")
        }
    }

    if ($helpExitCode -eq 0 -and $invalidExitCode -eq 2 -and
        @($centralWrongModeResults.Values | Where-Object ExitCode -ne 2).Count -eq 0 -and
        $buildWithoutWorkspaceExitCode -ne 0 -and $buildAtEngineRootExitCode -ne 0 -and
        $parseErrors.Count -eq 0) {
        Write-Host 'PASS AutoNormoKontrol central CLI mode contract'
    }

    $cliText = [System.IO.File]::ReadAllText($cliPath, [System.Text.Encoding]::UTF8)
    $checkStart = $cliText.IndexOf("'check' {", [StringComparison]::Ordinal)
    $checkEnd = if ($checkStart -ge 0) {
        $cliText.IndexOf('default {', $checkStart, [StringComparison]::Ordinal)
    }
    else { -1 }
    if ($checkStart -lt 0 -or $checkEnd -le $checkStart) {
        $failures.Add('CLI central check contract: check dispatch block was not found')
    }
    else {
        $checkDispatch = $cliText.Substring($checkStart, $checkEnd - $checkStart)
        if ($checkDispatch -notmatch 'test-compliance\.ps1' -or
            $checkDispatch -match 'build\.ps1|Get-ActiveWorkspace') {
            $failures.Add('CLI central check must run engine tests without resolving or building a document workspace')
        }
        foreach ($literal in @("'--fast'", "'-Suite', 'fast'")) {
            if (-not $checkDispatch.Contains($literal)) {
                $failures.Add("CLI central check --fast contract: missing $literal")
            }
        }
    }
    $strictStart = $cliText.IndexOf("'strict' {", [StringComparison]::Ordinal)
    $strictEnd = if ($strictStart -ge 0) {
        $cliText.IndexOf("'check' {", $strictStart, [StringComparison]::Ordinal)
    }
    else { -1 }
    if ($strictStart -lt 0 -or $strictEnd -le $strictStart) {
        $failures.Add('CLI workspace strict contract: strict dispatch block was not found')
    }
    else {
        $strictDispatch = $cliText.Substring($strictStart, $strictEnd - $strictStart)
        foreach ($literal in @(
            "Invoke-ProjectScript 'build.ps1'",
            "'-Mode', 'Strict'",
            "'-WorkspaceRoot', `$workspaceRoot",
            '-ExitCode $ExitCode'
        )) {
            if (-not $strictDispatch.Contains($literal)) {
                $failures.Add("CLI workspace strict contract: missing $literal")
            }
        }
    }
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
