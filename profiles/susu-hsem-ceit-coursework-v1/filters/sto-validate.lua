-- Fail-closed validator for the restricted SUSU coursework notation.
-- Every normative handler carries the clause marker used by the coverage gate.

local errors = {}
local warnings = {}

local function add_error(clause, message)
  errors[#errors + 1] = clause .. ': ' .. message
end

local function add_warning(clause, message)
  warnings[#warnings + 1] = clause .. ': ' .. message
end

local function has_class(element, class_name)
  for _, class in ipairs(element.classes or {}) do
    if class == class_name then
      return true
    end
  end
  return false
end

local function text(value)
  if value == nil then
    return ''
  end
  return pandoc.utils.stringify(value)
end

local function trim(value)
  return (value:gsub('^%s+', ''):gsub('%s+$', ''))
end

local function lower(value)
  return pandoc.text.lower(value)
end

local function ends_with(value, suffix)
  return suffix == '' or value:sub(-#suffix) == suffix
end

local function split_csv(value)
  local result = {}
  for item in (value or ''):gmatch('[^,;]+') do
    result[#result + 1] = trim(item)
  end
  return result
end

local function is_letter_or_digit(character)
  if character == nil or character == '' then return false end
  if character:match('^%d$') then return true end
  return pandoc.text.upper(character) ~= pandoc.text.lower(character)
end

local function contains_word(value, needle)
  local source = pandoc.text.lower(value)
  local target = pandoc.text.lower(needle)
  local source_length = pandoc.text.len(source)
  local target_length = pandoc.text.len(target)
  if target_length == 0 or source_length < target_length then return false end
  for index = 1, source_length - target_length + 1 do
    if pandoc.text.sub(source, index, index + target_length - 1) == target then
      local before = index > 1 and pandoc.text.sub(source, index - 1, index - 1) or ''
      local after_index = index + target_length
      local after = after_index <= source_length and pandoc.text.sub(source, after_index, after_index) or ''
      if not is_letter_or_digit(before) and not is_letter_or_digit(after) then
        return true
      end
    end
  end
  return false
end

local function is_placeholder(value)
  value = trim(value or '')
  return value == '' or value:find('%[') ~= nil or value:find('_') ~= nil
end

local function meta_bool(value)
  local normalized = lower(text(value))
  return normalized == 'true' or normalized == 'yes' or normalized == '1'
end

local function profile_inventory_set(clause, label, values)
  local result = {}
  local count = 0
  for _, value in ipairs(values or {}) do
    local identifier = text(value)
    if identifier == '' then
      add_error(clause, label .. ': empty id in profile inventory')
    elseif result[identifier] then
      add_error(clause, label .. ': duplicate profile id ' .. identifier)
    else
      result[identifier] = true
      count = count + 1
    end
  end
  if count == 0 then
    add_error(clause, label .. ': profile inventory is missing or empty')
  end
  return result
end

local function table_has_value(value)
  if value == nil then return false end
  for _, _ in pairs(value) do return true end
  return false
end

local function validate_exact_record_set(clause, label, records, expected)
  local seen = {}
  for _, record in ipairs(records or {}) do
    local identifier = text(record.id)
    if identifier == '' then
      add_error(clause, label .. ': запись без id')
    elseif not expected[identifier] then
      add_error(clause, label .. ': неизвестный id ' .. identifier)
    elseif seen[identifier] then
      add_error(clause, label .. ': дублирующий id ' .. identifier)
    else
      seen[identifier] = true
    end
  end
  for identifier, _ in pairs(expected) do
    if not seen[identifier] then
      add_error(clause, label .. ': отсутствует обязательная запись ' .. identifier)
    end
  end
end

local function validate_attribute_names(clause, element, allowed)
  for name, _ in pairs(element.attributes or {}) do
    if not allowed[name] then
      add_error(clause, 'недопустимый атрибут «' .. name .. '»')
    end
  end
end

local state = {
  block = 0,
  objects = {},
  refs = {},
  headers = {},
  appendices = {},
  equations = {},
  where_blocks = {},
  bibliography_block = nil,
  plain_blocks = {},
  main_counts = {fig = 0, tbl = 0, eq = 0},
}

local function register_object(kind, identifier, block_number, element, in_appendix)
  if identifier == nil or identifier == '' then
    add_error('STO-object-id', kind .. ' не имеет обязательного идентификатора')
    return
  end
  if state.objects[identifier] ~= nil then
    add_error('STO-object-id', 'дублирующий идентификатор ' .. identifier)
    return
  end
  state.objects[identifier] = {
    kind = kind,
    block = block_number,
    element = element,
    in_appendix = in_appendix,
  }
  if not in_appendix and state.main_counts[kind] ~= nil then
    state.main_counts[kind] = state.main_counts[kind] + 1
  end
end

local reference_words = {
  fig = {'рисунок', 'рисунке', 'рисунка', 'рисунку', 'рисунком'},
  tbl = {'таблица', 'таблице', 'таблицу', 'таблицы', 'таблицей'},
  eq = {'формула', 'формуле', 'формулу', 'формулы', 'формулой'},
  app = {'приложение', 'приложении', 'приложению', 'приложения', 'приложением'},
}

local function reference_kind(identifier)
  local prefix = identifier:match('^(%a+):')
  if prefix == 'fig' or prefix == 'tbl' or prefix == 'eq' or prefix == 'app' then
    return prefix
  end
  return nil
end

local function has_reference_word(context, kind, repeated)
  local normalized = lower(trim(context))
  for _, word in ipairs(reference_words[kind] or {}) do
    if repeated then
      if ends_with(normalized, 'см. ' .. word) then
        return true
      end
    elseif ends_with(normalized, word) then
      return true
    end
  end
  return false
end

local function scan_inlines(inlines, block_number)
  local context = ''
  for _, inline in ipairs(inlines or {}) do
    -- STO-8.5.1: every image-like object must be represented by the typed
    -- Figure block.  An inline/bare Image would evade figure numbering,
    -- captioning and the mandatory reference checks, so it is rejected.
    if inline.t == 'Image' then
      add_error('STO-8.5.1', 'изображение должно быть отдельным семантическим рисунком с подписью и идентификатором fig:')
    end
    if inline.t == 'Cite' and #inline.citations == 1 then
      local identifier = inline.citations[1].id
      local kind = reference_kind(identifier)
      if kind ~= nil then
        state.refs[identifier] = state.refs[identifier] or {}
        local repeated = #state.refs[identifier] > 0
        state.refs[identifier][#state.refs[identifier] + 1] = {
          block = block_number,
          context = context,
          kind = kind,
        }
        -- STO-8.5.4, STO-8.6.4, STO-8.7.11, STO-7.12.4:
        -- object references use the full Russian object name; repeated
        -- figure/table references additionally require "см.".
        if not has_reference_word(context, kind, repeated and (kind == 'fig' or kind == 'tbl')) then
          if repeated and (kind == 'fig' or kind == 'tbl') then
            add_error('STO-' .. (kind == 'fig' and '8.5.4' or '8.6.4'),
              identifier .. ': повторная ссылка должна оканчиваться формой «см. ' ..
              (kind == 'fig' and 'рисунок' or 'таблицу') .. '»')
          else
            local clause = ({fig='8.5.4', tbl='8.6.4', eq='8.7.11', app='7.12.4'})[kind]
            add_error('STO-' .. clause,
              identifier .. ': перед ссылкой требуется полное слово, обозначающее объект')
          end
        end
      end
    end
    context = context .. text(inline)
  end
end

local function table_identifier(table_element)
  if table_element.identifier ~= nil and table_element.identifier ~= '' then
    return table_element.identifier, text(table_element.caption)
  end
  local caption = text(table_element.caption)
  local clean, identifier = caption:match('^(.-)%s*%{#([^}]+)%}%s*$')
  return identifier or '', trim(clean or caption)
end

local function table_rows(table_element)
  local rows = {}
  if table_element.head and table_element.head.rows then
    for _, row in ipairs(table_element.head.rows) do rows[#rows + 1] = row end
  end
  for _, body in ipairs(table_element.bodies or {}) do
    for _, row in ipairs(body.head or {}) do rows[#rows + 1] = row end
    for _, row in ipairs(body.body or {}) do rows[#rows + 1] = row end
  end
  if table_element.foot and table_element.foot.rows then
    for _, row in ipairs(table_element.foot.rows) do rows[#rows + 1] = row end
  end
  return rows
end

local function validate_caption(clause, identifier, caption)
  if trim(caption) == '' then
    add_error(clause, identifier .. ': отсутствует наименование')
    return
  end
  local last = pandoc.text.sub(trim(caption), -1, -1)
  if last == '.' or last == ';' or last == ':' then
    add_error(clause, identifier .. ': точка/двоеточие в конце наименования запрещены')
  end
  local first = pandoc.text.sub(trim(caption), 1, 1)
  if first ~= pandoc.text.upper(first) then
    add_error(clause, identifier .. ': наименование должно начинаться с прописной буквы')
  end
end

local function validate_table(table_element, identifier, caption)
  -- STO-8.6.3, STO-8.6.5, STO-8.6.6, STO-8.6.8, STO-8.6.9,
  -- STO-8.6.12, STO-8.6.14, STO-8.6.15.
  if not identifier:match('^tbl:') then
    add_error('STO-8.6.3', 'идентификатор таблицы должен начинаться с tbl:')
  end
  validate_caption('STO-8.6.5', identifier, caption)
  local rows = table_rows(table_element)
  for row_index, row in ipairs(rows) do
    for _, cell in ipairs(row.cells or {}) do
      local value = trim(text(cell.contents or cell.content))
      if value == '' and (cell.row_span or 1) == 1 and (cell.col_span or 1) == 1 then
        add_error('STO-8.6.9', identifier .. ': пустая ячейка; отсутствие данных обозначается прочерком')
      end
      if row_index == 1 and value:match('^№%s*п/п') then
        add_error('STO-8.6.8', identifier .. ': графа «№ п/п» запрещена')
      end
      if row_index == 1 and value:match('[%.;:]$') then
        add_error('STO-8.6.6', identifier .. ': точка в заголовке графы запрещена')
      end
      -- STO-8.4.7, STO-8.6.12, STO-8.6.15: deterministic numeric hygiene;
      -- semantic equality of precision and units is handled by the AI gate.
      local numeric = value:gsub('%d+%.%d+%.%d+', '')
      if numeric:match('%d+%.%d+') then
        add_error('STO-8.4.7', identifier .. ': десятичный разделитель в ячейке должен быть запятой')
      end
      if value:match('%d%d%d%d%d+') and not value:match('%d%d%d[%s ]%d%d%d') then
        add_warning('STO-8.6.15', identifier .. ': проверьте группировку многозначного числа «' .. value .. '»')
      end
    end
  end
end

local function first_display_math(div)
  local result = nil
  div:walk({
    Math = function(math)
      if math.mathtype == 'DisplayMath' and result == nil then
        result = math.text
      end
    end
  })
  return result
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

local function scan_blocks(blocks, context)
  context = context or {in_appendix = false}
  for _, block in ipairs(blocks or {}) do
    state.block = state.block + 1
    local block_number = state.block

    if block.t == 'Header' then
      state.headers[#state.headers + 1] = {
        level = block.level,
        value = trim(text(block.content)),
        classes = block.classes,
        block = block_number,
        in_appendix = context.in_appendix,
      }
    elseif block.t == 'Para' or block.t == 'Plain' then
      scan_inlines(block.content, block_number)
      state.plain_blocks[#state.plain_blocks + 1] = trim(text(block.content))
    elseif block.t == 'Figure' then
      register_object('fig', block.identifier, block_number, block, context.in_appendix)
      validate_caption('STO-8.5.2', block.identifier, text(block.caption))
      if not block.identifier:match('^fig:') then
        add_error('STO-8.5.1', 'идентификатор рисунка должен начинаться с fig:')
      end
      -- STO-8.5.6, STO-8.5.7, STO-8.5.8, STO-8.5.9.
      local image = first_image(block)
      local function figure_attribute(name)
        return block.attributes[name] or (image and image.attributes[name])
      end
      if figure_attribute('kind') == 'graph' and
         (is_placeholder(figure_attribute('x-axis')) or is_placeholder(figure_attribute('y-axis'))) then
        add_error('STO-8.5.6', block.identifier .. ': график требует атрибуты x-axis и y-axis')
      end
      if figure_attribute('rotation') ~= nil and figure_attribute('rotation') ~= '90ccw' then
        add_error('STO-8.5.7', block.identifier .. ': допустим только rotation="90ccw"')
      end
      if figure_attribute('paper') == 'A3' then
        add_error('STO-8.5.8', block.identifier .. ': A3 требует отдельного foldout/spread backend')
      end
    elseif block.t == 'Table' then
      local identifier, caption = table_identifier(block)
      register_object('tbl', identifier, block_number, block, context.in_appendix)
      validate_table(block, identifier, caption)
    elseif block.t == 'Div' and has_class(block, 'equation') then
      register_object('eq', block.identifier, block_number, block, context.in_appendix)
      state.equations[block.identifier] = {
        block = block_number,
        math = first_display_math(block),
        symbols = split_csv(block.attributes.symbols),
        definitions = block.attributes.definitions,
      }
      if not block.identifier:match('^eq:') then
        add_error('STO-8.7.5', 'идентификатор формулы должен начинаться с eq:')
      end
      if state.equations[block.identifier].math == nil then
        add_error('STO-8.7.2', block.identifier .. ': требуется одна выделенная display-формула')
      end
    elseif block.t == 'Div' and has_class(block, 'equation-where') then
      local target = block.attributes['for'] or ''
      state.where_blocks[target] = {block = block_number, element = block}
    elseif block.t == 'Div' and has_class(block, 'bibliography') then
      state.bibliography_block = block_number
    elseif block.t == 'Div' and has_class(block, 'susu-appendix') then
      local identifier = block.identifier
      local letter = block.attributes.letter or ''
      register_object('app', identifier, block_number, block, true)
      state.appendices[#state.appendices + 1] = {
        identifier = identifier,
        letter = letter,
        title = block.attributes.title or '',
        block = block_number,
      }
      -- STO-7.12.4: the profile uses the two categories named by the STO.
      local appendix_kind = lower(block.attributes.kind or '')
      if appendix_kind ~= 'обязательное' and appendix_kind ~= 'информационное' then
        add_error('STO-7.12.4', identifier .. ': kind должен быть «обязательное» или «информационное»')
      end
      scan_blocks(block.content, {in_appendix = true, appendix = letter})
    elseif block.t == 'BlockQuote' then
      scan_blocks(block.content, context)
    elseif block.t == 'BulletList' or block.t == 'OrderedList' then
      for _, item in ipairs(block.content) do scan_blocks(item, context) end
    elseif block.t == 'DefinitionList' then
      for _, entry in ipairs(block.content) do
        for _, definition in ipairs(entry[2]) do scan_blocks(definition, context) end
      end
    end
  end
end

local function validate_metadata(doc, mode)
  -- STO-AI-GATE, STO-EXT-GATE: exact review inventories are profile data,
  -- never hard-coded renderer state and never inferred from mutable journals.
  local profile_inventory = doc.meta['profile-inventory'] or {}
  local inventory_profile_id = text(profile_inventory['profile-id'])
  if inventory_profile_id == '' then
    add_error('STO-AI-GATE', 'profile inventory has no profile-id')
  elseif inventory_profile_id ~= text(doc.meta['active-profile-id']) then
    add_error('STO-AI-GATE', 'profile inventory belongs to another active profile')
  end
  local required_semantic_rule_ids = profile_inventory_set(
    'STO-AI-GATE', 'semantic-rule-ids', profile_inventory['semantic-rule-ids'])
  local required_external_item_ids = profile_inventory_set(
    'STO-EXT-GATE', 'external-item-ids', profile_inventory['external-item-ids'])

  local function required(clause, label, value)
    if is_placeholder(value) then
      if mode == 'strict' then
        add_error(clause, label .. ' не заполнено либо содержит placeholder')
      else
        add_warning(clause, label .. ' ожидает подтверждённых внешних данных')
      end
    end
  end

  local function digital_date(label, value)
    value = trim(value or '')
    if is_placeholder(value) then return end
    -- STO-8.4.9: a supplied digital date is exactly one dd.mm.yyyy token;
    -- range checks prevent formally shaped but impossible day/month values.
    local day, month, year = value:match('^(%d%d)%.(%d%d)%.(%d%d%d%d)$')
    if day == nil or tonumber(day) < 1 or tonumber(day) > 31 or
       tonumber(month) < 1 or tonumber(month) > 12 or tonumber(year) < 1 then
      add_error('STO-8.4.9', label .. ' должна иметь вид дд.мм.гггг в одной строке: ' .. value)
    end
  end

  -- STO-1, STO-5.1, STO-7.1.1, STO-A1, STO-7.2.1, STO-V.
  required('STO-1', 'подтверждение применимости СТО к направлению 09.03.02',
    text(doc.meta['standard-applicability']))
  required('STO-5.1', 'дисциплина', text(doc.meta.discipline))
  required('STO-7.1.1', 'вышестоящая организация', text(doc.meta['parent-organization']))
  required('STO-7.1.1', 'наименование университета', text(doc.meta.university))
  required('STO-7.1.1', 'факультет/высшая школа', text(doc.meta.school))
  required('STO-7.1.1', 'кафедра', text(doc.meta.department))
  required('STO-7.2.1', 'направление/специальность', text(doc.meta.direction))
  required('STO-7.1.1', 'тема', text(doc.meta.title))
  required('STO-7.1.1', 'ФИО автора', text(doc.meta.student and doc.meta.student.name))
  required('STO-7.1.1', 'группа', text(doc.meta.student and doc.meta.student.group))
  required('STO-7.1.1', 'руководитель', text(doc.meta.supervisor and doc.meta.supervisor.name))
  required('STO-7.1.1', 'нормоконтролер',
    text(doc.meta['normal-controller'] and doc.meta['normal-controller'].name))
  local code = text(doc.meta['document-code'])
  if not code:match('^ЮУрГУ–%d%d%d%d%d%d%.%d%d%d%d%.%d%d%d%.ПЗ К[РП]$') then
    if mode == 'strict' then
      add_error('STO-7.1.1', 'код работы должен иметь вид ЮУрГУ–090302.2026.123.ПЗ КР')
    else
      add_warning('STO-7.1.1', 'код работы пока не является выпускным: ' .. code)
    end
  end

  if not meta_bool(doc.meta['include-assignment']) then
    add_error('STO-6', 'обязательное задание на курсовую отключено')
  end
  local assignment = doc.meta.assignment or {}
  required('STO-7.2.1', 'полное ФИО в задании', text(assignment['student-full-name']))
  required('STO-7.2.1', 'срок сдачи', text(assignment['due-date']))
  required('STO-7.2.1', 'заведующий кафедрой', text(assignment['head-of-department']))
  required('STO-7.2.1', 'дата утверждения задания', text(assignment['approval-date']))
  required('STO-7.2.1', 'перечень вопросов задания', text(assignment.questions))
  required('STO-7.2.1', 'календарный план', text(assignment.calendar))
  digital_date('дата утверждения задания', text(assignment['approval-date']))
  digital_date('срок сдачи работы', text(assignment['due-date']))
  for index, calendar_item in ipairs(assignment.calendar or {}) do
    digital_date('срок календарного плана, строка ' .. index, text(calendar_item.due))
  end

  -- STO-6, STO-7.3.1, STO-7.3.4: annotation is mandatory; 500 characters
  -- remains a recommendation and therefore only emits a warning.
  local abstract = text(doc.meta.abstract)
  required('STO-7.3.1', 'аннотация', abstract)
  local length = pandoc.text.len(abstract)
  if length < 350 or length > 750 then
    add_warning('STO-7.3.4', 'объём аннотации ' .. length .. ' знаков; ориентир СТО — 500')
  end

  if mode == 'strict' then
    -- STO-AI-GATE: semantic rules are release-blocking and bound to the
    -- exact content hash so a changed document cannot reuse an old review.
    local review = doc.meta['semantic-review'] or {}
    validate_exact_record_set('STO-AI-GATE', 'semantic-review.rules',
      review.rules, required_semantic_rule_ids)
    if text(review.status) ~= 'pass' then
      add_error('STO-AI-GATE', 'семантический аудит отсутствует либо имеет status != pass')
    end
    if text(review['content-hash']) ~= text(doc.meta['content-hash']) then
      add_error('STO-AI-GATE', 'семантический аудит относится к другой версии содержания')
    end
    required('STO-AI-GATE', 'рецензент семантического аудита', text(review.reviewer))
    required('STO-AI-GATE', 'дата семантического аудита', text(review['reviewed-at']))
    for _, rule in ipairs(review.rules or {}) do
      local rule_id = text(rule.id)
      local status = lower(text(rule.status))
      if status ~= 'pass' and status ~= 'not-applicable' then
        add_error('STO-AI-GATE', rule_id .. ': status должен быть pass или обоснованным not-applicable')
      end
      if is_placeholder(text(rule.evidence)) then
        add_error('STO-AI-GATE', rule_id .. ': отсутствует проверяемое evidence')
      end
      if status == 'not-applicable' and is_placeholder(text(rule.note)) then
        add_error('STO-AI-GATE', rule_id .. ': неприменимость не обоснована')
      end
    end
    local external = doc.meta['external-acceptance'] or {}
    validate_exact_record_set('STO-EXT-GATE', 'external-acceptance.items',
      external.items, required_external_item_ids)
    if text(external['profile-id']) ~= inventory_profile_id then
      add_error('STO-EXT-GATE', 'external acceptance belongs to another profile')
    end
    if text(external.status) ~= 'accepted' then
      add_error('STO-EXT-GATE', 'внешние реквизиты/исключения не подтверждены')
    end
    required('STO-EXT-GATE', 'лицо, принявшее внешние решения', text(external['accepted-by']))
    required('STO-EXT-GATE', 'дата принятия внешних решений', text(external['accepted-at']))
    for _, item in ipairs(external.items or {}) do
      local item_id = text(item.id)
      local item_status = lower(text(item.status))
      if item_status ~= 'accepted' and item_status ~= 'not-applicable' then
        add_error('STO-EXT-GATE', item_id .. ': внешнее решение не закрыто')
      end
      if is_placeholder(text(item.evidence)) or is_placeholder(text(item.decision)) then
        add_error('STO-EXT-GATE', item_id .. ': отсутствует evidence/decision')
      end
    end
  end
end

local function validate_headers()
  local previous_level = 0
  local numbered_sections = {}
  local introduction = nil
  local conclusion = nil

  for _, header in ipairs(state.headers) do
    if not header.in_appendix then
      local unnumbered = false
      for _, class in ipairs(header.classes or {}) do
        if class == 'unnumbered' then unnumbered = true end
      end
      local value = trim(header.value)
      local last = pandoc.text.sub(value, -1, -1)
      -- STO-8.2.3, STO-8.2.7, STO-8.2.8, STO-8.4.7.
      if last == '.' or last == ':' or last == ';' then
        add_error('STO-8.2.8', 'заголовок заканчивается знаком «' .. last .. '»: ' .. value)
      end
      if value:match('^%d+[%.%s]') then
        add_error('STO-8.2.2', 'номер заголовка вводится только генератором: ' .. value)
      end
      if header.level > previous_level + 1 and previous_level ~= 0 then
        add_error('STO-8.2.1', 'пропущен уровень заголовка перед «' .. value .. '»')
      end
      previous_level = header.level

      if lower(value) == 'введение' then introduction = header.block end
      if lower(value) == 'заключение' then conclusion = header.block end
      if header.level == 1 and not unnumbered then
        numbered_sections[#numbered_sections + 1] = header
      end
    end
  end

  -- STO-6, STO-7.6, STO-8.2.5, STO-8.2.6.
  if introduction == nil then add_error('STO-6', 'отсутствует обязательное введение') end
  if conclusion == nil then add_error('STO-6', 'отсутствует обязательное заключение') end
  if #numbered_sections == 0 then add_error('STO-6', 'отсутствует основной материал') end
  if state.bibliography_block == nil then add_error('STO-6', 'отсутствует библиографический список') end
  if introduction and #numbered_sections > 0 and introduction > numbered_sections[1].block then
    add_error('STO-6', 'введение должно предшествовать основной части')
  end
  if conclusion and #numbered_sections > 0 and conclusion < numbered_sections[#numbered_sections].block then
    add_error('STO-6', 'заключение должно следовать после основной части')
  end
  if conclusion and state.bibliography_block and conclusion > state.bibliography_block then
    add_error('STO-6', 'библиография должна следовать после заключения')
  end

  local number_words = {
    'один', 'два', 'три', 'четыре', 'пять', 'шесть', 'семь', 'восемь', 'девять', 'десять',
    'одиннадцать', 'двенадцать', 'тринадцать', 'четырнадцать', 'пятнадцать'
  }
  for index, section in ipairs(numbered_sections) do
    local boundary = numbered_sections[index + 1] and numbered_sections[index + 1].block or
      (conclusion or math.huge)
    local children = {}
    for _, header in ipairs(state.headers) do
      if not header.in_appendix and header.level == 2 and
         header.block > section.block and header.block < boundary then
        children[#children + 1] = header
      end
    end
    -- STO-8.2.4: if subdivisions are used there must be more than one.
    if #children == 1 then
      add_error('STO-8.2.4', 'раздел «' .. section.value .. '» содержит ровно один подраздел')
    end
    -- STO-8.2.5: every numbered first-level section ends with an
    -- unnumbered "Выводы по разделу <word>" subsection.
    local expected = 'выводы по разделу ' .. (number_words[index] or tostring(index))
    if #children == 0 or lower(children[#children].value) ~= expected then
      add_error('STO-8.2.5', 'раздел ' .. index .. ' должен заканчиваться «' .. expected .. '»')
    else
      local is_unnumbered = false
      for _, class in ipairs(children[#children].classes or {}) do
        if class == 'unnumbered' then is_unnumbered = true end
      end
      if not is_unnumbered then
        add_error('STO-8.2.5', '«' .. expected .. '» не должен иметь номера')
      end
    end
  end
end

local function validate_text_rules()
  for _, value in ipairs(state.plain_blocks) do
    local normalized = lower(value)
    -- STO-5.5: first-person singular author voice is prohibited.
    if contains_word(normalized, 'я') then
      add_error('STO-5.5', 'обнаружено личное местоимение «я»: ' .. value)
    end
    -- STO-8.5.4, STO-8.6.4: object words may not be abbreviated.
    if normalized:match('рис%.') then add_error('STO-8.5.4', 'сокращение «рис.» запрещено') end
    if normalized:match('табл%.') then add_error('STO-8.6.4', 'сокращение «табл.» запрещено') end
    -- STO-8.4.5, STO-8.4.7, STO-8.4.8.
    if value:match('%s+[,.!?;:]') then
      add_error('STO-8.4.7', 'пробел перед знаком препинания: ' .. value)
    end
    if value:match('%d+%-%d+') then
      add_error('STO-8.4.8', 'числовой диапазон должен использовать тире, не дефис: ' .. value)
    end
    local without_versions = value
      :gsub('ГОСТ%s+%d+%.%d+[%d%.–%-]*', '')
      :gsub('%d+%.%d+%.%d+', '')
    if without_versions:match('%d+%.%d+') then
      add_error('STO-8.4.7', 'десятичный разделитель должен быть запятой: ' .. value)
    end
  end
end

local function validate_objects()
  for identifier, object in pairs(state.objects) do
    local refs = state.refs[identifier] or {}
    if #refs == 0 then
      local clause = ({fig='8.5.4', tbl='8.6.4', eq='8.7.11', app='7.12.4'})[object.kind]
      add_error('STO-' .. clause, identifier .. ': отсутствует ссылка в тексте')
    else
      -- STO-8.5.3, STO-8.6.2, STO-7.12.6: first mention precedes
      -- the object; figure/table must be the immediately following block.
      if refs[1].block >= object.block then
        local clause = object.kind == 'fig' and '8.5.3' or
          (object.kind == 'tbl' and '8.6.2' or '7.12.6')
        add_error('STO-' .. clause, identifier .. ': объект расположен до первого упоминания')
      end
      if (object.kind == 'fig' or object.kind == 'tbl') and
         object.block ~= refs[1].block + 1 then
        local clause = object.kind == 'fig' and '8.5.3' or '8.6.2'
        add_error('STO-' .. clause, identifier .. ': объект должен непосредственно следовать за первым упоминанием')
      end
    end
  end

  -- STO-7.12.3, STO-7.12.5, STO-7.12.6: appendix identifiers,
  -- permitted sequence and reference order.
  local allowed = {'А','Б','В','Г','Д','Е','Ж','И','К','Л','М','Н','П','Р','С','Т','У','Ф','Х','Ц','Ш','Щ','Э','Ю','Я'}
  for index, appendix in ipairs(state.appendices) do
    if not appendix.identifier:match('^app:') then
      add_error('STO-7.12.4', 'идентификатор приложения должен начинаться с app:')
    end
    if appendix.letter ~= allowed[index] then
      add_error('STO-7.12.3', appendix.identifier .. ': ожидалось обозначение ' .. (allowed[index] or '?'))
    end
    if is_placeholder(appendix.title) then
      add_error('STO-7.12.3', appendix.identifier .. ': отсутствует тематический заголовок')
    end
    if index > 1 then
      local previous_refs = state.refs[state.appendices[index - 1].identifier] or {}
      local current_refs = state.refs[appendix.identifier] or {}
      if #previous_refs > 0 and #current_refs > 0 and previous_refs[1].block > current_refs[1].block then
        add_error('STO-7.12.6', 'порядок приложений не совпадает с порядком первых ссылок')
      end
    end
  end

  -- STO-8.7.2, STO-8.7.4, STO-8.7.7: structured formula explanation.
  for identifier, equation in pairs(state.equations) do
    if equation.definitions ~= 'previous' then
      local where = state.where_blocks[identifier]
      if where == nil then
        add_error('STO-8.7.7', identifier .. ': отсутствует блок .equation-where')
      else
        if where.block ~= equation.block + 1 then
          add_error('STO-8.7.4', identifier .. ': расшифровка должна непосредственно следовать за формулой')
        end
        local item_count = 0
        for _, block in ipairs(where.element.content) do
          if block.t == 'BulletList' then item_count = item_count + #block.content end
        end
        if #equation.symbols > 0 and item_count ~= #equation.symbols then
          add_error('STO-8.7.7', identifier .. ': число пояснений не совпадает со списком symbols')
        end
      end
      if equation.math and not trim(equation.math):match(',$') then
        add_error('STO-8.7.7', identifier .. ': перед блоком «где» формула должна заканчиваться запятой')
      end
    end
  end
end

function Pandoc(doc)
  local mode = lower(text(doc.meta['compliance-mode']))
  if mode == '' then mode = 'draft' end

  -- STO-NOTATION: only the documented semantic subset can reach the trusted
  -- renderer.  This prevents an AI author from bypassing the STO style with
  -- raw TeX, layout attributes, hard line breaks or unreviewed containers.
  doc:walk({
    -- STO-7.11.5: this coursework profile deliberately selects the
    -- bibliography-list scheme.  Notes are fail-closed until a separate
    -- footnote profile implements page/end placement, pointers and type size.
    Note = function()
      add_error('STO-7.11.5', 'сноски запрещены выбранным профилем; источник оформляется через библиографический список')
    end,
    RawInline = function(element)
      add_error('STO-NOTATION', 'сырой inline-код ' .. element.format .. ' запрещён')
    end,
    RawBlock = function(element)
      add_error('STO-NOTATION', 'сырой block-код ' .. element.format .. ' запрещён')
    end,
    LineBreak = function()
      add_error('STO-NOTATION', 'принудительный перенос строки запрещён')
    end,
    HorizontalRule = function()
      add_error('STO-NOTATION', 'горизонтальная линия в содержании запрещена')
    end,
    Span = function(element)
      if #element.classes > 0 or table_has_value(element.attributes) or element.identifier ~= '' then
        add_error('STO-NOTATION', 'оформительские Span-атрибуты запрещены')
      end
    end,
    Header = function(element)
      for _, class in ipairs(element.classes or {}) do
        if class ~= 'unnumbered' then
          add_error('STO-NOTATION', 'недопустимый класс заголовка «' .. class .. '»')
        end
      end
      validate_attribute_names('STO-NOTATION', element, {})
    end,
    Figure = function(element)
      validate_attribute_names('STO-NOTATION', element, {
        kind=true, ['x-axis']=true, ['y-axis']=true, rotation=true, paper=true,
      })
    end,
    Image = function(element)
      validate_attribute_names('STO-NOTATION', element, {
        width=true, height=true, kind=true, ['x-axis']=true, ['y-axis']=true,
        rotation=true, paper=true,
      })
      if #element.classes > 0 or element.identifier ~= '' then
        add_error('STO-NOTATION', 'идентификатор и классы задаются рисунку, а не вложенному Image')
      end
    end,
    Div = function(element)
      local known = has_class(element, 'equation') or
        has_class(element, 'equation-where') or
        has_class(element, 'bibliography') or
        has_class(element, 'susu-appendix')
      if not known or #element.classes ~= 1 then
        add_error('STO-NOTATION', 'неизвестный либо составной Div-класс')
        return
      end
      if has_class(element, 'equation') then
        validate_attribute_names('STO-NOTATION', element, {symbols=true, definitions=true})
      elseif has_class(element, 'equation-where') then
        validate_attribute_names('STO-NOTATION', element, {['for']=true})
      elseif has_class(element, 'susu-appendix') then
        validate_attribute_names('STO-NOTATION', element, {letter=true, title=true, kind=true})
      else
        validate_attribute_names('STO-NOTATION', element, {})
      end
    end,
  })

  validate_metadata(doc, mode)
  scan_blocks(doc.blocks)
  validate_headers()
  validate_text_rules()
  validate_objects()

  -- STO-8.5.10, STO-8.6.3, STO-8.7.5: the renderer changes to
  -- global number 1 when exactly one main object of that type exists.
  doc.meta['susu-single-figure'] = pandoc.MetaBool(state.main_counts.fig == 1)
  doc.meta['susu-single-table'] = pandoc.MetaBool(state.main_counts.tbl == 1)
  doc.meta['susu-single-equation'] = pandoc.MetaBool(state.main_counts.eq == 1)

  for _, warning in ipairs(warnings) do
    io.stderr:write('WARNING ' .. warning .. '\n')
  end
  if #errors > 0 then
    error('\n' .. table.concat(errors, '\n'))
  end
  io.stderr:write('STO validation passed (' .. mode .. ' mode).\n')
  return doc
end
