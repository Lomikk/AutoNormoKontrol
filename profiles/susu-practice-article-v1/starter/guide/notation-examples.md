# Разрешённая нотация профиля статьи

Этот файл является справкой и не включается в PDF. Используй только примеры,
которые поддерживаются текущим профилем. Не вставляй raw TeX/HTML.

## Заголовки

```markdown
# Введение

## Модель объекта

### Ограничения подхода
```

Не добавляй номера вручную: их формирует backend.

Не используй HTML-комментарии `<!-- ... -->` как служебные маркеры: текущая
цепочка может вывести их в PDF как обычный текст.

## Библиографическая ссылка

Сначала добавь проверенную запись в `bibliography.bib`, затем используй её ключ:

```markdown
Подход рассматривается в нескольких публикациях [@source-one; @source-two].
```

Библиографический список формируется шаблоном автоматически. Не добавляй в
Markdown ручной список литературы.

## График по данным

Исходники:

```text
assets/plots/result-distribution.tex
assets/data/result-distribution.csv
```

Manifest:

```json
{
  "id": "result-distribution",
  "type": "plot",
  "sources": [
    "assets/plots/result-distribution.tex",
    "assets/data/result-distribution.csv"
  ],
  "generator": "tex-pgfplots",
  "output": "build/assets/result-distribution.pdf",
  "tex-source": "assets/plots/result-distribution.tex",
  "data-source": "assets/data/result-distribution.csv",
  "provenance": "Построено автором по проверенным данным из CSV",
  "license": "Авторский материал"
}
```

Markdown:

```markdown
Распределение результатов показано на рисунке ниже.

![Распределение результатов](build/assets/result-distribution.pdf){#fig:result-distribution width=78%}
```

## Концептуальная TikZ-схема

Технически подтверждено, что pipeline собирает обычную TikZ-схему.

Создай самостоятельный TeX-файл:

```tex
\documentclass[tikz,border=4pt]{standalone}
\usepackage{fontspec}
\usepackage{polyglossia}
\setmainlanguage{russian}
\setmainfont{Times New Roman}
\newfontfamily\cyrillicfont{Times New Roman}
\usetikzlibrary{arrows.meta,positioning}

\begin{document}
\begin{tikzpicture}[
  every node/.style={draw,rounded corners,align=center},
  >={Stealth}
]
\node (a) {Источник данных};
\node (b) [right=of a] {Модель};
\node (c) [right=of b] {Контроль действия};
\draw[->] (a) -- (b);
\draw[->] (b) -- (c);
\end{tikzpicture}
\end{document}
```

Путь:

```text
assets/plots/protection-architecture.tex
```

Текущий контракт требует служебный CSV:

```text
assets/data/protection-architecture.csv
```

Допустимое содержимое:

```csv
key,value
nodes,3
edges,2
```

Это техническое описание схемы, а не исследовательские данные.

Manifest:

```json
{
  "id": "protection-architecture",
  "type": "plot",
  "sources": [
    "assets/plots/protection-architecture.tex",
    "assets/data/protection-architecture.csv"
  ],
  "generator": "tex-pgfplots",
  "output": "build/assets/protection-architecture.pdf",
  "tex-source": "assets/plots/protection-architecture.tex",
  "data-source": "assets/data/protection-architecture.csv",
  "provenance": "Авторская концептуальная схема",
  "license": "Авторский материал"
}
```

Markdown:

```markdown
Последовательность обработки показана на рисунке ниже.

![Архитектура защитного контура](build/assets/protection-architecture.pdf){#fig:protection-architecture width=78%}
```

Важно:

- не используй путь `assets/plots/protection-architecture.pdf`;
- pipeline создаёт `build/assets/protection-architecture.pdf`;
- не используй `@fig:protection-architecture` или `[@fig:...]`;
- номер рисунка формирует шаблон автоматически;
- размести рисунок рядом с первым содержательным обсуждением, а не после вывода;
- после Draft визуально проверь перенос, размер и подпись.

## Таблица

```markdown
Сопоставление подходов приведено в таблице ниже.

| Подход | Назначение | Ограничение |
|:--|:--|:--|
| Изоляция контекста | Разделение инструкций и данных | Не устраняет ошибочную политику |
| Контроль инструментов | Проверка операций | Требует явных правил доступа |

: Сопоставление уровней защиты
```

Не используй таблицу для одного значения или для декоративного размещения текста.

## Формула

Inline-формула:

```markdown
Доля успешных проверок обозначается как $Q$.
```

Display-формула:

```markdown
Показатель определяется отношением числа успешных проверок к их общему числу:

$$
Q = \frac{N_{\mathrm{ok}}}{N_{\mathrm{all}}}.
$$

Здесь $N_{\mathrm{ok}}$ — число успешных проверок, а
$N_{\mathrm{all}}$ — общее число проверок.
```

Нумерованные формулы и ссылки `[@eq:...]` в текущем профиле отдельно не
подтверждены. Не копируй coursework-блоки `.equation` без проверки поддержки.

## Перечень

```markdown
Архитектура включает:

- разделение доверенных и недоверенных данных;
- минимизацию полномочий;
- проверку инструментальных действий;
- журналирование событий.
```

Элементы должны быть грамматически согласованы с вводной фразой.

## Отдельный обзор и статья

Текущий профиль формирует один PDF из одного набора content-файлов.

Если требуется два самостоятельных документа — например, аналитический обзор и
научная статья, — создай два workspace одного профиля. Не пытайся получить два
независимых PDF из одного workspace без изменения профиля.
