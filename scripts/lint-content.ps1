param(
    [string[]]$ContentPaths = @('content')
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$files = New-Object System.Collections.Generic.List[System.IO.FileInfo]
foreach ($path in $ContentPaths) {
    $full = if ([System.IO.Path]::IsPathRooted($path)) { $path } else { Join-Path $root $path }
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        $files.Add((Get-Item -LiteralPath $full))
    }
    elseif (Test-Path -LiteralPath $full -PathType Container) {
        Get-ChildItem -LiteralPath $full -Filter '*.md' -File | ForEach-Object { $files.Add($_) }
    }
    else {
        Write-Error "Content path not found: $path"
        exit 1
    }
}
$files = @($files | Sort-Object FullName -Unique)
$forbidden = '\\(vspace|hspace|fontsize|setlength|newgeometry|pagebreak|newpage)\b'
$violations = $files | Select-String -Pattern $forbidden

if ($violations) {
    $violations | ForEach-Object {
        Write-Error ("Forbidden formatting command: {0}:{1}: {2}" -f $_.Path, $_.LineNumber, $_.Line.Trim())
    }
    exit 1
}

Write-Host 'Semantic Markdown check passed.'
