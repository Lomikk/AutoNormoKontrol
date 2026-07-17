[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,

    [Parameter(Mandatory = $true)]
    [string]$PdfPath,

    [Parameter(Mandatory = $true)]
    [string]$TexPath,

    [Parameter(Mandatory = $true)]
    [string]$ReportPath
)

$ErrorActionPreference = "Stop"

function Resolve-WorkspacePath {
    param([string]$RelativePath)

    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "Postflight paths must be workspace-relative: $RelativePath"
    }

    $root = [System.IO.Path]::GetFullPath($ProjectRoot)
    $candidate = [System.IO.Path]::GetFullPath(
        (Join-Path $root $RelativePath)
    )

    $prefix = $root.TrimEnd("\", "/") +
        [System.IO.Path]::DirectorySeparatorChar

    if (-not $candidate.StartsWith(
        $prefix,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Postflight path leaves the workspace: $RelativePath"
    }

    return $candidate
}

try {
    $pdfFull = Resolve-WorkspacePath $PdfPath
    $texFull = Resolve-WorkspacePath $TexPath
    $reportFull = Resolve-WorkspacePath $ReportPath

    if (-not (Test-Path -LiteralPath $texFull -PathType Leaf)) {
        throw "Generated TeX was not found: $TexPath"
    }

    if (-not (Test-Path -LiteralPath $pdfFull -PathType Leaf)) {
        throw "Generated PDF was not found: $PdfPath"
    }

    $pdf = Get-Item -LiteralPath $pdfFull

    if ($pdf.Length -le 0) {
        throw "Generated PDF is empty."
    }

    $pages = $null
    $pdfInfo = Get-Command pdfinfo -ErrorAction SilentlyContinue

    if ($null -ne $pdfInfo) {
        $pageLine = & $pdfInfo.Source -enc UTF-8 $pdfFull |
            Select-String "^Pages:\s+([0-9]+)$" |
            Select-Object -First 1

        if ($null -ne $pageLine) {
            $pages = [int]$pageLine.Matches[0].Groups[1].Value
        }
    }

    $report = [ordered]@{
        version = 1
        profile_id = "susu-practice-article-v1"
        status = "passed"
        pdf = [ordered]@{
            path = $PdfPath.Replace("\", "/")
            sha256 = (
                Get-FileHash -LiteralPath $pdfFull -Algorithm SHA256
            ).Hash.ToLowerInvariant()
            bytes = $pdf.Length
            pages = $pages
        }
        tex = [ordered]@{
            path = $TexPath.Replace("\", "/")
            sha256 = (
                Get-FileHash -LiteralPath $texFull -Algorithm SHA256
            ).Hash.ToLowerInvariant()
        }
    }

    $directory = Split-Path $reportFull -Parent
    New-Item -ItemType Directory -Path $directory -Force | Out-Null

    [System.IO.File]::WriteAllText(
        $reportFull,
        (($report | ConvertTo-Json -Depth 8) + "`n"),
        [System.Text.UTF8Encoding]::new($false)
    )

    Write-Host "Article PDF postflight passed."
    exit 0
}
catch {
    Write-Error ("Article PDF postflight failed: {0}" -f $_.Exception.Message)
    exit 1
}
