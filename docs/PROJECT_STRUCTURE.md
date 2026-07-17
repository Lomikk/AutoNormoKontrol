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
.\AutoNormoKontrol.cmd doctor
.\AutoNormoKontrol.cmd install [--yes]
.\AutoNormoKontrol.cmd help
```

- `new` создаёт Draft-valid работу в `Workspaces/<название>` и никогда не
  перезаписывает существующую папку. Без `--profile` используется явно
  зарегистрированный профиль по умолчанию.
- `list-profiles` показывает только доверенные записи `profiles/catalog.json`;
  каталоги на диске автоматически не исполняются.
- `check` проверяет сам движок, профиль и полный жизненный цикл на
  одноразовом тестовом workspace. Он не собирает «корневую курсовую».
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
Отдельно локальный `guide/profile-system-prompt.md` обязан точно совпадать с
системной инструкцией закреплённого профиля: его отсутствие или изменение
останавливает workspace-команду, поскольку агентский контракт нельзя обновлять
неявно.

## Агенты и контекст

Пишущий агент запускается в корне конкретного workspace через `gemini.cmd` и
сначала полностью читает локальные `AGENTS.md`, `GEMINI.md`,
`guide/profile-system-prompt.md`, `metadata.yaml` и при необходимости
`guide/notation-examples.md`. Системная инструкция имеет стабильное локальное
имя, но профильное содержимое; resolver проверяет её точное совпадение с
закреплённым профилем. В обычной задаче агенту не нужны `scripts/`, `profiles/`,
`sources/` и `tests/` центрального движка.

Проект не управляет контекстом Gemini CLI, Aider или OpenCode в MVP. Подобный
контракт можно рассматривать только после R1.4b и практического исследования
конкретного клиента.

Общий контракт для любого агента — точная диагностика `draft`,
ограничения локального `AGENTS.md` и правка исходника, а не generated TeX/PDF.
R1.4b добавит стабильный код, `file:line`, `object_id` и компактный
машиночитаемый отчёт. Это следующий этап, а не встроенный контроллер
контекста.
