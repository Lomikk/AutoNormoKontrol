[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$engineRoot = Split-Path -Parent $PSScriptRoot
$launcher = Join-Path $engineRoot 'AutoNormoKontrol.cmd'
$workspacesRoot = Join-Path $engineRoot 'Workspaces'
$workspaceName = 'Lifecycle R1 ' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$workspaceRoot = Join-Path $workspacesRoot $workspaceName
$selectedWorkspaceName = 'Selected profile ' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$selectedWorkspaceRoot = Join-Path $workspacesRoot $selectedWorkspaceName
$encoding = New-Object System.Text.UTF8Encoding($false)

. (Join-Path $PSScriptRoot 'profile.ps1')
. (Join-Path $PSScriptRoot 'workspace.ps1')

function Assert-Lifecycle {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-LifecycleCli {
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
        $output = @(& $FilePath @Arguments 2>&1)
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = if ($?) { 0 } else { 1 } }
        return [pscustomobject]@{
            ExitCode = [int]$code
            Text = ($output | Out-String)
        }
    }
    finally {
        $ErrorActionPreference = $previousPreference
        Set-Location -LiteralPath $previousLocation
    }
}

function Get-OptionalHash {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '<missing>' }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-HelpCommandNames {
    param([string]$Text)
    return @([regex]::Matches(
        $Text,
        '(?m)^\s{2}([a-z][a-z0-9-]*)\s{2,}'
    ) | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
}

function Write-WorkspaceManifest {
    param([object]$Document)
    [System.IO.File]::WriteAllText(
        (Join-Path $workspaceRoot 'project.yaml'),
        ($Document | ConvertTo-Json -Depth 10),
        $encoding
    )
}

try {
    $rootArtifacts = @(
        'build/coursework.pdf',
        'build/coursework.tex',
        'build/build-report.json',
        'build/document-snapshot.json',
        'build/compliance-report.json',
        'build/sto-traceability.json',
        'output/document.pdf',
        'output/export-report.json'
    )
    $rootHashesBefore = @{}
    foreach ($path in $rootArtifacts) {
        $rootHashesBefore[$path] = Get-OptionalHash (Join-Path $engineRoot $path)
    }

    $profilePath = Get-AutoNormoKontrolDefaultProfilePath -Root $engineRoot
    $activeProfile = Resolve-AutoNormoKontrolProfile `
        -Root $engineRoot -ProfilePath $profilePath
    $profileList = Invoke-LifecycleCli -FilePath $launcher `
        -Arguments @('list-profiles') -WorkingDirectory $engineRoot
    Assert-Lifecycle ($profileList.ExitCode -eq 0 -and
        $profileList.Text.Contains($activeProfile.ProfileId)) `
        ("list-profiles did not expose the active registered profile:`n" + $profileList.Text)

    $explicit = Invoke-LifecycleCli -FilePath $launcher `
        -Arguments @('new', '--profile', $activeProfile.ProfileId, $selectedWorkspaceName) `
        -WorkingDirectory $engineRoot
    Assert-Lifecycle ($explicit.ExitCode -eq 0) `
        ("new --profile failed:`n" + $explicit.Text)
    $explicitProject = Get-Content -Raw -Encoding UTF8 `
        -LiteralPath (Join-Path $selectedWorkspaceRoot 'project.yaml') | ConvertFrom-Json
    Assert-Lifecycle ([string]$explicitProject.profile.id -ceq $activeProfile.ProfileId) `
        'new --profile pinned another profile'

    $created = Invoke-LifecycleCli -FilePath $launcher `
        -Arguments @('new', $workspaceName) -WorkingDirectory $engineRoot
    Assert-Lifecycle ($created.ExitCode -eq 0) ("new failed:`n" + $created.Text)
    Assert-Lifecycle (Test-Path -LiteralPath $workspaceRoot -PathType Container) `
        'new did not create its workspace directory'
    Assert-Lifecycle (@(Get-ChildItem -LiteralPath $workspacesRoot -Directory -Force |
        Where-Object Name -Like '.ank-new-*').Count -eq 0) `
        'new left a staging directory behind'

    $manifestPath = Join-Path $workspaceRoot 'project.yaml'
    $requiredFiles = @(
        'project.yaml', 'AutoNormoKontrol.cmd', 'gemini.cmd', '.gitignore', 'GEMINI.md', 'AGENTS.md',
        'guide/profile-system-prompt.md',
        'metadata.yaml', 'format-spec.yaml', 'bibliography.bib', 'assets/manifest.json',
        'compliance/semantic-review.yaml', 'compliance/external-acceptance.yaml'
    )
    foreach ($relative in $requiredFiles) {
        Assert-Lifecycle (Test-Path -LiteralPath (Join-Path $workspaceRoot $relative) -PathType Leaf) `
            "starter file is missing: $relative"
    }
    $localLauncher = Join-Path $workspaceRoot 'AutoNormoKontrol.cmd'
    $geminiLauncher = Join-Path $workspaceRoot 'gemini.cmd'
    $geminiLauncherText = Get-Content -Raw -Encoding UTF8 -LiteralPath $geminiLauncher
    Assert-Lifecycle ($geminiLauncherText.Contains('where.exe gemini.cmd') -and
        $geminiLauncherText.Contains('where.exe gemini.exe') -and
        $geminiLauncherText.Contains('call "%GEMINI_CLI%" %*') -and
        $geminiLauncherText.Contains('if /I not "%%~fG"=="%~f0"') -and
        $geminiLauncherText.Contains('guide\profile-system-prompt.md') -and
        $geminiLauncherText -notmatch '(?i)api[_-]?key|--model') `
        'gemini.cmd is not a credential-free, non-recursive workspace launcher'

    # R1/workspace-only: a document launcher exposes only the document lifecycle.
    $workspaceHelp = Invoke-LifecycleCli -FilePath $localLauncher `
        -Arguments @('help') -WorkingDirectory $workspaceRoot
    $actualWorkspaceCommands = @(Get-HelpCommandNames $workspaceHelp.Text)
    $expectedWorkspaceCommands = @(
        'draft', 'strict', 'status', 'open', 'export', 'archive', 'help'
    ) | Sort-Object
    Assert-Lifecycle ($workspaceHelp.ExitCode -eq 0 -and
        @(Compare-Object $expectedWorkspaceCommands $actualWorkspaceCommands).Count -eq 0) `
        ("workspace help must expose exactly [{0}], got [{1}]`n{2}" -f
            ($expectedWorkspaceCommands -join ', '),
            ($actualWorkspaceCommands -join ', '),
            $workspaceHelp.Text)

    $wrongWorkspaceName = 'Wrong mode ' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $wrongWorkspacePath = Join-Path $workspacesRoot $wrongWorkspaceName
    $centralOnlyCases = @(
        [pscustomobject]@{ Name = 'new'; Arguments = @('new', $wrongWorkspaceName) },
        [pscustomobject]@{ Name = 'list-profiles'; Arguments = @('list-profiles') },
        [pscustomobject]@{ Name = 'check'; Arguments = @('check') },
        [pscustomobject]@{ Name = 'doctor'; Arguments = @('doctor') },
        [pscustomobject]@{ Name = 'install'; Arguments = @('install', '--yes') }
    )
    foreach ($case in $centralOnlyCases) {
        $wrongMode = Invoke-LifecycleCli -FilePath $localLauncher `
            -Arguments $case.Arguments -WorkingDirectory $workspaceRoot
        Assert-Lifecycle ($wrongMode.ExitCode -eq 2 -and
            $wrongMode.Text -match '(?i)AutoNormoKontrol[.]cmd') `
            ("workspace accepted central command '{0}' or omitted a mode diagnostic " +
                "(exit {1}):`n{2}" -f $case.Name, $wrongMode.ExitCode, $wrongMode.Text)
    }
    Assert-Lifecycle (-not (Test-Path -LiteralPath $wrongWorkspacePath)) `
        'workspace-local new created a sibling workspace'
    foreach ($forbidden in @('scripts', 'profiles', 'sources')) {
        Assert-Lifecycle (-not (Test-Path -LiteralPath (Join-Path $workspaceRoot $forbidden))) `
            "workspace contains an engine directory: $forbidden"
    }
    $metadataText = [System.IO.File]::ReadAllText(
        (Join-Path $workspaceRoot 'metadata.yaml'),
        [System.Text.Encoding]::UTF8
    )
    $expectedYear = [DateTime]::Now.Year
    Assert-Lifecycle ($metadataText -match ("(?m)^year:\s*{0}\s*$" -f $expectedYear)) `
        'new did not update starter metadata to the current year'

    $project = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
    $schema = Get-Content -Raw -Encoding UTF8 `
        -LiteralPath (Join-Path $engineRoot 'schemas/workspace-v1.schema.json') | ConvertFrom-Json
    $expectedRoot = @($schema.required | Sort-Object)
    $actualRoot = @($project.PSObject.Properties.Name | Sort-Object)
    Assert-Lifecycle (($expectedRoot -join '|') -eq ($actualRoot -join '|')) `
        'project.yaml root fields differ from workspace-v1 schema'
    $expectedDocument = @($schema.properties.document.required | Sort-Object)
    $actualDocument = @($project.document.PSObject.Properties.Name | Sort-Object)
    Assert-Lifecycle (($expectedDocument -join '|') -eq ($actualDocument -join '|')) `
        'project.yaml document fields differ from workspace-v1 schema'
    foreach ($version in @([string]$project.engine.minimum_version, [string]$project.engine.created_with)) {
        Assert-Lifecycle ($version -match '^[0-9]+\.[0-9]+\.[0-9]+$') `
            "workspace version is not x.y.z: $version"
    }

    $resolved = Resolve-AutoNormoKontrolWorkspace `
        -EngineRoot $engineRoot -WorkspaceRoot $workspaceRoot
    Assert-Lifecycle ($resolved.ProfilePath -eq $profilePath) 'workspace selected another profile'
    Assert-Lifecycle ($resolved.ProfileDigestMatches) 'new workspace pinned a different profile digest'
    Assert-Lifecycle (($resolved.ContentPaths -join '|') -eq
        (@($project.document.content) -join '|')) 'workspace changed explicit content order'
    foreach ($relative in @($project.document.content)) {
        Assert-Lifecycle (Test-Path -LiteralPath (Join-Path $workspaceRoot ([string]$relative)) -PathType Leaf) `
            "declared content file is missing: $relative"
    }

    $semanticTemplate = Join-Path $engineRoot `
        ([string]$resolved.Profile.Data.compliance.semantic_review_template)
    $externalTemplate = Join-Path $engineRoot `
        ([string]$resolved.Profile.Data.compliance.external_acceptance_template)
    $profilePrompt = Join-Path $engineRoot `
        ([string]$resolved.Profile.Data.compliance.system_prompt)
    $workspacePrompt = Join-Path $workspaceRoot 'guide/profile-system-prompt.md'
    Assert-Lifecycle ((Get-OptionalHash $semanticTemplate) -eq
        (Get-OptionalHash (Join-Path $workspaceRoot 'compliance/semantic-review.yaml'))) `
        'semantic review was not reset from the profile template'
    Assert-Lifecycle ((Get-OptionalHash $externalTemplate) -eq
        (Get-OptionalHash (Join-Path $workspaceRoot 'compliance/external-acceptance.yaml'))) `
        'external acceptance was not reset from the profile template'
    Assert-Lifecycle ((Get-OptionalHash $profilePrompt) -eq
        (Get-OptionalHash $workspacePrompt)) `
        'workspace agent prompt is not an exact profile-specific snapshot'

    $originalPromptBytes = [System.IO.File]::ReadAllBytes($workspacePrompt)
    try {
        [System.IO.File]::AppendAllText(
            $workspacePrompt,
            "`n<!-- prompt tampering probe -->`n",
            $encoding
        )
        $failed = $false
        try {
            [void](Resolve-AutoNormoKontrolWorkspace `
                -EngineRoot $engineRoot -WorkspaceRoot $workspaceRoot)
        }
        catch { $failed = $_.Exception.Message -match 'agent prompt does not match' }
        Assert-Lifecycle $failed 'modified workspace agent prompt did not fail closed'
    }
    finally {
        [System.IO.File]::WriteAllBytes($workspacePrompt, $originalPromptBytes)
    }

    $marker = Join-Path $workspaceRoot 'do-not-overwrite.marker'
    [System.IO.File]::WriteAllText($marker, 'preserve', $encoding)
    $duplicate = Invoke-LifecycleCli -FilePath $launcher `
        -Arguments @('new', $workspaceName) -WorkingDirectory $engineRoot
    Assert-Lifecycle ($duplicate.ExitCode -ne 0) 'duplicate new unexpectedly succeeded'
    Assert-Lifecycle ((Get-Content -Raw -LiteralPath $marker) -eq 'preserve') `
        'duplicate new modified the existing workspace'

    foreach ($invalidName in @('..', 'CON.txt', 'nested/name')) {
        $failed = $false
        try { [void](Assert-WorkspaceName -Name $invalidName) }
        catch { $failed = $true }
        Assert-Lifecycle $failed "unsafe workspace name was accepted: $invalidName"
    }

    $originalManifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath
    try {
        $invalid = $originalManifest | ConvertFrom-Json
        $invalid.document | Add-Member -NotePropertyName unexpected -NotePropertyValue $true
        Write-WorkspaceManifest $invalid
        $failed = $false
        try {
            [void](Resolve-AutoNormoKontrolWorkspace `
                -EngineRoot $engineRoot -WorkspaceRoot $workspaceRoot)
        }
        catch { $failed = $_.Exception.Message -match 'unknown field' }
        Assert-Lifecycle $failed 'unknown workspace field did not fail closed'

        $invalid = $originalManifest | ConvertFrom-Json
        $invalid.engine.minimum_version = '1.0'
        Write-WorkspaceManifest $invalid
        $failed = $false
        try {
            [void](Resolve-AutoNormoKontrolWorkspace `
                -EngineRoot $engineRoot -WorkspaceRoot $workspaceRoot)
        }
        catch { $failed = $_.Exception.Message -match 'semantic x.y.z' }
        Assert-Lifecycle $failed 'workspace version 1.0 did not fail closed'

        $invalid = $originalManifest | ConvertFrom-Json
        $invalid.schema_version = '1'
        Write-WorkspaceManifest $invalid
        $failed = $false
        try {
            [void](Resolve-AutoNormoKontrolWorkspace `
                -EngineRoot $engineRoot -WorkspaceRoot $workspaceRoot)
        }
        catch { $failed = $_.Exception.Message -match 'schema_version' }
        Assert-Lifecycle $failed 'string workspace schema_version did not fail closed'

        $invalid = $originalManifest | ConvertFrom-Json
        $invalid.profile.digest = ([string]$invalid.profile.digest).ToUpperInvariant()
        Write-WorkspaceManifest $invalid
        $failed = $false
        try {
            [void](Resolve-AutoNormoKontrolWorkspace `
                -EngineRoot $engineRoot -WorkspaceRoot $workspaceRoot)
        }
        catch { $failed = $_.Exception.Message -match 'lowercase' }
        Assert-Lifecycle $failed 'uppercase workspace profile digest did not fail closed'
    }
    finally {
        [System.IO.File]::WriteAllText($manifestPath, $originalManifest, $encoding)
    }

    $versionMismatch = $originalManifest | ConvertFrom-Json
    $versionMismatch.engine.created_with = '0.0.0'
    Write-WorkspaceManifest $versionMismatch
    try {
        $mismatchedWorkspace = Resolve-AutoNormoKontrolWorkspace `
            -EngineRoot $engineRoot -WorkspaceRoot $workspaceRoot
        Assert-Lifecycle (-not $mismatchedWorkspace.EngineVersionMatches) `
            'workspace created_with mismatch was not exposed by the resolver'
        Assert-Lifecycle ($mismatchedWorkspace.CreatedWithEngineVersion -eq '0.0.0') `
            'resolver lost the workspace created_with version'
        $mismatchStatus = Invoke-LifecycleCli -FilePath (Join-Path $workspaceRoot 'AutoNormoKontrol.cmd') `
            -Arguments @('status') -WorkingDirectory $engineRoot
        Assert-Lifecycle ($mismatchStatus.ExitCode -eq 0 -and
            $mismatchStatus.Text.Contains('0.0.0') -and
            $mismatchStatus.Text.Contains($mismatchedWorkspace.EngineVersion)) `
            'status did not report both saved and current engine versions'
    }
    finally {
        [System.IO.File]::WriteAllText($manifestPath, $originalManifest, $encoding)
    }

    foreach ($command in @('export', 'archive')) {
        $beforeBuild = Invoke-LifecycleCli -FilePath $localLauncher `
            -Arguments @($command) -WorkingDirectory $engineRoot
        Assert-Lifecycle ($beforeBuild.ExitCode -ne 0) `
            "$command unexpectedly succeeded before the first Draft"
    }
    Assert-Lifecycle (-not (Test-Path -LiteralPath `
        (Join-Path $workspaceRoot 'output/document.pdf') -PathType Leaf)) `
        'pre-build publish created output/document.pdf'

    # The starter is intentionally not accepted for release. This call proves
    # that the public strict command reaches build.ps1 in Strict mode and that
    # the compliance gates, not a broken CLI dispatch, reject it.
    $strictBeforeAcceptance = Invoke-LifecycleCli -FilePath $localLauncher `
        -Arguments @('strict') -WorkingDirectory $engineRoot
    Assert-Lifecycle ($strictBeforeAcceptance.ExitCode -ne 0 -and
        $strictBeforeAcceptance.Text -match 'STO-(AI|EXT)-GATE') `
        ("starter Strict did not fail through a compliance gate:`n" +
            $strictBeforeAcceptance.Text)

    $draft = Invoke-LifecycleCli -FilePath $localLauncher `
        -Arguments @('draft') -WorkingDirectory $engineRoot
    Assert-Lifecycle ($draft.ExitCode -eq 0) ("workspace Draft failed:`n" + $draft.Text)
    foreach ($relative in @(
        'build/coursework.pdf', 'build/build-report.json',
        'build/compliance-report.json', 'build/document-snapshot.json',
        'build/sto-traceability.json'
    )) {
        Assert-Lifecycle (Test-Path -LiteralPath (Join-Path $workspaceRoot $relative) -PathType Leaf) `
            "Draft output is missing from workspace: $relative"
    }
    foreach ($path in $rootArtifacts) {
        Assert-Lifecycle ($rootHashesBefore[$path] -eq (Get-OptionalHash (Join-Path $engineRoot $path))) `
            "workspace Draft modified engine artifact: $path"
    }

    $buildReport = Get-Content -Raw -Encoding UTF8 `
        -LiteralPath (Join-Path $workspaceRoot 'build/build-report.json') | ConvertFrom-Json
    $postflight = Get-Content -Raw -Encoding UTF8 `
        -LiteralPath (Join-Path $workspaceRoot 'build/compliance-report.json') | ConvertFrom-Json
    $builtPdf = Join-Path $workspaceRoot ([string]$buildReport.output.path)
    Assert-Lifecycle ([string]$buildReport.mode -eq 'draft') 'starter build was not Draft'
    Assert-Lifecycle ([string]$postflight.status -eq 'pass') 'starter PDF postflight did not pass'
    Assert-Lifecycle ((Get-OptionalHash $builtPdf) -eq ([string]$buildReport.output.sha256)) `
        'built PDF hash differs from build report'

    $export = Invoke-LifecycleCli -FilePath $localLauncher `
        -Arguments @('export') -WorkingDirectory $engineRoot
    Assert-Lifecycle ($export.ExitCode -eq 0) ("export failed:`n" + $export.Text)
    $published = Join-Path $workspaceRoot 'output/document.pdf'
    Assert-Lifecycle ((Get-OptionalHash $published) -eq (Get-OptionalHash $builtPdf)) `
        'published PDF differs from verified build'
    $publishedHash = Get-OptionalHash $published
    $exportReport = Get-Content -Raw -Encoding UTF8 `
        -LiteralPath (Join-Path $workspaceRoot 'output/export-report.json') | ConvertFrom-Json
    Assert-Lifecycle ([string]$exportReport.mode -eq 'draft' -and
        [string]$exportReport.profile_id -eq $resolved.Profile.ProfileId -and
        [string]$exportReport.content_hash -eq [string]$buildReport.content_hash -and
        [string]$exportReport.output.sha256 -eq $publishedHash) `
        'export report does not describe the published Draft'

    $exportAgain = Invoke-LifecycleCli -FilePath $localLauncher `
        -Arguments @('export') -WorkingDirectory $engineRoot
    Assert-Lifecycle ($exportAgain.ExitCode -eq 0) 'repeated export failed'
    Assert-Lifecycle ((Get-OptionalHash $published) -eq $publishedHash) `
        'repeated export changed PDF bytes'

    $snapshotPath = Join-Path $workspaceRoot 'build/document-snapshot.json'
    $originalSnapshot = [System.IO.File]::ReadAllText(
        $snapshotPath,
        [System.Text.Encoding]::UTF8
    )
    $truncatedSnapshot = $originalSnapshot | ConvertFrom-Json
    $truncatedSnapshot.files = @($truncatedSnapshot.files | Select-Object -Skip 1)
    [System.IO.File]::WriteAllText(
        $snapshotPath,
        ($truncatedSnapshot | ConvertTo-Json -Depth 10),
        $encoding
    )
    try {
        $truncatedExport = Invoke-LifecycleCli -FilePath $localLauncher `
            -Arguments @('export') -WorkingDirectory $engineRoot
        Assert-Lifecycle ($truncatedExport.ExitCode -ne 0) `
            'export trusted a truncated document snapshot'
        Assert-Lifecycle ((Get-OptionalHash $published) -eq $publishedHash) `
            'failed truncated-snapshot export modified the published PDF'
    }
    finally {
        [System.IO.File]::WriteAllText($snapshotPath, $originalSnapshot, $encoding)
    }

    $archive = Invoke-LifecycleCli -FilePath $localLauncher `
        -Arguments @('archive', 'acceptance') -WorkingDirectory $engineRoot
    Assert-Lifecycle ($archive.ExitCode -eq 0) ("archive failed:`n" + $archive.Text)
    $archivePath = Join-Path $workspaceRoot `
        ('output/archive/document-acceptance-draft-{0}.pdf' -f $publishedHash.Substring(0, 8))
    Assert-Lifecycle ((Get-OptionalHash $archivePath) -eq $publishedHash) `
        'archive differs from published PDF'
    $archiveAgain = Invoke-LifecycleCli -FilePath $localLauncher `
        -Arguments @('archive', 'acceptance') -WorkingDirectory $engineRoot
    Assert-Lifecycle ($archiveAgain.ExitCode -ne 0) 'archive collision overwrote an existing snapshot'
    $unsafeArchive = Invoke-LifecycleCli -FilePath $localLauncher `
        -Arguments @('archive', '../escape') -WorkingDirectory $engineRoot
    Assert-Lifecycle ($unsafeArchive.ExitCode -ne 0) 'unsafe archive label escaped its directory'

    $exportReportPath = Join-Path $workspaceRoot 'output/export-report.json'
    $originalExportReport = [System.IO.File]::ReadAllText(
        $exportReportPath,
        [System.Text.Encoding]::UTF8
    )
    $tamperedExportReport = $originalExportReport | ConvertFrom-Json
    $tamperedExportReport.mode = '../escape'
    [System.IO.File]::WriteAllText(
        $exportReportPath,
        ($tamperedExportReport | ConvertTo-Json -Depth 10),
        $encoding
    )
    try {
        $tamperedArchive = Invoke-LifecycleCli -FilePath $localLauncher `
            -Arguments @('archive', 'tampered') -WorkingDirectory $engineRoot
        Assert-Lifecycle ($tamperedArchive.ExitCode -ne 0) `
            'archive trusted an invalid mode from export-report.json'
        Assert-Lifecycle (@(Get-ChildItem -LiteralPath `
            (Join-Path $workspaceRoot 'output/archive') `
            -Filter 'document-tampered*' -File -Force).Count -eq 0) `
            'tampered export report escaped the archive naming contract'
    }
    finally {
        [System.IO.File]::WriteAllText($exportReportPath, $originalExportReport, $encoding)
    }
    Assert-Lifecycle (@(Get-ChildItem -LiteralPath (Join-Path $workspaceRoot 'output/archive') `
        -Filter '.ank-archive-*.tmp' -File -Force).Count -eq 0) `
        'archive left a temporary partial file behind'

    $mutated = Join-Path $workspaceRoot ([string]@($project.document.content)[1])
    $originalContent = [System.IO.File]::ReadAllText($mutated, [System.Text.Encoding]::UTF8)
    [System.IO.File]::AppendAllText($mutated, "`n<!-- snapshot mutation -->`n", $encoding)
    $staleExport = Invoke-LifecycleCli -FilePath $localLauncher `
        -Arguments @('export') -WorkingDirectory $engineRoot
    Assert-Lifecycle ($staleExport.ExitCode -ne 0) 'stale workspace was exported without a new Draft'
    Assert-Lifecycle ($staleExport.Text -match [regex]::Escape([string]@($project.document.content)[1])) `
        'stale export diagnostic did not identify the changed source file'
    Assert-Lifecycle ((Get-OptionalHash $published) -eq $publishedHash) `
        'failed stale export modified the published PDF'

    [System.IO.File]::WriteAllText($mutated, $originalContent, $encoding)

    $formatSpecPath = Join-Path $workspaceRoot 'format-spec.yaml'
    $originalFormatSpec = [System.IO.File]::ReadAllText(
        $formatSpecPath,
        [System.Text.Encoding]::UTF8
    )
    [System.IO.File]::AppendAllText(
        $formatSpecPath,
        "`n# document snapshot mutation`n",
        $encoding
    )
    try {
        $resolvedAfterFormatChange = Resolve-AutoNormoKontrolWorkspace `
            -EngineRoot $engineRoot -WorkspaceRoot $workspaceRoot
        Assert-Lifecycle ($resolvedAfterFormatChange.ProfileDigestMatches) `
            'mutable format-spec.yaml incorrectly changed the immutable profile digest'
        $staleFormatExport = Invoke-LifecycleCli -FilePath $localLauncher `
            -Arguments @('export') -WorkingDirectory $engineRoot
        Assert-Lifecycle ($staleFormatExport.ExitCode -ne 0) `
            'changed format-spec.yaml was exported without a new Draft'
        Assert-Lifecycle ($staleFormatExport.Text -match 'format-spec.yaml') `
            'stale format-spec diagnostic did not identify format-spec.yaml'
        Assert-Lifecycle ((Get-OptionalHash $published) -eq $publishedHash) `
            'failed format-spec export modified the published PDF'
    }
    finally {
        [System.IO.File]::WriteAllText($formatSpecPath, $originalFormatSpec, $encoding)
    }

    $reordered = $originalManifest | ConvertFrom-Json
    $firstChapter = $reordered.document.content[1]
    $reordered.document.content[1] = $reordered.document.content[2]
    $reordered.document.content[2] = $firstChapter
    Write-WorkspaceManifest $reordered
    try {
        $staleManifestExport = Invoke-LifecycleCli -FilePath $localLauncher `
            -Arguments @('export') -WorkingDirectory $engineRoot
        Assert-Lifecycle ($staleManifestExport.ExitCode -ne 0) `
            'changed project content order was exported without a new Draft'
        Assert-Lifecycle ($staleManifestExport.Text -match 'project.yaml') `
            'stale project manifest diagnostic did not identify project.yaml'
        Assert-Lifecycle ((Get-OptionalHash $published) -eq $publishedHash) `
            'failed project manifest export modified the published PDF'
    }
    finally {
        [System.IO.File]::WriteAllText($manifestPath, $originalManifest, $encoding)
    }

    Write-Host 'PASS R1 workspace lifecycle: new -> draft -> export -> archive'
    exit 0
}
catch {
    Write-Error ("R1 workspace lifecycle failed: {0}" -f $_.Exception.Message)
    exit 1
}
finally {
    foreach ($temporaryWorkspace in @($workspaceRoot, $selectedWorkspaceRoot)) {
        if (Test-Path -LiteralPath $temporaryWorkspace -PathType Container) {
        $workspaceFull = [System.IO.Path]::GetFullPath($temporaryWorkspace)
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
}
