# Структура проекта и CLI AutoNormoKontrol

Этот файл является каноническим справочником по пользовательским командам и
границам каталогов. Если другой документ перечисляет команды, он должен
ссылаться сюда, а не поддерживать второй независимый список.

## Канонический список CLI

Команды запускаются из корня репозитория:

```powershell
.\AutoNormoKontrol.cmd new <название работы>
.\AutoNormoKontrol.cmd doctor
.\AutoNormoKontrol.cmd install [--yes]
.\AutoNormoKontrol.cmd check
.\AutoNormoKontrol.cmd draft
.\AutoNormoKontrol.cmd build
.\AutoNormoKontrol.cmd strict
.\AutoNormoKontrol.cmd test
.\AutoNormoKontrol.cmd trace
.\AutoNormoKontrol.cmd status
.\AutoNormoKontrol.cmd open
.\AutoNormoKontrol.cmd export
.\AutoNormoKontrol.cmd archive [метка]
.\AutoNormoKontrol.cmd context <capability> <content-file>
.\AutoNormoKontrol.cmd help
```

- `new` из центрального каталога создаёт Draft-valid работу в
  `Workspaces/<название>` и никогда не перезаписывает существующую папку.
- `doctor` проверяет Pandoc, TeX Live и PDF-инструменты.
- `install` может установить Pandoc через WinGet; `--yes` убирает вопрос
  подтверждения только для этого действия. TeX Live устанавливается отдельно.
- `check` запускает тесты соответствия, затем Draft-сборку.
- `draft` собирает черновой PDF с предупреждениями.
- `build` — совместимый алиас `draft`.
- `strict` выполняет fail-closed сборку для выпуска.
- `test` запускает тесты правил и coverage gate.
- `trace` строит отчёт трассировки требований.
- `status` показывает состояния аудитов, PDF postflight и последнего PDF.
- `open` открывает опубликованный `output/document.pdf`, а до публикации —
  последний PDF из `build/`.
- `export` атомарно публикует последний успешный и актуальный PDF как
  `output/document.pdf`; для Draft явно выводится предупреждение.
- `archive` по явному действию сохраняет неизменяемую копию опубликованного PDF
  и отказывается перезаписывать существующий архив.
- `context` строит проверенный `context-plan-v1` и Aider `/load`-файлы для
  выбранного capability и content-файла активного профиля.
- `help` показывает справку CLI.

Центральный launcher создаёт работу; после этого пользователь и пишущий агент
запускают тонкий `AutoNormoKontrol.cmd` уже внутри неё. Локальный launcher не
содержит движок и работает, пока проект остаётся внутри общего каталога
`Workspaces`. Перемещение работ в произвольное место и установка через `PATH`
отложены, но формат данных workspace от относительного `..\..` не зависит.

`context-plan-v1` остаётся экспериментальным адаптером старого корневого
workspace для Aider. Он не является частью Gemini CLI MVP и намеренно не
запускается внутри новой отдельной работы: Gemini CLI стартует в корне workspace
и самостоятельно управляет своим контекстом. Общим контрактом для всех агентов
остаётся точная диагностика `draft`, а не принудительное управление читаемыми
файлами.

## Границы каталогов

| Область | Что содержит | Правило для Aider и внешнего чата |
|---|---|---|
| engine | `AutoNormoKontrol.cmd`, `scripts/`, `schemas/` | Только read-only контекст; не менять в обычной работе с содержанием |
| profile | `profiles/`, `profiles/active-profile.txt` | Read-only нормативный и оформительский контракт; профиль выбирается только через active-profile |
| workspace | `Workspaces/<name>/`: `project.yaml`, `content/`, `metadata.yaml`, `bibliography.bib`, `assets/`, `format-spec.yaml`, `compliance/`, `guide/` | Editable только данные одной работы; `project.yaml` задаёт профиль и явный порядок глав; журналы приёмки не менять без отдельной задачи и реального основания |
| sources | `sources/` | Канонические нормативные исходники; read-only, не добавлять в обычный контекст редактирования |
| tests | `tests/`, включая находящиеся там fixtures | Read-only искусственные примеры для проверки программы; не редактировать при исправлении курсовой |
| docs | `README.md`, `AGENTS.md`, `docs/` | Документация и агентский контракт; read-only при написании работы |
| build | Сгенерированные PDF, TeX, отчёты и snapshots внутри workspace | Всегда generated/excluded; не добавлять в агентский контекст как editable-файлы |
| output | Стабильный `document.pdf`, export-report и явные архивы | Пользовательский результат; не редактировать вручную и не считать источником содержания |

`AGENTS.md`, `README.md`, этот справочник и файлы активного профиля могут быть
read-only контекстом для агента. Они не являются содержанием курсовой.

## Manifest отдельной работы

`project.yaml` записан в строгом JSON-совместимом подмножестве YAML и проверяется
по контракту `schemas/workspace-v1.schema.json`. Он фиксирует:

- ID, путь manifest и digest одного профиля;
- минимальную и исходную версию движка;
- тип документа;
- непустой уникальный массив `document.content` в точном порядке сборки.

Неизвестные поля, traversal-пути, отсутствующие Markdown-файлы, неправильный
тип документа и несовместимая версия останавливают команду. Изменившийся digest
профиля показывается как предупреждение; тихого обновления или миграции работа
не выполняет. `project.yaml` включён в document snapshot, поэтому изменение
порядка глав после Draft делает прежний export устаревшим.

## Capability-модель AI-контекста

`R1.4a/context-plan-v1` не угадывает смысл пользовательского запроса. Пользователь
или ИИ выбирает только небольшой capability и content-target; активный профиль
определяет реальные пути:

```text
capability + target + active profile -> context-plan-v1 -> Aider adapter
```

| Capability | Editable | Дополнительный read-only контекст |
|---|---|---|
| `edit-content` | выбранный content-target | `metadata.yaml` |
| `edit-references` | выбранный content-target и активный `bibliography.bib` | `metadata.yaml` |
| `edit-metadata` | активный `metadata.yaml` | профильный контракт |
| `design-structure` | выбранный content-target | metadata и остальные content-входы активного профиля |
| `review-content` | нет | выбранный target и metadata |

Во всех режимах read-only добавляются `AGENTS.md`, `README.md`, указатель и
manifest активного профиля, системная инструкция, нормативный реестр и инструкция
текущего capability. Пути не сканируются и не подбираются по похожему имени.
Target обязан в точности присутствовать в `inputs.content` активного manifest.

Минимальный запуск:

```powershell
.\AutoNormoKontrol.cmd context edit-content content/00-introduction.md
```

Команда создаёт:

- `build/ai/context-plan.json` — текущий provider-neutral план;
- `build/ai/plans/*.json` — канонические планы допустимых переходов для того же
  target;
- `build/ai/aider-context.txt` — копируемое представление текущего плана;
- `build/ai/switch/*.aider` — готовые переключатели для `/load`;
- `build/ai/capabilities/*.md` — отдельную правдивую инструкцию каждого режима.

В Aider достаточно выполнить показанную команду, например:

```text
/load build/ai/switch/edit-content.aider
```

Фактический ввод `/load` пользователем является подтверждением перехода. ИИ
может объяснить нехватку доступа и рекомендовать один из уже подготовленных
переходов, но не может сам выдать себе дополнительные права. Один общий
`capabilities.md` не переиспользуется всеми switch-файлами: после перехода он
мог бы сообщать устаревший текущий режим, поэтому каждый switch загружает свою
capability-инструкцию.

Одинаковые profile digest, policy digest, capability и target дают одинаковый
JSON. План применим, пока digest профиля и политики совпадают, а target остаётся
в active profile. После изменения контракта нужно заново выполнить `context`.
Обычные ненужные файлы в план не включаются; `excluded` отдельно перечисляет
защищённые области. Исключения `build/ai/capabilities/*.md` разрешены только как
точные generated read-only инструкции: весь `build/**` по-прежнему никогда не
становится editable.

`excluded` означает запрет на editable-доступ, а не запрет любой загрузки:
точные manifest/prompt/requirements активного профиля и capability-инструкция
могут входить как read-only исключения. Для `edit-metadata` content-target служит
якорем цепочки переходов и сам в контекст не загружается.

Пока Draft не выдаёт `source suggestion`, target выбирается только по точному
пути и фрагменту из сообщения ошибки; нельзя выбирать `content/02-main.md` по
умолчанию. `semantic-review.yaml` и `external-acceptance.yaml` изменяются только
в отдельных процессах с реальным основанием, а не через capability написания.
