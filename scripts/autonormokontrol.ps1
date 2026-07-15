[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = '',

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$CommandArguments = @()
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'utf8-native.ps1')
. (Join-Path $PSScriptRoot 'profile.ps1')
$script:ActiveProfile = $null
$script:ActiveProfilePath = Get-AutoNormoKontrolDefaultProfilePath -Root $root
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
        $script:ActiveProfile = Resolve-AutoNormoKontrolProfile `
            -Root $root -ProfilePath $script:ActiveProfilePath
    }
    return $script:ActiveProfile
}

function Add-ProcessPath {
    param([string]$Directory)

    if ([string]::IsNullOrWhiteSpace($Directory) -or
        -not (Test-Path -LiteralPath $Directory -PathType Container)) {
        return
    }

    $pathEntries = @($env:Path -split ';' | Where-Object { $_ })
    if ($pathEntries -notcontains $Directory) {
        # Preserve Windows' canonical `Path` spelling. Creating a second
        # uppercase `PATH` entry makes Start-Process fail in PowerShell 5.1.
        $env:Path = $Directory + ';' + $env:Path
    }
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

    Set-Location -LiteralPath $root
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
    $optional = @('winget', 'git', 'code')
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
    Write-Host ("Рабочая папка: {0}" -f $root)

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

    $profile = Get-ActiveProfile
    $semanticPath = Join-Path $root ([string]$profile.Data.compliance.semantic_review)
    $externalPath = Join-Path $root ([string]$profile.Data.compliance.external_acceptance)
    $semanticStatus = Get-DocumentYamlValue $semanticPath 'status'
    $externalStatus = Get-DocumentYamlValue $externalPath 'status'

    Write-Host ("Профиль:                {0}" -f $profile.ProfileId)
    Write-Host ("Digest профиля:         {0}" -f $profile.ProfileDigest)
    Write-Host ("Смысловой аудит:        {0}" -f $semanticStatus)
    Write-Host ("Внешняя приёмка:        {0}" -f $externalStatus)

    $pdfPath = Join-Path $root ([string]$profile.Data.outputs.pdf)
    if (Test-Path -LiteralPath $pdfPath -PathType Leaf) {
        $pdf = Get-Item -LiteralPath $pdfPath
        Write-Host ("Последний PDF:          {0}" -f $pdf.FullName)
        Write-Host ("Изменён:                {0}" -f $pdf.LastWriteTime)
        Write-Host ("Размер:                 {0:N0} байт" -f $pdf.Length)
    }
    else {
        Write-Host 'Последний PDF:          ещё не собран' -ForegroundColor DarkYellow
    }

    $reportPath = Join-Path $root ([string]$profile.Data.reports.postflight)
    if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
        try {
            $report = Get-Content -Raw -Encoding UTF8 -LiteralPath $reportPath | ConvertFrom-Json
            Write-Host ("PDF postflight:         {0} ({1} стр.)" -f $report.status, $report.pages)
        }
        catch {
            Write-Host 'PDF postflight:         отчёт повреждён или несовместим' -ForegroundColor DarkYellow
        }
    }

    $tracePath = Join-Path $root ([string]$profile.Data.reports.traceability_json)
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
    $pdfPath = Join-Path $root ([string]$profile.Data.outputs.pdf)
    if (-not (Test-Path -LiteralPath $pdfPath -PathType Leaf)) {
        Write-Failure 'PDF ещё не собран. Сначала выполните команду draft.'
        return 1
    }

    Start-Process -FilePath $pdfPath
    Write-Success ("Открыт {0}" -f $pdfPath)
    return 0
}

function Show-Help {
    Write-Title 'AutoNormoKontrol CLI'
    Write-Host 'Использование:'
    Write-Host '  AutoNormoKontrol.cmd                  интерактивное меню'
    Write-Host '  AutoNormoKontrol.cmd <команда>        однократный запуск'
    Write-Host ''
    Write-Host 'Команды:' -ForegroundColor DarkCyan
    Write-Host '  check    полный локальный цикл: тесты, затем Draft-сборка'
    Write-Host '  draft    собрать черновой PDF с явными предупреждениями'
    Write-Host '  strict   строгая fail-closed сборка для выпуска'
    Write-Host '  test     запустить тесты правил и coverage-gate'
    Write-Host '  trace    обновить отчёт трассировки требований СТО'
    Write-Host '  status   показать состояние аудита и последней сборки'
    Write-Host '  doctor   проверить Pandoc, TeX Live и PDF-инструменты'
    Write-Host '  install  установить доступные зависимости через WinGet'
    Write-Host '  open     открыть последний собранный PDF'
    Write-Host '  context  подготовить безопасный AI-контекст: context <capability> <content-file>'
    Write-Host '  help     показать эту справку'
    Write-Host ''
    Write-Host 'CLI не меняет semantic-review или external-acceptance и не обходит Strict-gate.'
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
    switch ($normalized) {
        { $_ -in @('help', '-h', '--help', '/?') } {
            $ExitCode.Value = Show-Help
            break
        }
        'doctor' {
            $ExitCode.Value = Show-Doctor
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
        'trace' {
            Write-Title 'Трассировка требований СТО'
            Invoke-ProjectScript 'report-traceability.ps1' `
                -Arguments @('-ProfilePath', $script:ActiveProfilePath) -ExitCode $ExitCode
            break
        }
        'context' {
            Write-Title 'AI context plan'
            if ($Arguments.Count -ne 2) {
                Write-Failure 'Использование: AutoNormoKontrol.cmd context <capability> <content-file>'
                Write-Host 'Пример: AutoNormoKontrol.cmd context edit-content content/00-introduction.md'
                $ExitCode.Value = 2
                break
            }
            Invoke-ProjectScript 'context-plan.ps1' `
                -Arguments @(
                    '-Capability', [string]$Arguments[0],
                    '-Target', [string]$Arguments[1],
                    '-ProfilePath', $script:ActiveProfilePath
                ) -ExitCode $ExitCode
            break
        }
        'test' {
            Write-Title 'Тесты соответствия'
            if (-not (Assert-Tools @('pandoc'))) {
                $ExitCode.Value = 127
                break
            }
            Invoke-ProjectScript 'test-compliance.ps1' -ExitCode $ExitCode
            break
        }
        { $_ -in @('draft', 'build') } {
            Write-Title 'Черновая сборка'
            if (-not (Assert-Tools @('pandoc', 'latexmk', 'lualatex', 'biber', 'pdfinfo', 'pdffonts', 'pdftotext'))) {
                $ExitCode.Value = 127
                break
            }
            Invoke-ProjectScript 'build.ps1' `
                @('-Mode', 'Draft', '-ProfilePath', $script:ActiveProfilePath) -ExitCode $ExitCode
            break
        }
        'strict' {
            Write-Title 'Строгая сборка'
            Write-Host 'Strict завершается ошибкой при любом неподтверждённом требовании.' -ForegroundColor Yellow
            if (-not (Assert-Tools @('pandoc', 'latexmk', 'lualatex', 'biber', 'pdfinfo', 'pdffonts', 'pdftotext'))) {
                $ExitCode.Value = 127
                break
            }
            Invoke-ProjectScript 'build.ps1' `
                @('-Mode', 'Strict', '-ProfilePath', $script:ActiveProfilePath) -ExitCode $ExitCode
            break
        }
        'check' {
            Write-Title 'Полная локальная проверка'
            if (-not (Assert-Tools @('pandoc', 'latexmk', 'lualatex', 'biber', 'pdfinfo', 'pdffonts', 'pdftotext'))) {
                $ExitCode.Value = 127
                break
            }
            Invoke-ProjectScript 'test-compliance.ps1' -ExitCode $ExitCode
            if ($ExitCode.Value -ne 0) {
                break
            }
            Invoke-ProjectScript 'build.ps1' `
                @('-Mode', 'Draft', '-ProfilePath', $script:ActiveProfilePath) -ExitCode $ExitCode
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
        Write-Host '1  Полная проверка (тесты + Draft)'
        Write-Host '2  Собрать Draft PDF'
        Write-Host '3  Запустить тесты'
        Write-Host '4  Показать состояние проекта'
        Write-Host '5  Обновить трассировку СТО'
        Write-Host '6  Проверить окружение'
        Write-Host '7  Установить зависимости'
        Write-Host '8  Собрать Strict PDF'
        Write-Host '9  Открыть последний PDF'
        Write-Host 'H  Справка'
        Write-Host 'Q  Выход'
        Write-Host ''

        $choice = (Read-Host 'Выберите действие').Trim().ToLowerInvariant()
        $selectedCommand = switch ($choice) {
            '1' { 'check' }
            '2' { 'draft' }
            '3' { 'test' }
            '4' { 'status' }
            '5' { 'trace' }
            '6' { 'doctor' }
            '7' { 'install' }
            '8' { 'strict' }
            '9' { 'open' }
            'h' { 'help' }
            'q' { return }
            default { '' }
        }

        if ([string]::IsNullOrWhiteSpace($selectedCommand)) {
            Write-Failure 'Такого пункта меню нет.'
        }
        else {
            $menuExitCode = 0
            Invoke-CliCommand $selectedCommand -ExitCode ([ref]$menuExitCode)
        }

        Write-Host ''
        [void](Read-Host 'Нажмите Enter, чтобы вернуться в меню')
    }
}

$finalExitCode = 0

try {
    Set-Location -LiteralPath $root
    Initialize-ToolPaths

    if ([string]::IsNullOrWhiteSpace($Command)) {
        Show-InteractiveMenu
    }
    else {
        if ($CommandArguments.Count -gt 0 -and $Command -notin @('install', 'context')) {
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
