[CmdletBinding()]
param(
    [string]$WorkspaceRoot = '',

    [Parameter(Position = 0)]
    [string]$Command = '',

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$CommandArguments = @()
)

$ErrorActionPreference = 'Stop'
$engineRoot = Split-Path -Parent $PSScriptRoot
$script:IsWorkspaceMode = -not [string]::IsNullOrWhiteSpace($WorkspaceRoot)
$workspaceRoot = if ($script:IsWorkspaceMode) {
    [System.IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\', '/')
}
else {
    $null
}
. (Join-Path $PSScriptRoot 'utf8-native.ps1')
. (Join-Path $PSScriptRoot 'diagnostics.ps1')
. (Join-Path $PSScriptRoot 'profile.ps1')
. (Join-Path $PSScriptRoot 'workspace.ps1')
$script:ActiveWorkspace = $null
$script:ActiveProfile = $null
$script:PowerShellExecutable = if ($PSVersionTable.PSEdition -eq 'Core') {
    (Get-Process -Id $PID).Path
}
else {
    Join-Path $PSHOME 'powershell.exe'
}

function Write-Title {
    param([string]$Text)

    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host ("  {0}" -f $Text) -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
}

function Write-Success {
    param([string]$Text)
    Write-Host ("OK  {0}" -f $Text) -ForegroundColor Green
}

function Write-Failure {
    param([string]$Text)
    Write-Host ("ERR {0}" -f $Text) -ForegroundColor Red
}

function Get-ActiveProfile {
    if ($null -eq $script:ActiveProfile) {
        $script:ActiveProfile = (Get-ActiveWorkspace).Profile
    }
    return $script:ActiveProfile
}

function Get-ActiveWorkspace {
    if (-not $script:IsWorkspaceMode) {
        throw 'Команда документа доступна только из Workspaces/<работа>.'
    }
    if ($null -eq $script:ActiveWorkspace) {
        $script:ActiveWorkspace = Resolve-AutoNormoKontrolWorkspace `
            -EngineRoot $engineRoot -WorkspaceRoot $workspaceRoot
    }
    return $script:ActiveWorkspace
}

function Add-ProcessPath {
    param([string]$Directory)

    if ([string]::IsNullOrWhiteSpace($Directory) -or
        -not (Test-Path -LiteralPath $Directory -PathType Container)) {
        return
    }

    # Put the verified tool directory first even when it already occurs later
    # in PATH. This avoids unrelated wrappers named pdfinfo/pdftotext shadowing
    # TeX Live. Preserve Windows' canonical `Path` spelling: creating a second
    # uppercase `PATH` entry makes Start-Process fail in PowerShell 5.1.
    $pathEntries = @($env:Path -split ';' | Where-Object {
        $_ -and -not $_.Equals($Directory, [StringComparison]::OrdinalIgnoreCase)
    })
    $env:Path = (@($Directory) + $pathEntries) -join ';'
}

function Initialize-ToolPaths {
    # TeX Live installs versioned Windows binaries below C:\texlive by default.
    # Select the newest local release without hard-coding a year.
    $texRoots = @('C:\texlive', (Join-Path $env:USERPROFILE 'texlive'))
    foreach ($texRoot in $texRoots) {
        if (-not (Test-Path -LiteralPath $texRoot -PathType Container)) { continue }

        $release = Get-ChildItem -LiteralPath $texRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d{4}$' } |
            Sort-Object Name -Descending |
            Select-Object -First 1
        if ($null -ne $release) {
            Add-ProcessPath (Join-Path $release.FullName 'bin\windows')
        }
    }
}

function Get-ToolCommand {
    param([string]$Name)

    if ($Name -eq 'pandoc') {
        try {
            return [pscustomobject]@{ Source = Resolve-PandocExecutable }
        }
        catch {
            return $null
        }
    }
    return Get-Command $Name -ErrorAction SilentlyContinue
}

function Get-MissingTools {
    param([string[]]$Names)

    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($name in $Names) {
        if ($null -eq (Get-ToolCommand $name)) {
            $missing.Add($name)
        }
    }
    return $missing.ToArray()
}

function Assert-Tools {
    param([string[]]$Names)

    $missing = @(Get-MissingTools $Names)
    if ($missing.Count -eq 0) { return $true }

    Write-Failure ("Не найдены зависимости: {0}" -f ($missing -join ', '))
    Write-Host 'Запустите `AutoNormoKontrol.cmd doctor` и проверьте установку/PATH.'
    return $false
}

function Install-Dependencies {
    param([switch]$AssumeYes)

    Write-Title 'Установка зависимостей'

    $missingPandoc = $null -eq (Get-ToolCommand 'pandoc')
    $texTools = @('latexmk', 'lualatex', 'biber', 'pdfinfo', 'pdffonts', 'pdftotext')
    $missingTexTools = @(Get-MissingTools $texTools)

    if (-not $missingPandoc -and $missingTexTools.Count -eq 0) {
        Write-Success 'Все обязательные зависимости уже установлены.'
        return 0
    }

    if ($missingPandoc) {
        Write-Host 'Будет установлен Pandoc:' -ForegroundColor Cyan
        Write-Host '  winget install --id JohnMacFarlane.Pandoc --exact --source winget'
    }

    if ($missingTexTools.Count -gt 0) {
        Write-Host ''
        Write-Host ("Не найдены компоненты TeX Live: {0}" -f ($missingTexTools -join ', ')) `
            -ForegroundColor Yellow
        Write-Host 'TeX Live сейчас отсутствует в каталоге Winget; MiKTeX не является заменой профиля проекта.'
        Write-Host 'Официальный установщик: https://tug.org/texlive/windows.html'
    }

    if ($missingPandoc) {
        $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
        if ($null -eq $winget) {
            Write-Failure 'WinGet не найден. Установите или обновите Microsoft App Installer.'
            return 127
        }

        $confirmed = $AssumeYes
        if (-not $confirmed) {
            $answer = (Read-Host 'Установить Pandoc через WinGet? [y/N]').Trim().ToLowerInvariant()
            $confirmed = $answer -in @('y', 'yes', 'д', 'да')
        }
        if (-not $confirmed) {
            Write-Host 'Установка Pandoc отменена.' -ForegroundColor Yellow
            return 1
        }
        else {
            & $winget.Source install `
                --id JohnMacFarlane.Pandoc `
                --exact `
                --source winget `
                --accept-source-agreements `
                --accept-package-agreements
            if ($LASTEXITCODE -ne 0) {
                Write-Failure ("WinGet завершился с кодом {0}." -f $LASTEXITCODE)
                return $LASTEXITCODE
            }

            if ($null -eq (Get-ToolCommand 'pandoc')) {
                Write-Host 'Pandoc установлен. Если он ещё не найден, откройте новую консоль.' -ForegroundColor Yellow
            }
            else {
                Write-Success 'Pandoc установлен и обнаружен.'
            }
        }
    }

    if ($missingTexTools.Count -gt 0) {
        Write-Failure 'Автоматическая установка не завершена: требуется установить TeX Live вручную.'
        return 1
    }

    return 0
}

function Invoke-ProjectScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [string[]]$Arguments = @(),
        [switch]$Quiet,
        [Parameter(Mandatory = $true)]
        [ref]$ExitCode
    )

    $ExitCode.Value = 0
    $path = Join-Path $PSScriptRoot $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Failure ("Скрипт не найден: {0}" -f $path)
        $ExitCode.Value = 2
        return
    }

    $shellArguments = @(
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $path
    ) + $Arguments

    Set-Location -LiteralPath $engineRoot
    if ($Quiet) {
        $quotedScript = "'" + $path.Replace("'", "''") + "'"
        $commandArguments = @($Arguments | ForEach-Object {
            $argument = [string]$_
            if ($argument -match '^-[A-Za-z][A-Za-z0-9-]*$') { $argument }
            else { "'" + $argument.Replace("'", "''") + "'" }
        })
        $quietCommand = @(
            '[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)'
            '$OutputEncoding = [Console]::OutputEncoding'
            '$ProgressPreference = ''SilentlyContinue'''
            ('& {0} {1}' -f $quotedScript, ($commandArguments -join ' '))
            'if ($null -eq $LASTEXITCODE) { if ($?) { exit 0 } else { exit 1 } }'
            'exit $LASTEXITCODE'
        ) -join '; '
        $result = Invoke-Utf8NativeCommand -FilePath $script:PowerShellExecutable `
            -Arguments @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-OutputFormat', 'Text',
                '-ExecutionPolicy', 'Bypass',
                '-Command', $quietCommand
            ) -WorkingDirectory $engineRoot
        $childExitCode = [int]$result.ExitCode
        $captured = $result.StandardOutput + $result.StandardError
        $logDirectory = Join-Path $workspaceRoot 'build/logs'
        New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $logDirectory (([IO.Path]::GetFileNameWithoutExtension($Name)) + '.log')),
            $captured,
            (New-Object System.Text.UTF8Encoding($false))
        )
        $ExitCode.Value = $childExitCode
        if ($childExitCode -eq 0) {
            $profile = Get-ActiveProfile
            Write-Host 'OK ANK-BUILD-SUCCEEDED' -ForegroundColor Green
            Write-Host ('PDF: {0}' -f ([string]$profile.Data.outputs.pdf).Replace('\', '/'))
        }
        else {
            $workspace = Get-ActiveWorkspace
            $diagnostics = @(ConvertTo-AutoNormoKontrolDiagnostics `
                -Text $captured -WorkspaceRoot $workspaceRoot `
                -ContentPaths $workspace.ContentPaths)
            $diagnosticsPath = Join-Path $workspaceRoot 'build/diagnostics.json'
            $document = [pscustomobject][ordered]@{
                version = 1
                profile_id = $workspace.Profile.ProfileId
                command = ([IO.Path]::GetFileNameWithoutExtension($Name))
                exit_code = $childExitCode
                errors = $diagnostics
            }
            [System.IO.File]::WriteAllText(
                $diagnosticsPath,
                ($document | ConvertTo-Json -Depth 8),
                (New-Object System.Text.UTF8Encoding($false))
            )
            Write-AutoNormoKontrolCompactDiagnostics -Diagnostics $diagnostics
        }
        return
    }

    # Keep the child attached to the console so users see live build output.
    # Native UTF-8 decoding is handled at each Pandoc invocation.
    & $script:PowerShellExecutable @shellArguments
    $childExitCode = $LASTEXITCODE
    if ($null -eq $childExitCode) { $childExitCode = if ($?) { 0 } else { 1 } }
    $ExitCode.Value = [int]$childExitCode

    Write-Host ''
    if ($childExitCode -eq 0) {
        Write-Success ("Команда завершена: {0}" -f $Name)
    }
    else {
        Write-Failure ("Команда завершилась с кодом {0}: {1}" -f $childExitCode, $Name)
    }
    return
}

function Show-Doctor {
    Write-Title 'Диагностика окружения'

    $required = @('pandoc', 'latexmk', 'lualatex', 'biber', 'pdfinfo', 'pdffonts', 'pdftotext')
    $optional = @('winget', 'git', 'code', 'gemini')
    $missingRequired = New-Object System.Collections.Generic.List[string]

    foreach ($name in $required) {
        $tool = Get-ToolCommand $name
        if ($null -eq $tool) {
            Write-Failure ("{0,-12} не найден" -f $name)
            $missingRequired.Add($name)
        }
        else {
            Write-Success ("{0,-12} {1}" -f $name, $tool.Source)
        }
    }

    Write-Host ''
    Write-Host 'Необязательные инструменты:' -ForegroundColor DarkCyan
    foreach ($name in $optional) {
        $tool = Get-ToolCommand $name
        if ($null -eq $tool) {
            Write-Host ("--  {0,-12} не найден" -f $name) -ForegroundColor DarkYellow
        }
        else {
            Write-Host ("OK  {0,-12} {1}" -f $name, $tool.Source) -ForegroundColor Green
        }
    }

    Write-Host ''
    Write-Host ("PowerShell:    {0} ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
    Write-Host ("Движок:        {0}" -f $engineRoot)
    Write-Host 'Контекст:      центральный движок'

    if ($missingRequired.Count -gt 0) {
        Write-Failure ("Не хватает обязательных инструментов: {0}" -f ($missingRequired -join ', '))
        return 1
    }

    Write-Success 'Окружение готово к сборке.'
    return 0
}

function Get-DocumentYamlValue {
    param(
        [string]$Path,
        [string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'нет файла' }
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    # Both acceptance files keep document-level values exactly two spaces
    # below their single root mapping. Deeper per-rule statuses are ignored.
    $pattern = '(?m)^ {2}' + [regex]::Escape($Name) + ':\s*(.+)$'
    $match = [regex]::Match($text, $pattern)
    if ($match.Success) {
        return $match.Groups[1].Value.Trim().Trim('"').Trim("'")
    }
    return 'не указано'
}

function Show-Status {
    Write-Title 'Состояние проекта'

    $workspace = Get-ActiveWorkspace
    $profile = Get-ActiveProfile
    $semanticPath = Join-Path $workspaceRoot ([string]$profile.Data.compliance.semantic_review)
    $externalPath = Join-Path $workspaceRoot ([string]$profile.Data.compliance.external_acceptance)
    $semanticStatus = Get-DocumentYamlValue $semanticPath 'status'
    $externalStatus = Get-DocumentYamlValue $externalPath 'status'

    Write-Host ("Workspace:              {0}" -f $workspaceRoot)
    Write-Host ("Профиль:                {0}" -f $profile.ProfileId)
    Write-Host ("Digest профиля:         {0}" -f $profile.ProfileDigest)
    $digestState = if ($workspace.ProfileDigestMatches) { 'совпадает' } else { 'ИЗМЕНИЛСЯ' }
    Write-Host ("Зафиксированный digest: {0} ({1})" -f
        $workspace.PinnedProfileDigest, $digestState)
    $engineState = if ($workspace.EngineVersionMatches) { 'совпадает' } else { 'ДРУГАЯ ВЕРСИЯ' }
    Write-Host ("Версия движка:          {0}; создано на {1} ({2})" -f
        $workspace.EngineVersion, $workspace.CreatedWithEngineVersion, $engineState)
    Write-Host ("Смысловой аудит:        {0}" -f $semanticStatus)
    Write-Host ("Внешняя приёмка:        {0}" -f $externalStatus)

    $pdfPath = Join-Path $workspaceRoot ([string]$profile.Data.outputs.pdf)
    if (Test-Path -LiteralPath $pdfPath -PathType Leaf) {
        $pdf = Get-Item -LiteralPath $pdfPath
        Write-Host ("Последний PDF:          {0}" -f $pdf.FullName)
        Write-Host ("Изменён:                {0}" -f $pdf.LastWriteTime)
        Write-Host ("Размер:                 {0:N0} байт" -f $pdf.Length)
    }
    else {
        Write-Host 'Последний PDF:          ещё не собран' -ForegroundColor DarkYellow
    }

    $publishedPath = Join-Path $workspaceRoot $script:AutoNormoKontrolPublishedPdf
    if (Test-Path -LiteralPath $publishedPath -PathType Leaf) {
        Write-Host ("Опубликованный PDF:      {0}" -f $publishedPath)
    }
    else {
        Write-Host 'Опубликованный PDF:      ещё не создан' -ForegroundColor DarkYellow
    }

    $reportPath = Join-Path $workspaceRoot ([string]$profile.Data.reports.postflight)
    if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
        try {
            $report = Get-Content -Raw -Encoding UTF8 -LiteralPath $reportPath | ConvertFrom-Json
            # R1/workspace: profile postflight reports use a common status, but
            # older experimental reports stored the page count below pdf.pages.
            # Accept both layouts so status remains useful across profile v1.
            $pageCount = $null
            if ($null -ne $report.PSObject.Properties['pages']) {
                $pageCount = $report.pages
            }
            elseif ($null -ne $report.PSObject.Properties['pdf'] -and
                $null -ne $report.pdf -and
                $null -ne $report.pdf.PSObject.Properties['pages']) {
                $pageCount = $report.pdf.pages
            }
            $pageSummary = if ($null -eq $pageCount -or
                [string]::IsNullOrWhiteSpace([string]$pageCount)) {
                'число страниц не указано'
            }
            else {
                '{0} стр.' -f $pageCount
            }
            Write-Host ("PDF postflight:         {0} ({1})" -f $report.status, $pageSummary)
        }
        catch {
            Write-Host 'PDF postflight:         отчёт повреждён или несовместим' -ForegroundColor DarkYellow
        }
    }

    $tracePath = Join-Path $workspaceRoot ([string]$profile.Data.reports.traceability_json)
    if (Test-Path -LiteralPath $tracePath -PathType Leaf) {
        try {
            $trace = Get-Content -Raw -Encoding UTF8 -LiteralPath $tracePath | ConvertFrom-Json
            Write-Host ("Трассировка СТО:        {0} пунктов; пропусков доказательств: {1}" -f
                $trace.counts.total, $trace.counts.missing_evidence)
        }
        catch {
            Write-Host 'Трассировка СТО:        отчёт повреждён или несовместим' -ForegroundColor DarkYellow
        }
    }

    Write-Host ''
    if ($semanticStatus -ne 'pass' -or $externalStatus -ne 'accepted') {
        Write-Host 'Strict остаётся закрыт, пока аудит и внешняя приёмка не завершены.' -ForegroundColor Yellow
    }
    return 0
}

function Open-ResultPdf {
    $profile = Get-ActiveProfile
    $published = Join-Path $workspaceRoot $script:AutoNormoKontrolPublishedPdf
    $pdfPath = if (Test-Path -LiteralPath $published -PathType Leaf) {
        $published
    }
    else {
        Join-Path $workspaceRoot ([string]$profile.Data.outputs.pdf)
    }
    if (-not (Test-Path -LiteralPath $pdfPath -PathType Leaf)) {
        Write-Failure 'PDF ещё не собран. Сначала выполните команду draft.'
        return 1
    }

    Start-Process -FilePath $pdfPath
    Write-Success ("Открыт {0}" -f $pdfPath)
    return 0
}

function New-WorkspaceFromCli {
    param([string[]]$Arguments)

    $profilePath = ''
    $name = ''
    if ($Arguments.Count -eq 1) {
        $name = [string]$Arguments[0]
    }
    elseif ($Arguments.Count -eq 3 -and [string]$Arguments[0] -ceq '--profile') {
        $catalogEntry = Get-AutoNormoKontrolCatalogProfile `
            -Root $engineRoot -ProfileId ([string]$Arguments[1])
        $profilePath = $catalogEntry.Manifest
        $name = [string]$Arguments[2]
    }
    else {
        Write-Failure 'Использование: AutoNormoKontrol.cmd new [--profile <id>] <название работы>'
        return 2
    }
    if ([string]::IsNullOrWhiteSpace($name)) {
        Write-Failure 'Название работы не может быть пустым.'
        return 2
    }
    $created = New-AutoNormoKontrolWorkspace `
        -EngineRoot $engineRoot -Name $name -ProfilePath $profilePath
    Write-Success ("Создана новая работа: {0}" -f $created.WorkspaceRoot)
    Write-Host ("Профиль: {0}" -f $created.Profile.ProfileId)
    Write-Host 'Следующий шаг:'
    Write-Host ("  cd `"{0}`"" -f $created.WorkspaceRoot)
    Write-Host '  .\gemini.cmd'
    Write-Host 'или без агента:'
    Write-Host '  .\AutoNormoKontrol.cmd draft'
    return 0
}

function Show-ProfileCatalog {
    $catalog = Get-AutoNormoKontrolProfileCatalog -Root $engineRoot
    Write-Title 'Доступные профили'
    foreach ($entry in @($catalog.Entries)) {
        $default = if ($entry.IsDefault) { ' [по умолчанию]' } else { '' }
        Write-Host ("{0}{1}" -f $entry.Name, $default) -ForegroundColor Cyan
        Write-Host ("  ID: {0}" -f $entry.Id)
        Write-Host ("  Статус: {0}" -f $entry.Status)
        Write-Host ("  Manifest: {0}" -f $entry.Manifest)
    }
    return 0
}

function Select-ProfileIdInteractive {
    $entries = @((Get-AutoNormoKontrolProfileCatalog -Root $engineRoot).Entries)
    if ($entries.Count -eq 1) {
        Write-Host ("Профиль: {0}" -f $entries[0].Name)
        return $entries[0].Id
    }
    Write-Host 'Выберите профиль:' -ForegroundColor DarkCyan
    for ($index = 0; $index -lt $entries.Count; $index++) {
        $default = if ($entries[$index].IsDefault) { ' [по умолчанию]' } else { '' }
        Write-Host ("{0}  {1}{2}" -f ($index + 1), $entries[$index].Name, $default)
    }
    while ($true) {
        $choice = (Read-Host 'Номер профиля').Trim()
        $number = 0
        if ([int]::TryParse($choice, [ref]$number) -and
            $number -ge 1 -and $number -le $entries.Count) {
            return $entries[$number - 1].Id
        }
        Write-Failure 'Укажите номер профиля из списка.'
    }
}

function Export-WorkspacePdf {
    $result = Export-AutoNormoKontrolPdf -Workspace (Get-ActiveWorkspace)
    if ($result.Mode -eq 'draft') {
        Write-Host 'WARNING: опубликован Draft PDF; это не подтверждение Strict-готовности.' `
            -ForegroundColor Yellow
    }
    Write-Success ("Опубликован постоянный PDF: {0}" -f $result.Path)
    return 0
}

function Archive-WorkspacePdf {
    param([string[]]$Arguments)

    if ($Arguments.Count -gt 1) {
        Write-Failure 'Использование: AutoNormoKontrol.cmd archive [метка]'
        return 2
    }
    $label = if ($Arguments.Count -eq 1) { [string]$Arguments[0] } else { '' }
    $path = Archive-AutoNormoKontrolPdf -Workspace (Get-ActiveWorkspace) -Label $label
    Write-Success ("Создан архивный снимок: {0}" -f $path)
    return 0
}

function Show-Help {
    Write-Title 'AutoNormoKontrol CLI'
    Write-Host 'Использование:'
    Write-Host '  AutoNormoKontrol.cmd                  интерактивное меню'
    Write-Host '  AutoNormoKontrol.cmd <команда>        однократный запуск'
    Write-Host ''
    Write-Host 'Команды:' -ForegroundColor DarkCyan
    if ($script:IsWorkspaceMode) {
        Write-Host '  draft [--quiet]   собрать черновой PDF; --quiet даёт компактный вывод'
        Write-Host '  strict [--quiet]  строгая fail-closed сборка; --quiet даёт компактный вывод'
        Write-Host '  status   показать состояние аудита и последней сборки'
        Write-Host '  open     открыть последний собранный PDF'
        Write-Host '  export   опубликовать проверенный PDF как output/document.pdf'
        Write-Host '  archive  сохранить неизменяемую копию: archive [метка]'
        Write-Host '  help     показать эту справку'
        Write-Host ''
        Write-Host 'Команды документа работают только в Workspaces/<работа>.'
        Write-Host 'CLI не меняет журналы приёмки и не обходит Strict-gate.'
    }
    else {
        Write-Host '  new            создать работу: new [--profile <id>] <название>'
        Write-Host '  list-profiles  показать зарегистрированные профили документов'
        Write-Host '  check    проверить код движка и полный жизненный цикл тестовой работы'
        Write-Host '  doctor   проверить Pandoc, TeX Live и PDF-инструменты'
        Write-Host '  install  установить доступные зависимости через WinGet'
        Write-Host '  help     показать эту справку'
        Write-Host ''
        Write-Host 'Корень содержит только движок. Документы находятся в Workspaces/<работа>.'
    }
    return 0
}

function Invoke-CliCommand {
    param(
        [string]$Name,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)]
        [ref]$ExitCode
    )

    $ExitCode.Value = 0
    $normalized = $Name.Trim().ToLowerInvariant()
    if ($normalized -in @('-h', '--help', '/?')) { $normalized = 'help' }
    $centralCommands = @('new', 'list-profiles', 'check', 'doctor', 'install', 'help')
    $workspaceCommands = @('draft', 'strict', 'status', 'open', 'export', 'archive', 'help')
    $allowed = if ($script:IsWorkspaceMode) { $workspaceCommands } else { $centralCommands }
    if ($normalized -notin $allowed) {
        $known = @($centralCommands + $workspaceCommands | Select-Object -Unique)
        if ($normalized -in $known) {
            $location = if ($script:IsWorkspaceMode) {
                'центрального AutoNormoKontrol.cmd'
            }
            else {
                'Workspaces/<работа>/AutoNormoKontrol.cmd'
            }
            Write-Failure ("Команда '{0}' доступна только из {1}." -f $normalized, $location)
        }
        else {
            Write-Failure ("Неизвестная команда: {0}" -f $Name)
        }
        Write-Host 'Используйте AutoNormoKontrol.cmd help для списка команд.'
        $ExitCode.Value = 2
        return
    }
    switch ($normalized) {
        'help' {
            $ExitCode.Value = Show-Help
            break
        }
        'doctor' {
            $ExitCode.Value = Show-Doctor
            break
        }
        'new' {
            Write-Title 'Новая работа'
            $ExitCode.Value = New-WorkspaceFromCli -Arguments $Arguments
            break
        }
        'list-profiles' {
            $ExitCode.Value = Show-ProfileCatalog
            break
        }
        'install' {
            $ExitCode.Value = Install-Dependencies -AssumeYes:($Arguments -contains '--yes')
            break
        }
        'status' {
            $ExitCode.Value = Show-Status
            break
        }
        'open' {
            $ExitCode.Value = Open-ResultPdf
            break
        }
        'export' {
            Write-Title 'Публикация PDF'
            $ExitCode.Value = Export-WorkspacePdf
            break
        }
        'archive' {
            Write-Title 'Архивный снимок PDF'
            $ExitCode.Value = Archive-WorkspacePdf -Arguments $Arguments
            break
        }
        'draft' {
            $quiet = $Arguments.Count -eq 1 -and [string]$Arguments[0] -ceq '--quiet'
            if ($Arguments.Count -gt 0 -and -not $quiet) {
                Write-Failure 'Использование: AutoNormoKontrol.cmd draft [--quiet]'
                $ExitCode.Value = 2
                break
            }
            if (-not $quiet) { Write-Title 'Черновая сборка' }
            if (-not (Assert-Tools @('pandoc', 'latexmk', 'lualatex', 'biber', 'pdfinfo', 'pdffonts', 'pdftotext'))) {
                $ExitCode.Value = 127
                break
            }
            Invoke-ProjectScript 'build.ps1' `
                @('-Mode', 'Draft', '-WorkspaceRoot', $workspaceRoot) `
                -Quiet:$quiet -ExitCode $ExitCode
            break
        }
        'strict' {
            $quiet = $Arguments.Count -eq 1 -and [string]$Arguments[0] -ceq '--quiet'
            if ($Arguments.Count -gt 0 -and -not $quiet) {
                Write-Failure 'Использование: AutoNormoKontrol.cmd strict [--quiet]'
                $ExitCode.Value = 2
                break
            }
            if (-not $quiet) {
                Write-Title 'Строгая сборка'
                Write-Host 'Strict завершается ошибкой при любом неподтверждённом требовании.' -ForegroundColor Yellow
            }
            if (-not (Assert-Tools @('pandoc', 'latexmk', 'lualatex', 'biber', 'pdfinfo', 'pdffonts', 'pdftotext'))) {
                $ExitCode.Value = 127
                break
            }
            Invoke-ProjectScript 'build.ps1' `
                @('-Mode', 'Strict', '-WorkspaceRoot', $workspaceRoot) `
                -Quiet:$quiet -ExitCode $ExitCode
            break
        }
        'check' {
            Write-Title 'Полная локальная проверка'
            if (-not (Assert-Tools @('pandoc', 'latexmk', 'lualatex', 'biber', 'pdfinfo', 'pdffonts', 'pdftotext'))) {
                $ExitCode.Value = 127
                break
            }
            Invoke-ProjectScript 'test-compliance.ps1' -ExitCode $ExitCode
            break
        }
        default {
            Write-Failure ("Неизвестная команда: {0}" -f $Name)
            Write-Host 'Используйте `AutoNormoKontrol.cmd help` для списка команд.'
            $ExitCode.Value = 2
            break
        }
    }
    return
}

function Show-InteractiveMenu {
    while ($true) {
        Write-Title 'AutoNormoKontrol'
        if ($script:IsWorkspaceMode) {
            Write-Host '1  Собрать Draft PDF'
            Write-Host '2  Собрать Strict PDF'
            Write-Host '3  Показать состояние работы'
            Write-Host '4  Открыть последний PDF'
            Write-Host '5  Опубликовать output/document.pdf'
            Write-Host '6  Создать архивный снимок'
        }
        else {
            Write-Host '1  Создать новую работу'
            Write-Host '2  Показать профили документов'
            Write-Host '3  Проверить движок'
            Write-Host '4  Проверить окружение'
            Write-Host '5  Установить зависимости'
        }
        Write-Host 'H  Справка'
        Write-Host 'Q  Выход'
        Write-Host ''

        $choice = (Read-Host 'Выберите действие').Trim().ToLowerInvariant()
        $selectedCommand = if ($script:IsWorkspaceMode) {
            switch ($choice) {
                '1' { 'draft' }
                '2' { 'strict' }
                '3' { 'status' }
                '4' { 'open' }
                '5' { 'export' }
                '6' { 'archive' }
                'h' { 'help' }
                'q' { return }
                default { '' }
            }
        }
        else {
            switch ($choice) {
                '1' { 'new' }
                '2' { 'list-profiles' }
                '3' { 'check' }
                '4' { 'doctor' }
                '5' { 'install' }
                'h' { 'help' }
                'q' { return }
                default { '' }
            }
        }

        if ([string]::IsNullOrWhiteSpace($selectedCommand)) {
            Write-Failure 'Такого пункта меню нет.'
        }
        else {
            $menuArguments = @()
            if ($selectedCommand -eq 'new') {
                $profileId = Select-ProfileIdInteractive
                $menuArguments = @(
                    '--profile',
                    $profileId,
                    (Read-Host 'Название новой работы').Trim()
                )
            }
            elseif ($selectedCommand -eq 'archive') {
                $archiveLabel = (Read-Host 'Метка архива (можно оставить пустой)').Trim()
                if (-not [string]::IsNullOrWhiteSpace($archiveLabel)) {
                    $menuArguments = @($archiveLabel)
                }
            }
            $menuExitCode = 0
            Invoke-CliCommand $selectedCommand -Arguments $menuArguments `
                -ExitCode ([ref]$menuExitCode)
        }

        Write-Host ''
        [void](Read-Host 'Нажмите Enter, чтобы вернуться в меню')
    }
}

$finalExitCode = 0

try {
    Set-Location -LiteralPath $engineRoot
    Initialize-ToolPaths

    if ([string]::IsNullOrWhiteSpace($Command)) {
        Show-InteractiveMenu
    }
    else {
        if ($CommandArguments.Count -gt 0 -and
            -not ($Command -in @('draft', 'strict') -and
                $CommandArguments.Count -eq 1 -and $CommandArguments[0] -ceq '--quiet') -and
            $Command -notin @('install', 'new', 'archive')) {
            Write-Host ("Примечание: дополнительные аргументы пока не используются: {0}" -f
                ($CommandArguments -join ' ')) -ForegroundColor DarkYellow
        }
        Invoke-CliCommand $Command -Arguments $CommandArguments -ExitCode ([ref]$finalExitCode)
    }
}
catch {
    Write-Failure $_.Exception.Message
    $finalExitCode = 1
}

exit ([int]$finalExitCode)
