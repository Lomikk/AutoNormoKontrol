function ConvertTo-WindowsCommandLineArgument {
    param([AllowEmptyString()][string]$Argument)

    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') {
        return $Argument
    }

    # Quote according to CommandLineToArgvW/C runtime rules. Backslashes only
    # need doubling when they precede a quote or the closing quote.
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq [char]92) {
            $backslashes++
            continue
        }

        if ($character -eq [char]34) {
            if ($backslashes -gt 0) {
                [void]$builder.Append([char]92, ($backslashes * 2))
            }
            [void]$builder.Append([char]92)
            [void]$builder.Append([char]34)
        }
        else {
            if ($backslashes -gt 0) {
                [void]$builder.Append([char]92, $backslashes)
            }
            [void]$builder.Append($character)
        }
        $backslashes = 0
    }

    if ($backslashes -gt 0) {
        [void]$builder.Append([char]92, ($backslashes * 2))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Resolve-PandocExecutable {
    $command = Get-Command pandoc -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Pandoc\pandoc.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Pandoc\pandoc.exe'),
        (Join-Path $env:ProgramFiles 'Pandoc\pandoc.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw 'pandoc was not found in PATH or a standard Windows installation directory.'
}

function Invoke-Utf8NativeCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string[]]$Arguments = @(),

        [string]$WorkingDirectory = (Get-Location).Path
    )

    # Windows PowerShell 5.1 otherwise decodes redirected native stderr using
    # a legacy console/ANSI code page. Pandoc and its Lua filters emit UTF-8.
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = (($Arguments | ForEach-Object {
        ConvertTo-WindowsCommandLineArgument ([string]$_)
    }) -join ' ')
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "Failed to start native command: $FilePath"
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StandardOutput = $stdout
            StandardError = $stderr
        }
    }
    finally {
        $process.Dispose()
    }
}

function Write-NativeCommandResult {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Result
    )

    if (-not [string]::IsNullOrEmpty($Result.StandardOutput)) {
        Write-Host -NoNewline $Result.StandardOutput
    }
    if (-not [string]::IsNullOrEmpty($Result.StandardError)) {
        Write-Host -NoNewline $Result.StandardError
    }
}
