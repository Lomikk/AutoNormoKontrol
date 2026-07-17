# Контракт агента рабочей области

Эта папка содержит одну научную статью.

Перед редактированием прочитай:

- `guide/profile-system-prompt.md`;
- `metadata.yaml`;
- `content/article.md`.

Обычная работа выполняется только в:

- `content/*.md`;
- `metadata.yaml`;
- `bibliography.bib`;
- `assets/**`;
- `research/**`.

Не изменяй без отдельной просьбы пользователя:

- `project.yaml`;
- `format-spec.yaml`;
- `compliance/**`;
- `build/**`;
- `output/**`;
- локальные launcher-файлы;
- центральный движок AutoNormoKontrol.

Не выдумывай источники, DOI, результаты исследования, сведения об авторе,
организации или апробации.

Текст статьи должен оставаться семантическим Pandoc Markdown. Не используй
ручную визуальную подгонку, raw TeX и HTML.

После законченной правки запусти:

AutoNormoKontrol.cmd draft

Исправляй исходный Markdown или метаданные, а не сгенерированные TeX и PDF.
