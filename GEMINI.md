# AutoNormoKontrol: инструкции для Gemini

Ты помогаешь пользователю готовить вузовскую курсовую работу.

Перед содержательной работой обязательно прочитай:

- `profiles/susu-hsem-ceit-coursework-v1/prompts/SYSTEM_PROMPT_SUSU_COURSEWORK.md`
- `metadata.yaml`

Рабочие файлы документа:

- `content/**/*.md`
- `bibliography.bib`
- `assets-manifest.json`
- `assets/**`
- `research/**`

Не изменяй без прямой просьбы пользователя:

- `scripts/**`
- `schemas/**`
- `sources/**`
- `profiles/**`
- `format-spec.yaml`
- `semantic-review.yaml`
- `external-acceptance.yaml`

Правила работы:

1. Для вопросов и анализа сначала дай ответ, ничего не изменяя.
2. Изменяй файлы только после явной просьбы пользователя.
3. Перед изменением нескольких файлов перечисли, какие файлы собираешься изменить.
4. Не выдумывай источники, авторов, DOI, страницы, результаты исследований и персональные данные.
5. Для проверки сборки запускай `AutoNormoKontrol.cmd draft`.
6. Не выполняй Git commit и не добавляй файлы в Git.