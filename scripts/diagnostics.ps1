function Find-AutoNormoKontrolSourceLocation {
    param(
        [string]$Message,
        [string]$WorkspaceRoot,
        [string[]]$ContentPaths
    )

    $explicit = [regex]::Match($Message, '(?<path>content[/\\][^:\r\n]+[.]md)(?::(?<line>[0-9]+))?')
    if ($explicit.Success) {
        return [pscustomobject]@{
            File = $explicit.Groups['path'].Value.Replace('\', '/')
            Line = if ($explicit.Groups['line'].Success) { [int]$explicit.Groups['line'].Value } else { $null }
            ObjectId = $null
        }
    }

    $objectMatch = [regex]::Match($Message, '(?<id>(?:fig|tbl|eq|app):[A-Za-z0-9._-]+)')
    $needle = if ($objectMatch.Success) { $objectMatch.Groups['id'].Value } else { '' }
    if ([string]::IsNullOrWhiteSpace($needle)) {
        $citation = [regex]::Match($Message, '(?i)citation\s+[`''"]?(?<id>[A-Za-z0-9:._/-]+)')
        if ($citation.Success) { $needle = '@' + $citation.Groups['id'].Value }
    }
    if ([string]::IsNullOrWhiteSpace($needle)) {
        return [pscustomobject]@{ File = $null; Line = $null; ObjectId = $null }
    }

    $matches = @()
    $declarationNeedle = if ($objectMatch.Success) { '{#' + $needle } else { $needle }
    foreach ($relative in @($ContentPaths)) {
        $full = Join-Path $WorkspaceRoot $relative
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        $lines = Get-Content -LiteralPath $full -Encoding UTF8
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if ($lines[$index].Contains($declarationNeedle)) {
                $matches += [pscustomobject]@{
                    File = ([string]$relative).Replace('\', '/')
                    Line = $index + 1
                    ObjectId = if ($objectMatch.Success) { $objectMatch.Groups['id'].Value } else { $null }
                }
            }
        }
    }
    if ($matches.Count -eq 0 -and $objectMatch.Success) {
        foreach ($relative in @($ContentPaths)) {
            $full = Join-Path $WorkspaceRoot $relative
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
            $lines = Get-Content -LiteralPath $full -Encoding UTF8
            for ($index = 0; $index -lt $lines.Count; $index++) {
                if ($lines[$index].Contains($needle)) {
                    $matches += [pscustomobject]@{
                        File = ([string]$relative).Replace('\', '/')
                        Line = $index + 1
                        ObjectId = $objectMatch.Groups['id'].Value
                    }
                }
            }
        }
    }
    if ($matches.Count -eq 1) { return $matches[0] }
    return [pscustomobject]@{
        File = $null
        Line = $null
        ObjectId = if ($objectMatch.Success) { $objectMatch.Groups['id'].Value } else { $null }
    }
}

function ConvertTo-AutoNormoKontrolDiagnostics {
    param(
        [string]$Text,
        [string]$WorkspaceRoot,
        [string[]]$ContentPaths
    )

    $events = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $pattern = '(?m)^(?:ERROR\s+)?(?<code>(?:STO-[A-Za-z0-9.-]+|ARTICLE-[A-Z0-9-]+)):\s*(?<message>[^\r\n]+)'
    foreach ($match in [regex]::Matches($Text, $pattern)) {
        $code = $match.Groups['code'].Value
        $message = $match.Groups['message'].Value.Trim()
        $key = $code + [char]0 + $message
        if (-not $seen.Add($key)) { continue }
        $location = Find-AutoNormoKontrolSourceLocation `
            -Message $message -WorkspaceRoot $WorkspaceRoot -ContentPaths $ContentPaths
        $events.Add([pscustomobject][ordered]@{
            code = $code
            severity = 'error'
            message = $message
            file = $location.File
            line = $location.Line
            object_id = $location.ObjectId
        })
    }

    if ($events.Count -eq 0) {
        $code = 'ANK-BUILD-FAILED'
        $message = 'The build failed without a structured diagnostic.'
        $citation = [regex]::Match($Text, '(?im)^.*citation\s+[`''"]?(?<id>[A-Za-z0-9:._/-]+).*not found.*$')
        if ($citation.Success) {
            $code = 'ANK-CITATION-NOT-FOUND'
            $message = $citation.Value.Trim()
        }
        elseif ($Text -match 'Overfull \\[hv]box') {
            $code = 'ANK-LATEX-OVERFULL'
            $message = 'TeX reported content outside the permitted area.'
        }
        elseif ($Text -match 'Error running filter') {
            $code = 'ANK-PANDOC-FILTER-FAILED'
            $message = 'A Pandoc filter failed without a structured diagnostic.'
        }
        elseif ($Text -match '(?i)latexmk.*error') {
            $code = 'ANK-LATEX-FAILED'
            $message = 'LaTeX could not build the document.'
        }
        $location = Find-AutoNormoKontrolSourceLocation `
            -Message ($message + "`n" + $Text) `
            -WorkspaceRoot $WorkspaceRoot -ContentPaths $ContentPaths
        $events.Add([pscustomobject][ordered]@{
            code = $code; severity = 'error'; message = $message
            file = $location.File; line = $location.Line; object_id = $location.ObjectId
        })
    }
    return $events.ToArray()
}

function Write-AutoNormoKontrolCompactDiagnostics {
    param([object[]]$Diagnostics)
    Write-Host ('FAILED: {0} error(s)' -f $Diagnostics.Count) -ForegroundColor Red
    foreach ($event in $Diagnostics) {
        Write-Host ''
        Write-Host ('ERROR {0}' -f $event.code) -ForegroundColor Red
        if (-not [string]::IsNullOrWhiteSpace([string]$event.file)) {
            $coordinate = [string]$event.file
            if ($null -ne $event.line) { $coordinate += ':' + $event.line }
            Write-Host $coordinate
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$event.object_id)) {
            Write-Host ('OBJECT: {0}; source location unresolved' -f $event.object_id)
        }
        else {
            Write-Host 'SOURCE: unresolved'
        }
        Write-Host ([string]$event.message)
    }
}
