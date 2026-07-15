$script:AutoNormoKontrolProfilePointer = 'profiles/active-profile.txt'

function Get-AutoNormoKontrolDefaultProfilePath {
    param(
        [string]$Root = (Split-Path -Parent $PSScriptRoot),
        [string]$PointerPath = $script:AutoNormoKontrolProfilePointer
    )

    $pointerFull = Resolve-ProfileProjectPath -Root $Root -Path $PointerPath `
        -Location 'active_profile_pointer' -Kind File
    $raw = [System.IO.File]::ReadAllText($pointerFull, [System.Text.Encoding]::UTF8)
    $lines = @($raw -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -ne 1) {
        throw "Active profile pointer must contain exactly one non-empty project-relative path: $PointerPath"
    }
    $profilePath = $lines[0].Trim().Replace('\', '/')
    if ($profilePath -notmatch '^profiles/[a-z0-9]+(?:-[a-z0-9]+)*/profile\.yaml$') {
        throw "Active profile pointer has an invalid manifest path: $profilePath"
    }
    [void](Resolve-ProfileProjectPath -Root $Root -Path $profilePath `
        -Location 'active_profile' -Kind File)
    return $profilePath
}

function Get-ProfilePropertyNames {
    param([Parameter(Mandatory = $true)][object]$Object)
    return @($Object.PSObject.Properties | ForEach-Object { $_.Name })
}

function Assert-ProfileObjectShape {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Location,
        [Parameter(Mandatory = $true)][string[]]$Required
    )

    if ($Object -isnot [pscustomobject]) {
        throw "Profile field '$Location' must be an object."
    }
    $actual = @(Get-ProfilePropertyNames $Object)
    foreach ($name in $Required) {
        if ($actual -notcontains $name) {
            throw "Profile field '$Location' is missing required field '$name'."
        }
    }
    foreach ($name in $actual) {
        if ($Required -notcontains $name) {
            throw "Profile field '$Location' contains unknown field '$name'."
        }
    }
}

function Assert-ProfileString {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Location
    )
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        throw "Profile field '$Location' must be a non-empty string."
    }
}

function ConvertTo-ProfileStringArray {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Location
    )

    if ($Value -is [string] -or $Value -isnot [System.Array] -or $Value.Count -eq 0) {
        throw "Profile field '$Location' must be a non-empty array."
    }
    $result = @()
    $seen = @{}
    foreach ($item in @($Value)) {
        Assert-ProfileString -Value $item -Location $Location
        $text = [string]$item
        $key = $text.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            throw "Profile field '$Location' contains duplicate value '$text'."
        }
        $seen[$key] = $true
        $result += $text
    }
    return $result
}

function Resolve-ProfileProjectPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Location,
        [ValidateSet('File', 'Directory', 'Output')][string]$Kind = 'File'
    )

    Assert-ProfileString -Value $Path -Location $Location
    if ([System.IO.Path]::IsPathRooted($Path)) {
        throw "Profile path '$Location' must be project-relative: $Path"
    }
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $full = [System.IO.Path]::GetFullPath((Join-Path $rootFull $Path))
    $prefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
    $isRootDirectory = $Kind -eq 'Directory' -and
        $full.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)
    if (-not $isRootDirectory -and
        -not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Profile path '$Location' leaves the project root: $Path"
    }
    if ($Kind -eq 'File' -and -not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "Profile file '$Location' was not found: $Path"
    }
    if ($Kind -eq 'Directory' -and -not (Test-Path -LiteralPath $full -PathType Container)) {
        throw "Profile directory '$Location' was not found: $Path"
    }
    return $full
}

function Get-ProfileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-ProfileDigest {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$ManifestRelativePath,
        [Parameter(Mandatory = $true)][object]$Document
    )

    $paths = @(
        $ManifestRelativePath,
        [string]$Document.compliance.canonical_inventory,
        [string]$Document.compliance.requirements,
        [string]$Document.compliance.review_inventory,
        [string]$Document.compliance.semantic_review_template,
        [string]$Document.compliance.external_acceptance_template,
        [string]$Document.compliance.system_prompt,
        [string]$Document.compliance.format_spec,
        [string]$Document.compliance.research_notes,
        [string]$Document.render.template,
        [string]$Document.render.postflight
    ) + @($Document.render.style_files) + @($Document.render.lua_filters)
    $paths = @($paths | ForEach-Object { ([string]$_).Replace('\', '/') } | Sort-Object -Unique)
    $lines = foreach ($path in $paths) {
        $full = Resolve-ProfileProjectPath -Root $Root -Path $path -Location 'profile_digest' -Kind File
        $path + [char]0 + (Get-ProfileSha256 $full)
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Resolve-AutoNormoKontrolProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string]$ProfilePath = ''
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root)
    if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
        $ProfilePath = Get-AutoNormoKontrolDefaultProfilePath -Root $rootFull
    }
    $manifestFull = Resolve-ProfileProjectPath -Root $rootFull -Path $ProfilePath `
        -Location 'manifest' -Kind File
    try {
        $text = [System.IO.File]::ReadAllText($manifestFull, [System.Text.Encoding]::UTF8)
        $document = $text | ConvertFrom-Json
    }
    catch {
        throw "Profile manifest is not valid JSON-compatible YAML: $($_.Exception.Message)"
    }

    $rootFields = @(
        'schema_version', 'profile_id', 'document_type', 'inputs', 'compliance',
        'render', 'assets', 'outputs', 'reports', 'capabilities'
    )
    Assert-ProfileObjectShape -Object $document -Location '<root>' -Required $rootFields
    Assert-ProfileObjectShape -Object $document.inputs -Location 'inputs' -Required @(
        'content', 'metadata', 'bibliography', 'asset_manifest'
    )
    Assert-ProfileObjectShape -Object $document.compliance -Location 'compliance' -Required @(
        'canonical_inventory', 'requirements', 'review_inventory', 'semantic_review',
        'external_acceptance', 'semantic_review_template', 'external_acceptance_template',
        'system_prompt', 'format_spec', 'research_notes',
        'implementation_paths', 'test_paths', 'prompt_paths', 'semantic_paths', 'external_paths'
    )
    Assert-ProfileObjectShape -Object $document.render -Location 'render' -Required @(
        'pandoc_from', 'template', 'style_files', 'lua_filters', 'tex_input_paths', 'postflight'
    )
    Assert-ProfileObjectShape -Object $document.assets -Location 'assets' -Required @(
        'report', 'output_directory'
    )
    Assert-ProfileObjectShape -Object $document.outputs -Location 'outputs' -Required @('tex', 'pdf')
    Assert-ProfileObjectShape -Object $document.reports -Location 'reports' -Required @(
        'document_snapshot', 'build_report', 'postflight', 'traceability_json',
        'traceability_markdown'
    )
    Assert-ProfileObjectShape -Object $document.capabilities -Location 'capabilities' -Required @(
        'assignment', 'abstract', 'figures', 'tables', 'equations', 'appendices'
    )

    if ([int]$document.schema_version -ne 1 -or [string]$document.schema_version -ne '1') {
        throw "Unsupported profile schema_version: $($document.schema_version)"
    }
    Assert-ProfileString $document.profile_id 'profile_id'
    if ([string]$document.profile_id -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*-v[0-9]+$') {
        throw "Invalid profile_id: $($document.profile_id)"
    }
    Assert-ProfileString $document.document_type 'document_type'
    if ([string]$document.document_type -notmatch '^[a-z][a-z0-9-]*$') {
        throw "Invalid document_type: $($document.document_type)"
    }

    $fileFields = @(
        @('inputs.metadata', $document.inputs.metadata),
        @('inputs.bibliography', $document.inputs.bibliography),
        @('inputs.asset_manifest', $document.inputs.asset_manifest),
        @('compliance.canonical_inventory', $document.compliance.canonical_inventory),
        @('compliance.requirements', $document.compliance.requirements),
        @('compliance.review_inventory', $document.compliance.review_inventory),
        @('compliance.semantic_review', $document.compliance.semantic_review),
        @('compliance.external_acceptance', $document.compliance.external_acceptance),
        @('compliance.semantic_review_template', $document.compliance.semantic_review_template),
        @('compliance.external_acceptance_template', $document.compliance.external_acceptance_template),
        @('compliance.system_prompt', $document.compliance.system_prompt),
        @('compliance.format_spec', $document.compliance.format_spec),
        @('compliance.research_notes', $document.compliance.research_notes),
        @('render.template', $document.render.template),
        @('render.postflight', $document.render.postflight)
    )
    foreach ($entry in $fileFields) {
        [void](Resolve-ProfileProjectPath -Root $rootFull -Path ([string]$entry[1]) `
            -Location ([string]$entry[0]) -Kind File)
    }

    $arrayFields = @(
        @('inputs.content', $document.inputs.content, 'File'),
        @('compliance.implementation_paths', $document.compliance.implementation_paths, 'Any'),
        @('compliance.test_paths', $document.compliance.test_paths, 'Any'),
        @('compliance.prompt_paths', $document.compliance.prompt_paths, 'Any'),
        @('compliance.semantic_paths', $document.compliance.semantic_paths, 'Any'),
        @('compliance.external_paths', $document.compliance.external_paths, 'Any'),
        @('render.style_files', $document.render.style_files, 'File'),
        @('render.lua_filters', $document.render.lua_filters, 'File'),
        @('render.tex_input_paths', $document.render.tex_input_paths, 'Directory')
    )
    foreach ($entry in $arrayFields) {
        $items = @(ConvertTo-ProfileStringArray -Value $entry[1] -Location $entry[0])
        foreach ($item in $items) {
            $kind = [string]$entry[2]
            if ($kind -eq 'Any') {
                $full = Resolve-ProfileProjectPath -Root $rootFull -Path $item -Location $entry[0] -Kind Output
                if (-not (Test-Path -LiteralPath $full)) {
                    throw "Profile evidence path '$($entry[0])' was not found: $item"
                }
            }
            else {
                [void](Resolve-ProfileProjectPath -Root $rootFull -Path $item -Location $entry[0] -Kind $kind)
            }
        }
    }

    Assert-ProfileString $document.render.pandoc_from 'render.pandoc_from'
    foreach ($entry in @(
        @('assets.report', $document.assets.report),
        @('assets.output_directory', $document.assets.output_directory),
        @('outputs.tex', $document.outputs.tex),
        @('outputs.pdf', $document.outputs.pdf),
        @('reports.document_snapshot', $document.reports.document_snapshot),
        @('reports.build_report', $document.reports.build_report),
        @('reports.postflight', $document.reports.postflight),
        @('reports.traceability_json', $document.reports.traceability_json),
        @('reports.traceability_markdown', $document.reports.traceability_markdown)
    )) {
        [void](Resolve-ProfileProjectPath -Root $rootFull -Path ([string]$entry[1]) `
            -Location ([string]$entry[0]) -Kind Output)
    }

    foreach ($name in @('assignment', 'abstract', 'figures', 'tables', 'equations', 'appendices')) {
        $value = [string]$document.capabilities.$name
        if ($value -notin @('required', 'optional', 'forbidden')) {
            throw "Profile capability '$name' has unsupported value '$value'."
        }
    }

    $manifestRelative = $ProfilePath.Replace('\', '/')
    return [pscustomobject][ordered]@{
        ProfileId = [string]$document.profile_id
        DocumentType = [string]$document.document_type
        ManifestPath = $manifestRelative
        ManifestFullPath = $manifestFull
        ManifestSha256 = Get-ProfileSha256 $manifestFull
        ProfileDigest = Get-ProfileDigest -Root $rootFull `
            -ManifestRelativePath $manifestRelative -Document $document
        Data = $document
    }
}
