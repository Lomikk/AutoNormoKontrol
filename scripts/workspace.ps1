$script:AutoNormoKontrolWorkspaceManifest = 'project.yaml'
$script:AutoNormoKontrolPublishedPdf = 'output/document.pdf'
$script:AutoNormoKontrolExportReport = 'output/export-report.json'
$script:AutoNormoKontrolArchiveDirectory = 'output/archive'
$script:AutoNormoKontrolAgentPrompt = 'guide/profile-system-prompt.md'
$script:AutoNormoKontrolGeminiLauncher = 'gemini.cmd'
$script:AutoNormoKontrolWorkspaceLauncherTemplate = 'resources/workspace-launchers/AutoNormoKontrol.cmd'
$script:AutoNormoKontrolGeminiLauncherTemplate = 'resources/workspace-launchers/gemini.cmd'

. (Join-Path $PSScriptRoot 'requirements.ps1')

function Get-AutoNormoKontrolEngineVersion {
    param([Parameter(Mandatory = $true)][string]$EngineRoot)

    $versionPath = Join-Path $EngineRoot 'VERSION'
    if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) {
        throw "Engine version file was not found: $versionPath"
    }
    $value = [System.IO.File]::ReadAllText(
        $versionPath,
        [System.Text.Encoding]::UTF8
    ).Trim()
    if ($value -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
        throw "Engine VERSION must be semantic x.y.z: $value"
    }
    try { [void][version]$value }
    catch { throw "Engine VERSION must be semantic x.y.z: $value" }
    return $value
}

function Assert-WorkspaceObjectShape {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Location,
        [Parameter(Mandatory = $true)][string[]]$Required
    )

    if ($Object -isnot [pscustomobject]) {
        throw "Workspace field '$Location' must be an object."
    }
    $actual = @($Object.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($name in $Required) {
        if ($actual -notcontains $name) {
            throw "Workspace field '$Location' is missing required field '$name'."
        }
    }
    foreach ($name in $actual) {
        if ($Required -notcontains $name) {
            throw "Workspace field '$Location' contains unknown field '$name'."
        }
    }
}

function Resolve-WorkspaceOwnedPath {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [ValidateSet('File', 'Directory', 'Output')][string]$Kind = 'File'
    )

    return Resolve-ProfileProjectPath -Root $WorkspaceRoot -Path $RelativePath `
        -Location 'workspace' -Kind $Kind
}

function Resolve-AutoNormoKontrolWorkspace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$EngineRoot,
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot
    )

    $engineFull = [System.IO.Path]::GetFullPath($EngineRoot).TrimEnd('\', '/')
    $workspaceFull = [System.IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\', '/')
    if (-not (Test-Path -LiteralPath $engineFull -PathType Container)) {
        throw "Engine root does not exist: $engineFull"
    }
    if (-not (Test-Path -LiteralPath $workspaceFull -PathType Container)) {
        throw "Workspace root does not exist: $workspaceFull"
    }

    $engineVersion = Get-AutoNormoKontrolEngineVersion -EngineRoot $engineFull
    $manifestFull = Join-Path $workspaceFull $script:AutoNormoKontrolWorkspaceManifest
    if (-not (Test-Path -LiteralPath $manifestFull -PathType Leaf)) {
        throw "Workspace manifest was not found: $manifestFull"
    }
    try {
        $document = [System.IO.File]::ReadAllText(
            $manifestFull,
            [System.Text.Encoding]::UTF8
        ) | ConvertFrom-Json
    }
    catch {
        throw "Workspace manifest is not valid JSON-compatible YAML: $($_.Exception.Message)"
    }

    Assert-WorkspaceObjectShape $document '<root>' @('schema_version', 'profile', 'engine', 'document')
    Assert-WorkspaceObjectShape $document.profile 'profile' @('id', 'manifest', 'digest')
    Assert-WorkspaceObjectShape $document.engine 'engine' @('minimum_version', 'created_with')
    Assert-WorkspaceObjectShape $document.document 'document' @('type', 'content')
    if ($document.schema_version -isnot [int] -or $document.schema_version -ne 1) {
        throw "Unsupported workspace schema_version: $($document.schema_version)"
    }

    $profileId = [string]$document.profile.id
    $profilePath = ([string]$document.profile.manifest).Replace('\', '/')
    $pinnedDigest = [string]$document.profile.digest
    if ($profileId -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*-v[0-9]+$') {
        throw "Invalid workspace profile id: $profileId"
    }
    if ($profilePath -notmatch '^profiles/[a-z0-9]+(?:-[a-z0-9]+)*/profile\.yaml$') {
        throw "Invalid workspace profile manifest path: $profilePath"
    }
    if ($pinnedDigest -cnotmatch '^[a-f0-9]{64}$') {
        throw 'Workspace profile digest must contain 64 lowercase SHA-256 characters.'
    }

    foreach ($field in @('minimum_version', 'created_with')) {
        $value = [string]$document.engine.$field
        if ($value -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
            throw "Workspace engine.$field must be semantic x.y.z: $value"
        }
        try { [void][version]$value }
        catch { throw "Workspace engine.$field must be semantic x.y.z: $value" }
    }
    if ([version]$engineVersion -lt [version]([string]$document.engine.minimum_version)) {
        throw ("Workspace requires AutoNormoKontrol >= {0}; installed engine is {1}." -f
            $document.engine.minimum_version, $engineVersion)
    }

    $contentPaths = @(ConvertTo-ProfileStringArray -Value $document.document.content `
        -Location 'document.content')
    foreach ($contentPath in $contentPaths) {
        $normalized = ([string]$contentPath).Replace('\', '/')
        if ($normalized -ne [string]$contentPath -or
            $normalized -notmatch '^content/.+\.md$' -or
            $normalized -match '(^|/)(\.|\.\.)(/|$)') {
            throw "Workspace document.content contains an unsafe Markdown path: $contentPath"
        }
        [void](Resolve-WorkspaceOwnedPath $workspaceFull $normalized File)
    }

    $profile = Resolve-AutoNormoKontrolProfile -Root $engineFull -ProfilePath $profilePath
    if ($profile.ProfileId -ne $profileId) {
        throw "Workspace expects profile '$profileId', manifest declares '$($profile.ProfileId)'."
    }
    if ($profile.DocumentType -ne [string]$document.document.type) {
        throw ("Workspace document type '{0}' does not match profile type '{1}'." -f
            $document.document.type, $profile.DocumentType)
    }

    # R1/agent-contract: new copies the profile prompt as a starting point, but
    # the local file is an intentional workspace-owned override. It must exist
    # and stay inside the workspace; users may adapt it without editing engine.
    [void](Resolve-WorkspaceOwnedPath `
        $workspaceFull $script:AutoNormoKontrolAgentPrompt File)

    # The profile only declares these workspace-owned paths. Resolve every
    # concrete input and output here, against the selected project root.
    $workspaceInputs = @(
        @('inputs.metadata', $profile.Data.inputs.metadata),
        @('inputs.bibliography', $profile.Data.inputs.bibliography),
        @('inputs.asset_manifest', $profile.Data.inputs.asset_manifest),
        @('compliance.semantic_review', $profile.Data.compliance.semantic_review),
        @('compliance.external_acceptance', $profile.Data.compliance.external_acceptance),
        @('compliance.format_spec', $profile.Data.compliance.format_spec)
    )
    foreach ($entry in $workspaceInputs) {
        [void](Resolve-WorkspaceOwnedPath $workspaceFull ([string]$entry[1]) File)
    }

    $workspaceOutputs = @(
        @('assets.report', $profile.Data.assets.report),
        @('assets.output_directory', $profile.Data.assets.output_directory),
        @('outputs.tex', $profile.Data.outputs.tex),
        @('outputs.pdf', $profile.Data.outputs.pdf),
        @('reports.document_snapshot', $profile.Data.reports.document_snapshot),
        @('reports.build_report', $profile.Data.reports.build_report),
        @('reports.postflight', $profile.Data.reports.postflight),
        @('reports.traceability_json', $profile.Data.reports.traceability_json),
        @('reports.traceability_markdown', $profile.Data.reports.traceability_markdown)
    )
    foreach ($entry in $workspaceOutputs) {
        [void](Resolve-WorkspaceOwnedPath $workspaceFull ([string]$entry[1]) Output)
    }

    foreach ($texInput in @($profile.Data.render.tex_input_paths)) {
        if ([string]$texInput -eq '.') {
            [void](Resolve-WorkspaceOwnedPath $workspaceFull '.' Directory)
        }
    }

    return [pscustomobject][ordered]@{
        EngineRoot = $engineFull
        WorkspaceRoot = $workspaceFull
        ManifestPath = $manifestFull
        Manifest = $document
        EngineVersion = $engineVersion
        CreatedWithEngineVersion = [string]$document.engine.created_with
        EngineVersionMatches = $engineVersion -eq [string]$document.engine.created_with
        ProfilePath = $profilePath
        PinnedProfileDigest = $pinnedDigest
        ProfileDigestMatches = $pinnedDigest -eq $profile.ProfileDigest
        Profile = $profile
        ContentPaths = $contentPaths
        AgentPromptPath = $agentPromptFull
    }
}

function Assert-WorkspaceName {
    param([Parameter(Mandatory = $true)][string]$Name)

    $value = $Name.Trim()
    if ([string]::IsNullOrWhiteSpace($value) -or $value -in @('.', '..')) {
        throw 'Workspace name must not be empty.'
    }
    if ($value.Length -gt 100) {
        throw 'Workspace name must be at most 100 characters.'
    }
    if ($value.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
        $value.Contains('\') -or $value.Contains('/')) {
        throw "Workspace name contains a forbidden path character: $value"
    }
    $base = $value.TrimEnd('.', ' ').ToUpperInvariant()
    if ($base -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$') {
        throw "Workspace name is reserved by Windows: $value"
    }
    if ($value -ne $value.TrimEnd('.', ' ')) {
        throw 'Workspace name must not end with a dot or space.'
    }
    return $value
}

function New-AutoNormoKontrolWorkspace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$EngineRoot,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$ProfilePath = ''
    )

    $engineFull = [System.IO.Path]::GetFullPath($EngineRoot).TrimEnd('\', '/')
    $nameValue = Assert-WorkspaceName -Name $Name
    $workspacesRoot = Join-Path $engineFull 'Workspaces'
    New-Item -ItemType Directory -Force -Path $workspacesRoot | Out-Null
    $target = [System.IO.Path]::GetFullPath((Join-Path $workspacesRoot $nameValue))
    $workspacePrefix = [System.IO.Path]::GetFullPath($workspacesRoot).TrimEnd('\', '/') +
        [System.IO.Path]::DirectorySeparatorChar
    if (-not $target.StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Workspace destination leaves the Workspaces directory.'
    }
    if (Test-Path -LiteralPath $target) {
        throw "Workspace already exists; no files were overwritten: $target"
    }

    if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
        $catalog = Get-AutoNormoKontrolProfileCatalog -Root $engineFull
        $defaultProfiles = @($catalog.Entries | Where-Object IsDefault)
        if ($defaultProfiles.Count -ne 1) {
            throw 'Profile catalog did not resolve exactly one default profile.'
        }
        $ProfilePath = $defaultProfiles[0].Manifest
    }
    $profile = Resolve-AutoNormoKontrolProfile -Root $engineFull -ProfilePath $ProfilePath
    $profileData = $profile.Data
    $starter = Resolve-ProfileProjectPath -Root $engineFull `
        -Path ([string]$profileData.starter.directory) -Location 'starter.directory' `
        -Kind Directory

    $staging = Join-Path $workspacesRoot ('.ank-new-' + [guid]::NewGuid().ToString('N'))
    $committed = $false
    try {
        New-Item -ItemType Directory -Path $staging | Out-Null
        Get-ChildItem -LiteralPath $starter -Force | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $staging -Recurse -Force
        }

        # R1/workspace: keep the starter versioned while avoiding a stale year
        # in every project created after the profile release year.
        $metadataRelative = [string]$profileData.inputs.metadata
        $metadataFull = Resolve-ProfileProjectPath -Root $staging -Path $metadataRelative `
            -Location 'new.metadata' -Kind File
        $metadataText = [System.IO.File]::ReadAllText(
            $metadataFull,
            [System.Text.Encoding]::UTF8
        )
        $currentYear = [DateTime]::Now.Year.ToString([Globalization.CultureInfo]::InvariantCulture)
        $yearPattern = '(?m)^year:\s*[0-9]{4}\s*$'
        if ([regex]::Matches($metadataText, $yearPattern).Count -ne 1) {
            throw 'Profile starter metadata must contain exactly one numeric year field.'
        }
        $metadataText = [regex]::Replace($metadataText, $yearPattern, "year: $currentYear")
        $codePattern = '(?m)^(document-code:\s*"[^"]*?\.)([0-9]{4})(\.[^"]*")$'
        $metadataText = [regex]::Replace(
            $metadataText,
            $codePattern,
            { param($match) $match.Groups[1].Value + $currentYear + $match.Groups[3].Value }
        )
        [System.IO.File]::WriteAllText($metadataFull, $metadataText,
            (New-Object System.Text.UTF8Encoding($false)))

        $compliance = Join-Path $staging 'compliance'
        New-Item -ItemType Directory -Force -Path $compliance | Out-Null
        # R0/requirements-v2: review journals are generated from the canonical
        # inventory plus this profile's verification declarations. Their
        # statuses and evidence remain workspace-owned and are never regenerated.
        $requirementContract = Get-AutoNormoKontrolRequirementContract `
            -Root $engineFull -Profile $profile
        New-AutoNormoKontrolReviewJournals `
            -Contract $requirementContract `
            -DocumentType ([string]$profileData.document_type) `
            -SemanticPath (Join-Path $compliance 'semantic-review.yaml') `
            -ExternalPath (Join-Path $compliance 'external-acceptance.yaml')

        # R1/agent-contract: the profile starter owns the local agent prompt.
        # It was copied with the rest of starter and may be adapted in workspace.
        [void](Resolve-WorkspaceOwnedPath -WorkspaceRoot $staging `
            -RelativePath $script:AutoNormoKontrolAgentPrompt -Kind File)

        # R1/agent-contract: launchers are engine resources, not executable
        # source embedded in PowerShell or duplicated by every profile starter.
        foreach ($launcherEntry in @(
            @($script:AutoNormoKontrolWorkspaceLauncherTemplate, 'AutoNormoKontrol.cmd'),
            @($script:AutoNormoKontrolGeminiLauncherTemplate, $script:AutoNormoKontrolGeminiLauncher)
        )) {
            $launcherSource = Resolve-ProfileProjectPath -Root $engineFull `
                -Path ([string]$launcherEntry[0]) -Location 'workspace.launcher' -Kind File
            Copy-Item -LiteralPath $launcherSource `
                -Destination (Join-Path $staging ([string]$launcherEntry[1])) -Force
        }

        $engineVersion = Get-AutoNormoKontrolEngineVersion -EngineRoot $engineFull
        $contentPaths = @(ConvertTo-ProfileStringArray -Value $profileData.starter.content `
            -Location 'starter.content')
        $manifest = [pscustomobject][ordered]@{
            schema_version = 1
            profile = [pscustomobject][ordered]@{
                id = [string]$profileData.profile_id
                manifest = $profile.ManifestPath
                digest = ('0' * 64)
            }
            engine = [pscustomobject][ordered]@{
                minimum_version = $engineVersion
                created_with = $engineVersion
            }
            document = [pscustomobject][ordered]@{
                type = [string]$profileData.document_type
                content = $contentPaths
            }
        }
        [System.IO.File]::WriteAllText(
            (Join-Path $staging $script:AutoNormoKontrolWorkspaceManifest),
            ($manifest | ConvertTo-Json -Depth 8),
            (New-Object System.Text.UTF8Encoding($false))
        )

        $manifest.profile.id = $profile.ProfileId
        $manifest.profile.manifest = $profile.ManifestPath
        $manifest.profile.digest = $profile.ProfileDigest
        $manifest.document.type = $profile.DocumentType
        [System.IO.File]::WriteAllText(
            (Join-Path $staging $script:AutoNormoKontrolWorkspaceManifest),
            ($manifest | ConvertTo-Json -Depth 8),
            (New-Object System.Text.UTF8Encoding($false))
        )

        # R1/workspace: same-volume Directory.Move is the atomic commit. Unlike
        # Move-Item it cannot silently place staging inside a target directory
        # that appeared after the initial existence check.
        [System.IO.Directory]::Move($staging, $target)
        $committed = $true
        return Resolve-AutoNormoKontrolWorkspace -EngineRoot $engineFull -WorkspaceRoot $target
    }
    finally {
        if (-not $committed -and (Test-Path -LiteralPath $staging -PathType Container)) {
            $stagingFull = [System.IO.Path]::GetFullPath($staging)
            if ($stagingFull.StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $stagingFull -Recurse -Force
            }
        }
    }
}

function Get-ValidatedBuildArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Workspace,
        [switch]$RequireFreshSnapshot
    )

    $profile = $Workspace.Profile
    $root = $Workspace.WorkspaceRoot
    $reportRelative = [string]$profile.Data.reports.build_report
    $reportFull = Resolve-WorkspaceOwnedPath $root $reportRelative File
    try { $report = Get-Content -Raw -Encoding UTF8 -LiteralPath $reportFull | ConvertFrom-Json }
    catch { throw "Build report is not valid JSON: $($_.Exception.Message)" }
    if ([string]$report.version -ne '1' -or
        [string]$report.profile_id -ne $profile.ProfileId -or
        [string]$report.profile_digest -ne $profile.ProfileDigest) {
        throw 'Last build report belongs to another or changed profile; run draft again.'
    }
    if ([string]$report.mode -notin @('draft', 'strict')) {
        throw "Last build report has unsupported mode '$($report.mode)'."
    }
    $expectedPdf = ([string]$profile.Data.outputs.pdf).Replace('\', '/')
    if (([string]$report.output.path).Replace('\', '/') -ne $expectedPdf) {
        throw 'Last build report points to an unexpected PDF path.'
    }
    $pdfFull = Resolve-WorkspaceOwnedPath $root $expectedPdf File
    $pdf = Get-Item -LiteralPath $pdfFull
    $pdfHash = (Get-FileHash -LiteralPath $pdfFull -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($pdf.Length -ne [int64]$report.output.bytes -or
        $pdfHash -ne ([string]$report.output.sha256).ToLowerInvariant()) {
        throw 'Built PDF no longer matches the successful build report; run draft again.'
    }
    $stream = [System.IO.File]::OpenRead($pdfFull)
    try {
        $header = New-Object byte[] 5
        [void]$stream.Read($header, 0, 5)
        if ([System.Text.Encoding]::ASCII.GetString($header) -ne '%PDF-') {
            throw 'Built artifact is not a PDF file.'
        }
    }
    finally { $stream.Dispose() }

    $postflightFull = Resolve-WorkspaceOwnedPath $root `
        ([string]$profile.Data.reports.postflight) File
    try { $postflight = Get-Content -Raw -Encoding UTF8 -LiteralPath $postflightFull | ConvertFrom-Json }
    catch { throw "PDF postflight report is not valid JSON: $($_.Exception.Message)" }
    if ([string]$postflight.status -ne 'pass') {
        throw 'The last PDF postflight did not pass; run draft and fix its errors.'
    }

    if ($RequireFreshSnapshot) {
        $snapshotRelative = [string]$report.document_snapshot
        $snapshotFull = Resolve-WorkspaceOwnedPath $root $snapshotRelative File
        try { $snapshot = Get-Content -Raw -Encoding UTF8 -LiteralPath $snapshotFull | ConvertFrom-Json }
        catch { throw "Document snapshot is not valid JSON: $($_.Exception.Message)" }
        Assert-WorkspaceObjectShape $snapshot 'document-snapshot' @(
            'version', 'profile_id', 'algorithm', 'content_hash', 'files'
        )
        if ([string]$snapshot.version -ne '1' -or
            [string]$snapshot.profile_id -ne $profile.ProfileId -or
            [string]$snapshot.algorithm -ne 'sha256(path-null-file-sha256)' -or
            [string]$snapshot.content_hash -cnotmatch '^[a-f0-9]{64}$' -or
            [string]$snapshot.content_hash -ne [string]$report.content_hash) {
            throw 'Document snapshot does not match the successful build report; run draft again.'
        }

        $snapshotFiles = @($snapshot.files)
        if ($snapshotFiles.Count -eq 0) {
            throw 'Document snapshot contains no files; run draft again.'
        }
        $seenSnapshotPaths = New-Object 'System.Collections.Generic.HashSet[string]' `
            ([StringComparer]::OrdinalIgnoreCase)
        $canonicalLines = New-Object System.Collections.Generic.List[string]
        foreach ($entry in $snapshotFiles) {
            Assert-WorkspaceObjectShape $entry 'document-snapshot.files[]' @('path', 'sha256')
            $path = [string]$entry.path
            $expectedHash = [string]$entry.sha256
            if ([string]::IsNullOrWhiteSpace($path) -or
                $path.Replace('\', '/') -ne $path -or
                $expectedHash -cnotmatch '^[a-f0-9]{64}$' -or
                -not $seenSnapshotPaths.Add($path)) {
                throw "Document snapshot contains an invalid or duplicate path: $path"
            }
            $full = Resolve-WorkspaceOwnedPath $root $path File
            $actual = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actual -ne $expectedHash) {
                throw "Workspace changed after the last successful build ($path); run draft again."
            }
            $canonicalLines.Add($path + [char]0 + $expectedHash)
        }
        $canonicalBytes = [System.Text.Encoding]::UTF8.GetBytes(($canonicalLines -join "`n"))
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $canonicalHash = ([BitConverter]::ToString(
                $sha.ComputeHash($canonicalBytes)
            )).Replace('-', '').ToLowerInvariant()
        }
        finally { $sha.Dispose() }
        if ($canonicalHash -ne [string]$snapshot.content_hash) {
            throw 'Document snapshot canonical hash is invalid; run draft again.'
        }
    }

    return [pscustomobject][ordered]@{
        Report = $report
        PdfFullPath = $pdfFull
        PdfHash = $pdfHash
        PdfBytes = $pdf.Length
    }
}

function Write-AtomicUtf8Json {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )
    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $temporary = Join-Path $directory ('.ank-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $backup = Join-Path $directory ('.ank-' + [guid]::NewGuid().ToString('N') + '.bak')
    try {
        [System.IO.File]::WriteAllText(
            $temporary,
            ($Value | ConvertTo-Json -Depth 12),
            (New-Object System.Text.UTF8Encoding($false))
        )
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [System.IO.File]::Replace($temporary, $Path, $backup)
        }
        else {
            [System.IO.File]::Move($temporary, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
        if (Test-Path -LiteralPath $backup -PathType Leaf) {
            Remove-Item -LiteralPath $backup -Force
        }
    }
}

function Export-AutoNormoKontrolPdf {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Workspace)

    $artifact = Get-ValidatedBuildArtifact -Workspace $Workspace -RequireFreshSnapshot
    $destination = Resolve-WorkspaceOwnedPath $Workspace.WorkspaceRoot `
        $script:AutoNormoKontrolPublishedPdf Output
    $directory = Split-Path -Parent $destination
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $temporary = Join-Path $directory ('.ank-export-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $backup = Join-Path $directory ('.ank-export-' + [guid]::NewGuid().ToString('N') + '.bak')
    try {
        $alreadyPublished = $false
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            try {
                $publishedHashResult = Get-FileHash -LiteralPath $destination -Algorithm SHA256
                $publishedHash = $publishedHashResult.Hash.ToLowerInvariant()
                $alreadyPublished = $publishedHash -eq $artifact.PdfHash
            }
            catch { $alreadyPublished = $false }
        }

        # A no-op export succeeds even while a PDF viewer has the identical
        # published file open. Different bytes still require an atomic replace.
        if (-not $alreadyPublished) {
            [System.IO.File]::Copy($artifact.PdfFullPath, $temporary, $false)
            $temporaryHash = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($temporaryHash -ne $artifact.PdfHash) {
                throw 'Temporary export copy failed its SHA-256 verification.'
            }
            try {
                if (Test-Path -LiteralPath $destination -PathType Leaf) {
                    [System.IO.File]::Replace($temporary, $destination, $backup)
                }
                else {
                    [System.IO.File]::Move($temporary, $destination)
                }
            }
            catch {
                throw ("Cannot update output/document.pdf. Close a program that locks it and repeat export. " +
                    "The verified build PDF was preserved. Details: $($_.Exception.Message)")
            }
        }

        $exportReportFull = Resolve-WorkspaceOwnedPath $Workspace.WorkspaceRoot `
            $script:AutoNormoKontrolExportReport Output
        $exportReport = [pscustomobject][ordered]@{
            version = 1
            profile_id = $Workspace.Profile.ProfileId
            profile_digest = $Workspace.Profile.ProfileDigest
            mode = [string]$artifact.Report.mode
            content_hash = [string]$artifact.Report.content_hash
            exported_at_utc = [DateTime]::UtcNow.ToString('o')
            output = [pscustomobject][ordered]@{
                path = $script:AutoNormoKontrolPublishedPdf
                sha256 = $artifact.PdfHash
                bytes = $artifact.PdfBytes
            }
        }
        Write-AtomicUtf8Json -Path $exportReportFull -Value $exportReport
        return [pscustomobject][ordered]@{
            Path = $destination
            Mode = [string]$artifact.Report.mode
            Hash = $artifact.PdfHash
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
        if (Test-Path -LiteralPath $backup -PathType Leaf) {
            Remove-Item -LiteralPath $backup -Force
        }
    }
}

function Archive-AutoNormoKontrolPdf {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Workspace,
        [string]$Label = ''
    )

    $published = Resolve-WorkspaceOwnedPath $Workspace.WorkspaceRoot `
        $script:AutoNormoKontrolPublishedPdf File
    $reportFull = Resolve-WorkspaceOwnedPath $Workspace.WorkspaceRoot `
        $script:AutoNormoKontrolExportReport File
    try { $report = Get-Content -Raw -Encoding UTF8 -LiteralPath $reportFull | ConvertFrom-Json }
    catch { throw "Export report is not valid JSON: $($_.Exception.Message)" }

    Assert-WorkspaceObjectShape $report 'export-report' @(
        'version', 'profile_id', 'profile_digest', 'mode', 'content_hash',
        'exported_at_utc', 'output'
    )
    Assert-WorkspaceObjectShape $report.output 'export-report.output' @(
        'path', 'sha256', 'bytes'
    )

    $reportMode = [string]$report.mode
    $reportHash = ([string]$report.output.sha256).ToLowerInvariant()
    $reportProfileDigest = ([string]$report.profile_digest).ToLowerInvariant()
    $reportContentHash = ([string]$report.content_hash).ToLowerInvariant()
    $reportOutputPath = ([string]$report.output.path).Replace('\', '/')
    if ([string]$report.version -ne '1' -or
        [string]$report.profile_id -ne $Workspace.Profile.ProfileId -or
        $reportProfileDigest -ne $Workspace.Profile.ProfileDigest -or
        $reportMode -notin @('draft', 'strict') -or
        $reportContentHash -notmatch '^[a-f0-9]{64}$' -or
        $reportOutputPath -ne $script:AutoNormoKontrolPublishedPdf) {
        throw 'Export report is incompatible with this workspace; run export again.'
    }

    $hash = (Get-FileHash -LiteralPath $published -Algorithm SHA256).Hash.ToLowerInvariant()
    $bytes = (Get-Item -LiteralPath $published).Length
    if ($hash -ne $reportHash -or
        $bytes -ne [int64]$report.output.bytes) {
        throw 'Published PDF no longer matches its export report; run export again.'
    }

    $labelValue = $Label.Trim()
    if ([string]::IsNullOrWhiteSpace($labelValue)) {
        $labelValue = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    }
    if ($labelValue.Length -gt 64 -or
        $labelValue -notmatch '^[\p{L}\p{Nd}][\p{L}\p{Nd}._-]*$') {
        throw 'Archive label may contain letters, digits, dot, underscore and hyphen (maximum 64 characters).'
    }

    $archiveDirectory = Resolve-WorkspaceOwnedPath $Workspace.WorkspaceRoot `
        $script:AutoNormoKontrolArchiveDirectory Output
    New-Item -ItemType Directory -Force -Path $archiveDirectory | Out-Null
    $fileName = 'document-{0}-{1}-{2}.pdf' -f
        $labelValue, $reportMode, $hash.Substring(0, 8)
    $destination = Join-Path $archiveDirectory $fileName
    if (Test-Path -LiteralPath $destination) {
        throw "Archive already exists; no file was overwritten: $destination"
    }

    $temporary = Join-Path $archiveDirectory `
        ('.ank-archive-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::Copy($published, $temporary, $false)
        $temporaryFile = Get-Item -LiteralPath $temporary
        $archiveHash = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($archiveHash -ne $hash -or $temporaryFile.Length -ne $bytes) {
            throw 'Archive copy failed its SHA-256 or length verification.'
        }
        # File.Move is a no-overwrite atomic publish on the same volume. A
        # failed/interrupted copy can leave only a disposable temporary file.
        [System.IO.File]::Move($temporary, $destination)
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
    return $destination
}
