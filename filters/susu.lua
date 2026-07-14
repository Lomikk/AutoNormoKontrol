-- Trusted renderer. Source Markdown is validated before this filter runs.

local function has_class(element, class_name)
  for _, class in ipairs(element.classes or {}) do
    if class == class_name then return true end
  end
  return false
end

local function trim(value)
  return (value:gsub('^%s+', ''):gsub('%s+$', ''))
end

local function latex_blocks(blocks)
  if blocks == nil then return '' end
  return trim(pandoc.write(pandoc.Pandoc(blocks), 'latex'))
end

local function latex_inlines(inlines)
  if inlines == nil then return '' end
  return latex_blocks({pandoc.Plain(inlines)})
end

local function reference_kind(identifier)
  local prefix = identifier:match('^(%a+):')
  if prefix == 'fig' or prefix == 'tbl' or prefix == 'eq' or prefix == 'app' then
    return prefix
  end
  return nil
end

local function transform_references(inlines)
  local output = pandoc.Inlines({})
  for _, inline in ipairs(inlines) do
    if inline.t == 'Cite' and #inline.citations == 1 then
      local identifier = inline.citations[1].id
      local kind = reference_kind(identifier)
      if kind ~= nil then
        if #output > 0 and output[#output].t == 'Space' then output:remove(#output) end
        local command = kind == 'eq' and '\\eqref{' .. identifier .. '}' or
          '\\ref{' .. identifier .. '}'
        -- STO-8.4.5, STO-8.5.4, STO-8.6.4, STO-8.7.11:
        -- a nonbreaking space binds the full object word to its number;
        -- formula references use parentheses through \eqref.
        output:insert(pandoc.RawInline('latex', '~' .. command))
      else
        output:insert(inline)
      end
    else
      output:insert(inline)
    end
  end
  return output
end

local header_joiners = {
  ['а']=true, ['без']=true, ['в']=true, ['во']=true, ['для']=true, ['до']=true,
  ['и']=true, ['из']=true, ['к']=true, ['как']=true, ['на']=true, ['над']=true,
  ['но']=true, ['о']=true, ['об']=true, ['от']=true, ['по']=true, ['под']=true,
  ['при']=true, ['с']=true, ['со']=true, ['у']=true, ['через']=true,
}

local function protect_header_joiners(header)
  -- STO-7.4.2, STO-8.2.5, STO-8.2.6: level-one headings are stored in the
  -- same uppercase form that is printed and written to the table of contents.
  if header.level == 1 then
    for _, inline in ipairs(header.content) do
      if inline.t == 'Str' then inline.text = pandoc.text.upper(inline.text) end
    end
  end
  -- STO-8.2.8: prepositions and conjunctions may not remain at the end of
  -- a wrapped heading line; hyphenation itself is disabled in the style.
  local result = pandoc.Inlines({})
  local index = 1
  while index <= #header.content do
    local current = header.content[index]
    local next_inline = header.content[index + 1]
    result:insert(current)
    if current.t == 'Str' and next_inline and next_inline.t == 'Space' and
       header_joiners[pandoc.text.lower(current.text)] then
      result:insert(pandoc.RawInline('latex', '~'))
      index = index + 2
    else
      index = index + 1
    end
  end
  header.content = result
  return header
end

local function table_identity(table_element)
  local caption = pandoc.utils.stringify(table_element.caption)
  local caption_text, identifier = caption:match('^(.-)%s*%{#([^}]+)%}%s*$')
  if identifier == nil then
    identifier = table_element.identifier or ''
    caption_text = caption
  end
  return identifier, trim(caption_text or '')
end

local function parsed_caption_blocks(caption_text)
  if caption_text == '' then return {} end
  return pandoc.read(caption_text, 'markdown').blocks
end

local function table_rows(table_element)
  local head = {}
  local body = {}
  if table_element.head and table_element.head.rows then
    for _, row in ipairs(table_element.head.rows) do head[#head + 1] = row end
  end
  for _, table_body in ipairs(table_element.bodies or {}) do
    for _, row in ipairs(table_body.head or {}) do head[#head + 1] = row end
    for _, row in ipairs(table_body.body or {}) do body[#body + 1] = row end
  end
  if table_element.foot and table_element.foot.rows then
    for _, row in ipairs(table_element.foot.rows) do body[#body + 1] = row end
  end
  return head, body
end

local function render_cell(cell)
  local contents = cell.contents or cell.content or {}
  local value = latex_blocks(contents):gsub('\n\n+', '\\par '):gsub('\n', ' ')
  local row_span = tonumber(cell.row_span) or 1
  local col_span = tonumber(cell.col_span) or 1
  if row_span > 1 or col_span > 1 then
    value = string.format('\\SetCell[r=%d,c=%d]{} %s', row_span, col_span, value)
  end
  return value
end

local function render_row(row)
  local cells = {}
  for _, cell in ipairs(row.cells or {}) do cells[#cells + 1] = render_cell(cell) end
  return table.concat(cells, ' & ') .. ' \\\\'
end

local function column_alignment(colspec)
  local alignment = tostring(colspec[1] or colspec.align or '')
  if alignment:find('Right') then return 'r' end
  if alignment:find('Center') then return 'c' end
  return 'l'
end

local function render_table(table_element)
  -- STO-8.6.3, STO-8.6.7, STO-8.6.8, STO-8.6.13 and Appendix M:
  -- controlled longtblr output provides a top caption, full grid, repeated
  -- head, continuation/final headings and a 12 pt body (caption remains 14 pt).
  local identifier, caption_text = table_identity(table_element)
  local caption_latex = latex_blocks(parsed_caption_blocks(caption_text))
    :gsub('\n\n+', ' '):gsub('\n', ' ')
  local head, body = table_rows(table_element)
  local columns = {}
  for _, colspec in ipairs(table_element.colspecs or {}) do
    columns[#columns + 1] = 'X[' .. column_alignment(colspec) .. ']'
  end
  if #columns == 0 and #head > 0 then
    for _ = 1, #(head[1].cells or {}) do columns[#columns + 1] = 'X[l]' end
  end
  local colspec = '|' .. table.concat(columns, '|') .. '|'
  local lines = {
    '\\begin{longtblr}[',
    '  theme=susu,',
    '  caption={' .. caption_latex .. '},',
    '  entry={' .. caption_latex .. '},',
    '  label={' .. identifier .. '}',
    ']{',
    '  colspec={' .. colspec .. '},',
    '  width=\\linewidth,',
    '  rowhead=' .. tostring(#head) .. ',',
    '  hlines, vlines,',
    '  rows={font=\\fontsize{12pt}{14pt}\\selectfont},',
    '  row{1-' .. tostring(math.max(#head, 1)) .. '}={font=\\bfseries}',
    '}',
  }
  for _, row in ipairs(head) do lines[#lines + 1] = render_row(row) end
  for _, row in ipairs(body) do lines[#lines + 1] = render_row(row) end
  lines[#lines + 1] = '\\end{longtblr}'
  return pandoc.RawBlock('latex', table.concat(lines, '\n'))
end

local function first_image(figure)
  local found = nil
  figure:walk({
    Image = function(image)
      if found == nil then found = image end
    end
  })
  return found
end

local function figure_width(image)
  local width = image.attributes.width
  if width == nil or width == '' then return '\\maxwidth' end
  local percentage = width:match('^(%d+)%%$')
  if percentage then return string.format('%.4f\\linewidth', tonumber(percentage) / 100) end
  return width
end

local function render_figure(figure)
  -- STO-8.5.2, STO-8.5.3, STO-8.5.5, STO-8.5.7: figures are deliberately
  -- non-floating and are emitted exactly at their semantic source position.
  local image = first_image(figure)
  if image == nil then error('Validated Figure unexpectedly contains no Image') end
  local caption = latex_blocks(figure.caption.long or figure.caption)
    :gsub('\n\n+', ' '):gsub('\n', ' ')
  local options = {'width=' .. figure_width(image), 'keepaspectratio'}
  local rotation = figure.attributes.rotation or image.attributes.rotation
  if rotation == '90ccw' then options[#options + 1] = 'angle=90' end
  local latex = table.concat({
    '\\begin{figure}[H]',
    '\\centering',
    '\\includegraphics[' .. table.concat(options, ',') .. ']{\\detokenize{' .. image.src .. '}}',
    '\\caption{' .. caption .. '}',
    '\\label{' .. figure.identifier .. '}',
    '\\end{figure}',
  }, '\n')
  return pandoc.RawBlock('latex', latex)
end

local function first_display_math(div)
  local result = nil
  div:walk({
    Math = function(math)
      if math.mathtype == 'DisplayMath' and result == nil then result = trim(math.text) end
    end
  })
  return result
end

local function render_where(div)
  -- STO-8.7.4, STO-8.7.7: a typed list lets the renderer guarantee "где"
  -- without a colon/indent and one semicolon-terminated definition per line.
  local items = {}
  for _, block in ipairs(div.content) do
    if block.t == 'BulletList' then
      for _, item in ipairs(block.content) do items[#items + 1] = latex_blocks(item) end
    end
  end
  local lines = {'\\begin{SUSUWhere}'}
  for index, item in ipairs(items) do
    item = trim(item):gsub('[%.;,]%s*$', '')
    local punctuation = index == #items and '.' or ';'
    local label = index == 1 and '[где]' or '[]'
    lines[#lines + 1] = '\\item' .. label .. ' ' .. item .. punctuation
  end
  lines[#lines + 1] = '\\end{SUSUWhere}'
  return pandoc.RawBlock('latex', table.concat(lines, '\n'))
end

local function render_div(div)
  if has_class(div, 'bibliography') then
    -- STO-7.11.2, STO-7.11.4.
    return pandoc.RawBlock('latex',
      '\\clearpage\\printbibliography[heading=bibintoc,title={БИБЛИОГРАФИЧЕСКИЙ СПИСОК}]')
  end

  if has_class(div, 'equation') then
    -- STO-8.7.2, STO-8.7.5, STO-8.7.6, STO-8.7.10, STO-8.7.13:
    -- formulas and mathematical equations share this one typed renderer,
    -- therefore an equation cannot silently acquire different layout rules.
    local equation = first_display_math(div)
    return pandoc.RawBlock('latex', table.concat({
      '\\begin{equation}', equation,
      '\\label{' .. div.identifier .. '}', '\\end{equation}'
    }, '\n'))
  end

  if has_class(div, 'equation-where') then return render_where(div) end

  if has_class(div, 'susu-appendix') then
    -- STO-7.12.3, STO-7.12.4, STO-7.12.5, STO-7.12.7, STO-7.12.8.
    local letter = div.attributes.letter
    local title = div.attributes.title
    local kind = div.attributes.kind or 'информационное'
    local blocks = pandoc.List({})
    blocks:insert(pandoc.RawBlock('latex',
      '\\begin{SUSUAppendix}{' .. letter .. '}{' .. title .. '}{' ..
        div.identifier .. '}{' .. kind .. '}'))
    blocks:extend(div.content)
    blocks:insert(pandoc.RawBlock('latex', '\\end{SUSUAppendix}'))
    return blocks
  end

  return nil
end

return {
  {Inlines = transform_references, Header = protect_header_joiners},
  {Table = render_table, Figure = render_figure, Div = render_div},
}
