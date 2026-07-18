# Тематические тесты движка

Этот каталог сокращает контекст разработчика. `scripts/test-compliance.ps1`
остаётся единственным runner и создаёт общий безопасный контекст; файлы
`*.tests.ps1` подключаются им через dot-source и не запускаются напрямую.

## Быстрый цикл

Из корня движка:

```powershell
.\AutoNormoKontrol.cmd check --fast
```

Для одной подсистемы разработчик может вызвать внутренний runner:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .\scripts\test-compliance.ps1 -Suite profile-contract -SkipCoverage
```

Доступные наборы:

| Suite | Область |
|---|---|
| `profile-contract` | resolver, каталог, schema и digest профилей |
| `static-render-contract` | точные обязательные фрагменты TeX/Lua реализации активного профиля |
| `semantic-validator` | Pandoc fixtures, mutation и semantic/external gates |
| `build-assets` | asset builder, snapshot и wiring общей сборки |
| `engine-cli` | режимы центрального/workspace CLI и установка зависимостей |
| `engine-integration` | disposable workspace, runners зарегистрированных профилей и UTF-8 процессный контракт |
| `fast` | все наборы, кроме `engine-integration` |
| `all` | полный порядок, используемый обычным `check` |

`-SkipCoverage` допустим только для повторного локального запуска узкого набора.
Он не входит в публичный CLI и не отменяет coverage в `check --fast` или полном
`check`.

## Куда добавлять проверку

- Тест помещается в самый узкий набор, которому принадлежит проверяемый
  контракт. Не возвращай тематический код в центральный runner.
- Общий helper добавляется в runner только если нужен минимум двум наборам;
  иначе он остаётся рядом со своим тестом.
- Нормативная реализация обязана сохранить комментарий `STO-x.y.z` и реальный
  fixture с тем же ID. Разделение файлов не является причиной ослаблять
  coverage, exact-set или mutation gate.
- `engine-integration` используется только для поведения, которое невозможно
  доказать более дешёвым набором. Не добавляй туда статическую проверку.
- Все generated данные тестов остаются в `build/` или одноразовом workspace и
  удаляются runner/lifecycle helper.

Перед завершением любого изменения движка обязательно выполни:

```powershell
.\AutoNormoKontrol.cmd check
```

Успех отдельного suite или `check --fast` не является выпускным доказательством.
