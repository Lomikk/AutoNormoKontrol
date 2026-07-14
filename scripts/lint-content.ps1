$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$files = Get-ChildItem -LiteralPath (Join-Path $root 'content') -Filter '*.md' -File
$forbidden = '\\(vspace|hspace|fontsize|setlength|newgeometry|pagebreak|newpage)\b'
$violations = $files | Select-String -Pattern $forbidden

if ($violations) {
    $violations | ForEach-Object {
        Write-Error ("Forbidden formatting command: {0}:{1}: {2}" -f $_.Path, $_.LineNumber, $_.Line.Trim())
    }
    exit 1
}

Write-Host 'Semantic Markdown check passed.'
