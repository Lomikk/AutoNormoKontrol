# Структура проекта и CLI AutoNormoKontrol

Этот файл является каноническим справочником по пользовательским командам и
границам каталогов. Если другой документ перечисляет команды, он должен
ссылаться сюда, а не поддерживать второй независимый список.

## Канонический список CLI

Команды запускаются из корня репозитория:

```powershell
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
.\AutoNormoKontrol.cmd context <capability> <content-file>
.\AutoNormoKontrol.cmd help
```

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
- `open` открывает последний PDF из `build/`.
- `context` строит проверенный `context-plan-v1` и Aider `/load`-файлы для
  выбранного capability и content-файла активного профиля.
- `help` показывает справку CLI.

Команды `new`, `export` и `archive` пока не реализованы. Не следует
документировать их как рабочие и не следует имитировать их ручным удалением,
перезаписью или публикацией файлов. Сейчас новый workspace создаётся только
вручную на основании активного профиля, а рабочий результат находится в
`build/`.

## Границы каталогов

| Область | Что содержит | Правило для Aider и внешнего чата |
|---|---|---|
| engine | `AutoNormoKontrol.cmd`, `scripts/`, `schemas/` | Только read-only контекст; не менять в обычной работе с содержанием |
| profile | `profiles/`, `profiles/active-profile.txt` | Read-only нормативный и оформительский контракт; профиль выбирается только через active-profile |
| workspace | `content/`, `metadata.yaml`, `bibliography.bib`, `assets/`, `format-spec.yaml`, `compliance/` | Editable только явно разрешённые файлы текущей задачи; журналы приёмки не менять без отдельной задачи и реального основания |
| sources | `sources/` | Канонические нормативные исходники; read-only, не добавлять в обычный контекст редактирования |
| tests | `tests/`, включая находящиеся там fixtures | Read-only искусственные примеры для проверки программы; не редактировать при исправлении курсовой |
| docs | `README.md`, `AGENTS.md`, `docs/` | Документация и агентский контракт; read-only при написании работы |
| build | Сгенерированные PDF, TeX, отчёты и snapshots | Всегда generated/excluded; не добавлять в Aider как editable-файлы |

`AGENTS.md`, `README.md`, этот справочник и файлы активного профиля могут быть
read-only контекстом для агента. Они не являются содержанием курсовой.

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
