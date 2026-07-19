# Структура проекта и CLI AutoNormoKontrol

Этот файл — канонический справочник по публичным командам и
границам каталогов. Корень репозитория содержит только движок;
единственное место живого документа — `Workspaces/<name>/`.

## Канонический CLI

Контекст команды определяется однозначно. Если в текущем каталоге нет
`project.yaml`, он не считается работой и команды сборки документа
отклоняются.

### Центральный каталог движка

```powershell
.\AutoNormoKontrol.cmd new <название работы>
.\AutoNormoKontrol.cmd new --profile <id> <название работы>
.\AutoNormoKontrol.cmd list-profiles
.\AutoNormoKontrol.cmd check
.\AutoNormoKontrol.cmd check --fast
.\AutoNormoKontrol.cmd doctor
.\AutoNormoKontrol.cmd install [--yes]
.\AutoNormoKontrol.cmd help
```

- `new` создаёт Draft-valid работу в `Workspaces/<название>` и никогда не
  перезаписывает существующую папку. Без `--profile` используется явно
  зарегистрированный профиль по умолчанию.
- `list-profiles` показывает только доверенные записи `profiles/catalog.json`;
  каталоги на диске автоматически не исполняются.
- `check --fast` выполняет coverage и тематические проверки без дорогого
  disposable-workspace lifecycle; обычный `check` дополнительно проверяет
  полный жизненный цикл и остаётся обязательным выпускным gate. Ни один режим
  не собирает «корневую курсовую».
- `doctor` проверяет Pandoc, TeX Live и PDF-инструменты.
- `install` может установить Pandoc через WinGet; TeX Live устанавливается
  отдельно.
- `help` показывает только команды движка.

### Каталог `Workspaces/<name>/`

```powershell
.\AutoNormoKontrol.cmd draft
.\AutoNormoKontrol.cmd strict
.\AutoNormoKontrol.cmd status
.\AutoNormoKontrol.cmd open
.\AutoNormoKontrol.cmd export
.\AutoNormoKontrol.cmd archive [метка]
.\AutoNormoKontrol.cmd help
```

- `draft` проверяет содержание и собирает черновой PDF с явными
  предупреждениями.
- `strict` выполняет финальную fail-closed сборку и не обходит semantic
  review и external acceptance.
- `status` показывает версию движка/профиля, статусы аудитов и
  последней сборки.
- `open` открывает `output/document.pdf`, а до первой публикации —
  последний PDF из `build/`.
- `export` атомарно публикует последний успешный и актуальный PDF как
  `output/document.pdf`; для Draft выводится предупреждение.
- `archive` по явному действию сохраняет неизменяемую копию и не
  перезаписывает существующий архив.
- `help` показывает только команды работы.

Команды `build`, `test`, `trace` и `context` не являются публичным CLI.
Для разработчика остаются прямые внутренние скрипты, но обычный
пользователь и пишущий агент работают только через команды выше.

Центральный launcher создаёт работу; после этого пользователь и пишущий агент
запускают тонкий `AutoNormoKontrol.cmd` внутри неё. Локальный launcher не
содержит движок. Перемещение работ за пределы `Workspaces` и установка
через `PATH` отложены.

## Границы каталогов

| Область | Что содержит | Правило |
|---|---|---|
| engine | `AutoNormoKontrol.cmd`, `scripts/`, `schemas/`, `VERSION` | Реализация программы; не изменять при написании курсовой |
| profile | `profiles/`, `profiles/catalog.json`, `profiles/active-profile.txt` | Доверенный нормативный и оформительский контракт; не изменять в обычной работе |
| workspace | `Workspaces/<name>/`: `project.yaml`, `gemini.cmd`, `content/`, `metadata.yaml`, `bibliography.bib`, `assets/`, `format-spec.yaml`, `compliance/`, `guide/` | Единственные живые данные одной работы; `project.yaml` задаёт точный порядок глав |
| sources | `sources/` | Канонические нормативные исходники; read-only при написании работы |
| tests | `tests/` | Искусственные fixture для проверки движка; не являются данными курсовой |
| docs | `README.md`, `AGENTS.md`, `docs/` | Документация и контракт разработчика |
| build | `Workspaces/<name>/build/` | Всегда generated/disposable; не редактировать и не считать исходником |
| output | `Workspaces/<name>/output/` | Стабильный PDF, export-report и явные архивы; не редактировать вручную |

Корневые `content/`, `metadata.yaml`, `bibliography.bib`, `assets/`,
`format-spec.yaml`, `compliance/`, document-PDF и evidence запрещены. Тестовые
данные живут в `tests/` или во временном каталоге, создаваемом `check`.

## Manifest отдельной работы

`project.yaml` записан в строгом JSON-совместимом подмножестве YAML и проверяется
по `schemas/workspace-v1.schema.json`. Он фиксирует:

- ID, путь manifest и digest одного профиля;
- минимальную и исходную версию движка;
- тип документа;
- непустой уникальный массив `document.content` в точном порядке сборки.

Неизвестные поля, traversal-пути, отсутствующие Markdown-файлы,
неправильный тип документа и несовместимая версия останавливают команду.
Изменившийся digest профиля показывается как предупреждение; тихого
обновления нет. `project.yaml` входит в document snapshot, поэтому изменение
порядка глав после Draft делает прежний export устаревшим.
Локальный `guide/profile-system-prompt.md` входит в starter закреплённого
профиля. Его отсутствие останавливает workspace-команду, но
содержимое является разрешённым override конкретной работы: пользователь может
уточнить инструкции агенту, не меняя центральный профиль.

## Агенты и контекст

Пишущий агент запускается в корне конкретного workspace через `gemini.cmd` и
сначала полностью читает локальные `AGENTS.md`, `GEMINI.md`,
`guide/profile-system-prompt.md`, `metadata.yaml` и при необходимости
`guide/notation-examples.md`. Системная инструкция имеет стабильное локальное
имя и получает исходное профильное содержимое при `new`; дальнейшие локальные
уточнения принадлежат только этой работе. В обычной задаче агенту не нужны `scripts/`, `profiles/`,
`sources/` и `tests/` центрального движка.

Проект не управляет контекстом Gemini CLI, Aider или OpenCode в MVP. Подобный
контракт можно рассматривать только после R1.4b и практического исследования
конкретного клиента.

Общий контракт для любого агента — точная диагностика `draft`,
ограничения локального `AGENTS.md` и правка исходника, а не generated TeX/PDF.
`draft --quiet` возвращает компактный код, `file:line` и сообщение, не предлагая
агенту читать технический лог. Структурированный внутренний отчёт сохраняется
для автоматизации и тестов, но не является обязательным контекстом агента.

## Маршрут разработчика

Этот раздел — каноническая карта чтения для изменения движка. Его задача — не
описать каждый файл повторно, а ограничить начальный контекст. Если в ходе
работы обнаружена реальная зависимость за пределами указанной строки, её нужно
добавить в эту таблицу вместе с regression-тестом.

| Изменяемая подсистема | Сначала читать | Основные исходники | Локальная проверка |
|---|---|---|---|
| Центральный CLI и режимы команд | этот файл, соответствующий блок CLI | `AutoNormoKontrol.cmd`, `scripts/autonormokontrol.ps1` | набор `engine-cli` |
| Создание и разрешение workspace | schema workspace и раздел «Manifest отдельной работы» | `scripts/workspace.ps1`, `resources/workspace-launchers/`, `schemas/workspace-v1.schema.json` | набор `engine-integration` |
| Загрузка и каталог профилей | `profile.yaml`, profile/catalog schemas; нормативный реестр не нужен, если его смысл не меняется | `scripts/profile.ps1`, `profiles/catalog.json`, `schemas/profile-*.schema.json` | набор `profile-contract` |
| Общая сборочная оркестрация | manifest тестового профиля и только используемые поля | `scripts/build.ps1`, snapshot/asset helpers | наборы `build-assets` и `engine-integration` |
| Нормативное правило профиля | `docs/REQUIREMENTS_V2.md`, source inventory, запись requirements и профильный prompt | `scripts/requirements.ps1`, `resources/filters/` для allow-listed общих алгоритмов, профильный Lua/TeX/postflight handler | `semantic-validator` и fixture с тем же ID |
| Quiet-диагностика | контракт R1.4 в roadmap | `scripts/diagnostics.ps1`, quiet-ветка CLI | diagnostic lifecycle fixtures |
| Публикация и архив | раздел workspace CLI | `scripts/workspace.ps1`, publish-ветки CLI | набор `engine-integration` |
| Документация пользователя | только документ соответствующей роли ниже | `README.md`, `docs/FAQ.md` | проверка ссылок и полный `check` перед выпуском |

Роли документации не должны дублироваться:

- `README.md` — установка и первый пользовательский сценарий;
- `docs/FAQ.md` — объяснение понятий и ограничений пользователю;
- этот файл — фактическая структура, публичный CLI и маршрут разработчика;
- `docs/ROADMAP.md` — незавершённые этапы и критерии их завершения;
- `docs/PRODUCT_DECISIONS.md` — подтверждённые пользовательские решения;
- `docs/decisions/ADR-*.md` — причины устойчивых архитектурных решений.

Тематический тест запускается для быстрого цикла, полный `check` остаётся
единственным выпускным gate изменений движка. Успех локального набора нельзя
использовать как основание пропустить остальные интеграционные проверки.
