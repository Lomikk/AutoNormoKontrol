[CmdletBinding()]
param(
    [string]$InputRoot,
    [string]$DestinationRoot,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root

if ([string]::IsNullOrWhiteSpace($InputRoot)) {
    $InputRoot = Join-Path $root 'Документы ЮУрГУ'
}
if ([string]::IsNullOrWhiteSpace($DestinationRoot)) {
    $DestinationRoot = Join-Path $root 'sources\susu'
}

function Get-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Assert-Command {
    param([Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command was not found: $Name"
    }
}

function Write-Utf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function ConvertTo-RelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BasePath
    )
    return $Path.Substring($BasePath.TrimEnd('\').Length).TrimStart('\') -replace '\\', '/'
}

function Copy-VerifiedFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [switch]$AllowMetadataUpdate
    )

    $sourceHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash.ToLowerInvariant()
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        $destinationHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($destinationHash -ne $sourceHash) {
            if ($AllowMetadataUpdate) {
                if (-not $DryRun) {
                    Copy-Item -LiteralPath $Source -Destination $Destination -Force
                }
                return $sourceHash
            }
            throw "Refusing to overwrite a different existing source: $Destination"
        }
        return $sourceHash
    }

    if ($DryRun) { return $sourceHash }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination
    return $sourceHash
}

function Invoke-PopplerInspection {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$Source
    )

    # Poppler's pdffonts reports missing display-font mappings on stderr even
    # when extraction succeeds.  Capture that diagnostic as data and decide by
    # the native exit code instead of letting PowerShell 5.1 promote it to an
    # exception under ErrorActionPreference=Stop.
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $Command $Source 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) { throw "$Command failed: $Source" }
    return $output
}

function Get-PdfRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$DestinationDirectory,
        [Parameter(Mandatory = $true)][string]$TextFileName,
        [Parameter(Mandatory = $true)][string]$Role
    )

    $sourceHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash.ToLowerInvariant()
    $info = @(Invoke-PopplerInspection -Command 'pdfinfo' -Source $Source)
    $pageLine = $info | Where-Object { $_ -match '^Pages:' } | Select-Object -First 1
    if ($null -eq $pageLine) { throw "pdfinfo did not report a page count: $Source" }
    $pages = [int](($pageLine -replace '^Pages:\s*', '').Trim())
    $fonts = @(Invoke-PopplerInspection -Command 'pdffonts' -Source $Source)

    $textPath = Join-Path $DestinationDirectory $TextFileName
    $technicalPath = [System.IO.Path]::ChangeExtension($textPath, 'technical.txt')
    if (-not $DryRun) {
        New-Item -ItemType Directory -Force -Path $DestinationDirectory | Out-Null
        & pdftotext -layout -enc UTF-8 $Source $textPath
        if ($LASTEXITCODE -ne 0) { throw "pdftotext failed: $Source" }
    }

    $record = [ordered]@{
        role = $Role
        source_sha256 = $sourceHash
        pages = $pages
        text = (ConvertTo-RelativePath -Path $textPath -BasePath $DestinationRoot)
        text_sha256 = $null
        text_bytes = $null
    }
    if (-not $DryRun) {
        $record.text_sha256 = (Get-FileHash -LiteralPath $textPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $record.text_bytes = (Get-Item -LiteralPath $textPath).Length
        $technical = @(
            "Source SHA256: $sourceHash",
            "Text SHA256: $($record.text_sha256)",
            '',
            '[pdfinfo]'
        ) + $info + @('', '[pdffonts]') + $fonts
        Write-Utf8File -Path $technicalPath -Text (($technical -join [Environment]::NewLine) + [Environment]::NewLine)
    }
    return [pscustomobject]$record
}

$InputRoot = Get-NormalizedPath $InputRoot
$DestinationRoot = Get-NormalizedPath $DestinationRoot
$allowedDestinationRoot = Get-NormalizedPath (Join-Path $root 'sources')
if (-not $DestinationRoot.StartsWith($allowedDestinationRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "DestinationRoot must remain under $allowedDestinationRoot"
}
if (-not (Test-Path -LiteralPath $InputRoot -PathType Container)) {
    throw "Source input directory was not found: $InputRoot"
}

Assert-Command 'pdfinfo'
Assert-Command 'pdffonts'
Assert-Command 'pdftotext'

$listingPath = Join-Path $InputRoot 'Источник.yml'
if (-not (Test-Path -LiteralPath $listingPath -PathType Leaf)) {
    throw "Source listing was not found: $listingPath"
}

$standardDirectories = @(Get-ChildItem -LiteralPath $InputRoot -Directory |
    Where-Object { $_.Name -match '^СТО ЮУрГУ \d{2}-\d{4}$' } |
    Sort-Object Name)
if ($standardDirectories.Count -eq 0) {
    throw "No directories named 'СТО ЮУрГУ NN-YYYY' were found in $InputRoot"
}

$catalogEntries = New-Object System.Collections.Generic.List[object]
foreach ($directory in $standardDirectories) {
    $match = [regex]::Match($directory.Name, '^СТО ЮУрГУ (?<number>\d{2})-(?<year>\d{4})$')
    $id = ('sto-{0}-{1}' -f $match.Groups['number'].Value, $match.Groups['year'].Value)
    $code = ('СТО ЮУрГУ {0}-{1}' -f $match.Groups['number'].Value, $match.Groups['year'].Value)
    $standardPdfs = @(Get-ChildItem -LiteralPath $directory.FullName -File -Filter 'CTOsusu*.pdf')
    if ($standardPdfs.Count -ne 1) {
        throw "$code must contain exactly one CTOsusu*.pdf, found $($standardPdfs.Count)"
    }

    $destination = Join-Path $DestinationRoot $id
    $standardPdf = $standardPdfs[0]
    $standardDestination = Join-Path $destination (Join-Path 'original' $standardPdf.Name)
    $standardHash = Copy-VerifiedFile -Source $standardPdf.FullName -Destination $standardDestination
    $standardRecord = Get-PdfRecord -Source $standardPdf.FullName `
        -DestinationDirectory (Join-Path $destination 'derived') `
        -TextFileName 'standard.layout.txt' -Role 'normative-standard'

    $attachments = New-Object System.Collections.Generic.List[object]
    $files = @(Get-ChildItem -LiteralPath $directory.FullName -File | Sort-Object Name)
    foreach ($file in $files | Where-Object { $_.FullName -ne $standardPdf.FullName }) {
        $extension = $file.Extension.ToLowerInvariant()
        $relativeDestination = switch ($extension) {
            '.doc' { Join-Path 'attachments\original' $file.Name }
            '.docx' { Join-Path 'attachments\converted' $file.Name }
            '.pdf' { Join-Path 'attachments\rendered' $file.Name }
            default { throw "Unsupported source attachment extension '$extension': $($file.FullName)" }
        }
        $destinationPath = Join-Path $destination $relativeDestination
        $attachmentHash = Copy-VerifiedFile -Source $file.FullName -Destination $destinationPath
        $attachment = [ordered]@{
            file = (ConvertTo-RelativePath -Path $destinationPath -BasePath $DestinationRoot)
            source_name = $file.Name
            media_type = $extension.TrimStart('.')
            sha256 = $attachmentHash
            role = if ($extension -eq '.doc') { 'original-form' } elseif ($extension -eq '.docx') { 'converted-form' } else { 'rendered-form' }
            derived = $null
        }
        if ($extension -eq '.pdf') {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
            $derived = Get-PdfRecord -Source $file.FullName `
                -DestinationDirectory (Join-Path $destination 'derived\forms') `
                -TextFileName "$base.layout.txt" -Role 'form-rendering'
            $attachment.derived = $derived
        }
        $attachments.Add([pscustomobject]$attachment)
    }

    $manifest = [ordered]@{
        schema_version = 1
        id = $id
        code = $code
        source_listing = '../provenance/Источник.yml'
        standard = [ordered]@{
            original = (ConvertTo-RelativePath -Path $standardDestination -BasePath $DestinationRoot)
            sha256 = $standardHash
            derived = $standardRecord
        }
        attachments = $attachments.ToArray()
        interpretation_status = 'not-a-profile'
        notes = @(
            'This manifest identifies files and reproducible derivatives only.',
            'It does not classify normative requirements or determine document-profile applicability.'
        )
    }
    if (-not $DryRun) {
        Write-Utf8File -Path (Join-Path $destination 'manifest.json') -Text (($manifest | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
    }

    $catalogEntries.Add([pscustomobject]@{
        id = $id
        code = $code
        manifest = "$id/manifest.json"
        standard_sha256 = $standardHash
        attachment_count = $attachments.Count
    })
}

$listingHash = (Get-FileHash -LiteralPath $listingPath -Algorithm SHA256).Hash.ToLowerInvariant()
if (-not $DryRun) {
    # The listing is provenance metadata, not an original normative document.
    # Its curated URLs may be corrected while copied PDF/DOC originals remain
    # SHA-locked by Copy-VerifiedFile. STO-SOURCE-CORPUS
    Copy-VerifiedFile -Source $listingPath -Destination (Join-Path $DestinationRoot 'provenance\Источник.yml') -AllowMetadataUpdate | Out-Null
    $catalog = [ordered]@{
        schema_version = 1
        corpus = 'susu-official-education-documents'
        source_listing = [ordered]@{
            file = 'provenance/Источник.yml'
            sha256 = $listingHash
            url = 'https://k.susu.ru/index.php/15-dokumentatsiya/48-dokumenty-po-uchebnoj-deyatelnosti'
        }
        documents = $catalogEntries.ToArray()
        known_listing_discrepancies = @(
            'STO 21 declares cto_21_pril_g.doc twice with different labels; this is one physical file with two declared roles.'
        )
        scope = 'Source corpus only. No requirement inventory or profile inheritance is implied.'
    }
    Write-Utf8File -Path (Join-Path $DestinationRoot 'catalog.json') -Text (($catalog | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
}

$mode = if ($DryRun) { 'DRY RUN: no files copied or generated' } else { 'IMPORT COMPLETE' }
Write-Host $mode -ForegroundColor Green
Write-Host ("Input: {0}" -f $InputRoot)
Write-Host ("Destination: {0}" -f $DestinationRoot)
$catalogEntries | Sort-Object id | Format-Table id, code, attachment_count, standard_sha256 -AutoSize
