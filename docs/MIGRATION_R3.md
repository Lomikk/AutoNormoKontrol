# R3: перенос текущего профиля

R3 физически отделяет движок AutoNormoKontrol от единственного нормативного
профиля, не меняя правила, пользовательские команды и результат сборки.

## Что изменилось

Активный профиль выбирается единственной строкой в
`profiles/active-profile.txt`. Сейчас она указывает на:

```text
profiles/susu-hsem-ceit-coursework-v1/profile.yaml
```

Указатель fail-closed: пустой файл, несколько строк, путь другого вида или
отсутствующий manifest останавливают команду. Поиска первого каталога и
автоматического выбора профиля нет.

Пути профильных файлов перенесены следующим образом:

| До R3 | После R3 |
|---|---|
| `compliance/requirements.json` | `profiles/susu-hsem-ceit-coursework-v1/compliance/requirements.json` |
| `compliance/review-inventory.yaml` | `profiles/susu-hsem-ceit-coursework-v1/compliance/review-inventory.yaml` |
| `compliance/research-notes.md` | `profiles/susu-hsem-ceit-coursework-v1/compliance/research-notes.md` |
| `prompts/SYSTEM_PROMPT_SUSU_COURSEWORK.md` | `profiles/susu-hsem-ceit-coursework-v1/prompts/SYSTEM_PROMPT_SUSU_COURSEWORK.md` |
| `templates/susu-coursework.tex` | `profiles/susu-hsem-ceit-coursework-v1/templates/susu-coursework.tex` |
| `styles/susu-coursework.sty` | `profiles/susu-hsem-ceit-coursework-v1/styles/susu-coursework.sty` |
| `filters/sto-validate.lua` | `profiles/susu-hsem-ceit-coursework-v1/filters/sto-validate.lua` |
| `filters/susu.lua` | `profiles/susu-hsem-ceit-coursework-v1/filters/susu.lua` |
| `scripts/validate-pdf.ps1` | `profiles/susu-hsem-ceit-coursework-v1/postflight/validate-pdf.ps1` |

Дополнительно профиль получил неизменяемый exact-set
`compliance/canonical-requirement-ids.json` и стартовые файлы в
`review-templates/`.

## Что намеренно осталось в workspace

Следующие файлы относятся к конкретной работе, а не к реализации профиля:

- `content/*.md`;
- `metadata.yaml`;
- `bibliography.bib`;
- `assets/`;
- `format-spec.yaml`;
- `compliance/semantic-review.yaml`;
- `compliance/external-acceptance.yaml`.

Профильные review templates задают форму новых журналов, но не содержат готовой
приёмки новой работы. Копировать статус `pass` или `accepted` между workspace
нельзя.

## Что требуется пользователю

Публичные команды не изменились:

```powershell
.\AutoNormoKontrol.cmd doctor
.\AutoNormoKontrol.cmd draft
.\AutoNormoKontrol.cmd check
.\AutoNormoKontrol.cmd status
.\AutoNormoKontrol.cmd strict
```

После обновления существующего checkout вручную переносить содержание или
журналы не нужно. Собственные инструменты, которые напрямую открывали старые
пути, должны сначала прочитать `profiles/active-profile.txt`, затем manifest и
брать пути из его полей.

Параметр `-ProfilePath` остаётся диагностическим интерфейсом разработчика. Он не
является публичной системой переключения типов документов и не делает
произвольный manifest поддерживаемым.

## Что не входит в R3

- второй профиль;
- `list-profiles` и `new --profile`;
- наследование и merge профилей;
- кафедральные или преподавательские overrides;
- изменение 172 нормативных требований;
- перенос evidence текущей работы в пакет профиля.

Эти задачи относятся к R4 и последующим этапам и требуют отдельного решения на
основании реального второго нормативного источника.
