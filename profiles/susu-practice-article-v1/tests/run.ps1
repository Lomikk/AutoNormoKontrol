[CmdletBinding()]
param(
    [string]$EngineRoot = ''
)

$ErrorActionPreference = 'Stop'
$profileId = 'susu-practice-article-v1'

if ([string]::IsNullOrWhiteSpace($EngineRoot)) {
    $EngineRoot = Join-Path $PSScriptRoot '..\..\..'
}
$engineFull = [System.IO.Path]::GetFullPath($EngineRoot).TrimEnd('\', '/')
$launcher = Join-Path $engineFull 'AutoNormoKontrol.cmd'
$workspacesRoot = Join-Path $engineFull 'Workspaces'
$workspaceName = 'Article smoke ' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$workspaceRoot = Join-Path $workspacesRoot $workspaceName

function Assert-ArticleProfile {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-ArticleCli {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    $previousLocation = Get-Location
    $previousPreference = $ErrorActionPreference
    try {
        Set-Location -LiteralPath $WorkingDirectory
        $ErrorActionPreference = 'Continue'
        $messages = @(& $FilePath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode) { $exitCode = if ($?) { 0 } else { 1 } }
        return [pscustomobject]@{
            ExitCode = [int]$exitCode
            Text = ($messages | Out-String)
        }
    }
    finally {
        $ErrorActionPreference = $previousPreference
        Set-Location -LiteralPath $previousLocation
    }
}

try {
    Assert-ArticleProfile (Test-Path -LiteralPath $launcher -PathType Leaf) `
        "Central launcher was not found: $launcher"

    $created = Invoke-ArticleCli -FilePath $launcher `
        -Arguments @('new', '--profile', $profileId, $workspaceName) `
        -WorkingDirectory $engineFull
    Assert-ArticleProfile ($created.ExitCode -eq 0) `
        ("Article new failed:`n" + $created.Text)

    $projectPath = Join-Path $workspaceRoot 'project.yaml'
    $project = Get-Content -Raw -Encoding UTF8 -LiteralPath $projectPath | ConvertFrom-Json
    Assert-ArticleProfile ([string]$project.profile.id -ceq $profileId) `
        'Article workspace pinned another profile.'

    $localLauncher = Join-Path $workspaceRoot 'AutoNormoKontrol.cmd'
    $draft = Invoke-ArticleCli -FilePath $localLauncher `
        -Arguments @('draft') -WorkingDirectory $workspaceRoot
    Assert-ArticleProfile ($draft.ExitCode -eq 0) `
        ("Article Draft failed:`n" + $draft.Text)

    $profilePath = Join-Path $engineFull 'profiles/susu-practice-article-v1/profile.yaml'
    $profile = Get-Content -Raw -Encoding UTF8 -LiteralPath $profilePath | ConvertFrom-Json
    $buildReportPath = Join-Path $workspaceRoot ([string]$profile.reports.build_report)
    $postflightPath = Join-Path $workspaceRoot ([string]$profile.reports.postflight)
    $buildReport = Get-Content -Raw -Encoding UTF8 -LiteralPath $buildReportPath | ConvertFrom-Json
    $postflight = Get-Content -Raw -Encoding UTF8 -LiteralPath $postflightPath | ConvertFrom-Json
    $builtPdf = Join-Path $workspaceRoot ([string]$profile.outputs.pdf)

    Assert-ArticleProfile ([string]$buildReport.mode -ceq 'draft') `
        'Article build report does not describe a Draft.'
    Assert-ArticleProfile ([string]$buildReport.profile_id -ceq $profileId) `
        'Article build report belongs to another profile.'
    Assert-ArticleProfile ([string]$postflight.status -ceq 'pass') `
        'Article postflight does not use the shared pass status.'
    Assert-ArticleProfile ($postflight.PSObject.Properties.Name -contains 'pages' -and
        [int]$postflight.pages -gt 0) `
        'Article postflight does not expose a positive top-level page count.'
    Assert-ArticleProfile (Test-Path -LiteralPath $builtPdf -PathType Leaf) `
        'Article Draft PDF was not created.'

    $status = Invoke-ArticleCli -FilePath $localLauncher `
        -Arguments @('status') -WorkingDirectory $workspaceRoot
    Assert-ArticleProfile ($status.ExitCode -eq 0 -and
        $status.Text -match 'PDF postflight:\s+pass\s+\([1-9][0-9]*\s+') `
        ("Article status did not show the postflight page count:`n" + $status.Text)

    $strict = Invoke-ArticleCli -FilePath $localLauncher `
        -Arguments @('strict') -WorkingDirectory $workspaceRoot
    Assert-ArticleProfile ($strict.ExitCode -ne 0 -and
        $strict.Text.Contains('ARTICLE-STRICT-UNSUPPORTED')) `
        ("Experimental Article Strict did not fail with its stable code:`n" + $strict.Text)

    $export = Invoke-ArticleCli -FilePath $localLauncher `
        -Arguments @('export') -WorkingDirectory $workspaceRoot
    $published = Join-Path $workspaceRoot 'output/document.pdf'
    Assert-ArticleProfile ($export.ExitCode -eq 0 -and
        (Test-Path -LiteralPath $published -PathType Leaf)) `
        ("Article export failed:`n" + $export.Text)
    $builtHash = (Get-FileHash -LiteralPath $builtPdf -Algorithm SHA256).Hash
    $publishedHash = (Get-FileHash -LiteralPath $published -Algorithm SHA256).Hash
    Assert-ArticleProfile ($builtHash -ceq $publishedHash) `
        'Published article differs from its verified Draft PDF.'

    $archive = Invoke-ArticleCli -FilePath $localLauncher `
        -Arguments @('archive', 'profile-smoke') -WorkingDirectory $workspaceRoot
    $archiveDirectory = Join-Path $workspaceRoot 'output/archive'
    Assert-ArticleProfile ($archive.ExitCode -eq 0 -and
        @(Get-ChildItem -LiteralPath $archiveDirectory -Filter '*.pdf' -File).Count -eq 1) `
        ("Article archive failed:`n" + $archive.Text)

    Write-Host 'PASS susu-practice-article-v1: new -> draft -> status -> strict(blocked) -> export -> archive'
    exit 0
}
catch {
    Write-Error ("Article profile smoke failed: {0}" -f $_.Exception.Message)
    exit 1
}
finally {
    if (Test-Path -LiteralPath $workspaceRoot -PathType Container) {
        $workspaceFull = [System.IO.Path]::GetFullPath($workspaceRoot)
        $allowedPrefix = [System.IO.Path]::GetFullPath($workspacesRoot).TrimEnd('\', '/') +
            [System.IO.Path]::DirectorySeparatorChar
        if ($workspaceFull.StartsWith($allowedPrefix, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Parent $workspaceFull).Equals(
                [System.IO.Path]::GetFullPath($workspacesRoot),
                [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $workspaceFull -Recurse -Force
        }
    }
}
