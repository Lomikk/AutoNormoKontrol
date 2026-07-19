[CmdletBinding()]
param([string]$EngineRoot = '')

$ErrorActionPreference = 'Stop'
$profileId = 'susu-referat-v1'
if ([string]::IsNullOrWhiteSpace($EngineRoot)) {
    $EngineRoot = Join-Path $PSScriptRoot '..\..\..'
}
$engine = [System.IO.Path]::GetFullPath($EngineRoot).TrimEnd('\', '/')
$launcher = Join-Path $engine 'AutoNormoKontrol.cmd'
$workspaces = Join-Path $engine 'Workspaces'
$name = 'Referat smoke ' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$workspace = Join-Path $workspaces $name
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Assert-Referat([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Invoke-Cli([string]$File, [string[]]$Arguments, [string]$Directory) {
    $previous = Get-Location
    $oldPreference = $ErrorActionPreference
    try {
        Set-Location -LiteralPath $Directory
        $ErrorActionPreference = 'Continue'
        $messages = @(& $File @Arguments 2>&1)
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = if ($?) { 0 } else { 1 } }
        return [pscustomobject]@{ ExitCode = [int]$code; Text = ($messages | Out-String) }
    }
    finally {
        $ErrorActionPreference = $oldPreference
        Set-Location -LiteralPath $previous
    }
}

try {
    $created = Invoke-Cli $launcher @('new', '--profile', $profileId, $name) $engine
    Assert-Referat ($created.ExitCode -eq 0) ("Referat new failed:`n" + $created.Text)
    $local = Join-Path $workspace 'AutoNormoKontrol.cmd'
    $draft = Invoke-Cli $local @('draft', '--quiet') $workspace
    Assert-Referat ($draft.ExitCode -eq 0) ("Referat Draft failed:`n" + $draft.Text)
    Assert-Referat (Test-Path -LiteralPath (Join-Path $workspace 'build/referat.pdf')) `
        'Referat PDF was not created.'

    # STO17-4.2.1: the shared required-elements module rejects a missing
    # introduction using the profile-owned diagnostic.
    $introPath = Join-Path $workspace 'content/00-introduction.md'
    $intro = [System.IO.File]::ReadAllText($introPath, [Text.Encoding]::UTF8)
    $introLines = @($intro -split "`r?`n")
    $introLines[0] = '# Overview'
    [System.IO.File]::WriteAllText(
        $introPath, ($introLines -join "`n"), $utf8)
    $missing = Invoke-Cli $local @('draft', '--quiet') $workspace
    Assert-Referat ($missing.ExitCode -ne 0 -and
        $missing.Text.Contains('STO17-4.2.1/MISSING_REQUIRED_ELEMENT')) `
        ("Missing introduction did not fail with its diagnostic:`n" + $missing.Text)
    [System.IO.File]::WriteAllText($introPath, $intro, $utf8)

    # STO17-4.2.1: the same module reads chapter order from project.yaml and
    # rejects main matter placed before the introduction.
    $projectPath = Join-Path $workspace 'project.yaml'
    $project = [System.IO.File]::ReadAllText($projectPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $items = @($project.document.content)
    $items[0], $items[1] = $items[1], $items[0]
    $project.document.content = $items
    [System.IO.File]::WriteAllText($projectPath, ($project | ConvertTo-Json -Depth 10), $utf8)
    $order = Invoke-Cli $local @('draft', '--quiet') $workspace
    Assert-Referat ($order.ExitCode -ne 0 -and
        $order.Text.Contains('STO17-4.2.1/ELEMENT_ORDER')) `
        ("Invalid element order did not fail with its diagnostic:`n" + $order.Text)

    Write-Host 'PASS susu-referat-v1: new, draft and shared structure failures'
    exit 0
}
catch {
    Write-Error ("Referat profile smoke failed: {0}" -f $_.Exception.Message)
    exit 1
}
finally {
    if (Test-Path -LiteralPath $workspace -PathType Container) {
        $full = [System.IO.Path]::GetFullPath($workspace)
        $prefix = [System.IO.Path]::GetFullPath($workspaces).TrimEnd('\', '/') +
            [System.IO.Path]::DirectorySeparatorChar
        if ($full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $full -Recurse -Force
        }
    }
}
