-- Engine-owned Strict gates generated from requirements.json.
-- The filter validates release evidence but never invents review decisions.
-- STO-AI-GATE, STO-EXT-GATE.

local errors = {}

local function text(value)
  if value == nil then return '' end
  return pandoc.utils.stringify(value)
end

local function lower(value)
  return pandoc.text.lower(text(value))
end

local function is_placeholder(value)
  value = text(value):gsub('^%s+', ''):gsub('%s+$', '')
  return value == '' or value:find('%[') ~= nil or value:find('_') ~= nil
end

local function add_error(code, message)
  errors[#errors + 1] = code .. ': ' .. message
end

local function inventory_set(code, label, values)
  local result = {}
  for _, value in ipairs(values or {}) do
    local id = text(value)
    if id == '' then
      add_error(code, label .. ': empty id in generated inventory')
    elseif result[id] then
      add_error(code, label .. ': duplicate id ' .. id)
    else
      result[id] = true
    end
  end
  return result
end

local function exact_record_set(code, label, records, expected)
  local actual = {}
  for _, record in ipairs(records or {}) do
    local id = text(record.id)
    if id == '' then
      add_error(code, label .. ': empty id')
    elseif actual[id] then
      add_error(code, label .. ': duplicate id ' .. id)
    else
      actual[id] = true
    end
  end
  for id, _ in pairs(expected) do
    if not actual[id] then add_error(code, label .. ': missing id ' .. id) end
  end
  for id, _ in pairs(actual) do
    if not expected[id] then add_error(code, label .. ': unknown id ' .. id) end
  end
end

local function required(code, label, value)
  if is_placeholder(value) then add_error(code, label .. ' не заполнено') end
end

function Pandoc(doc)
  errors = {}
  local mode = lower(doc.meta['compliance-mode'])
  if mode == '' then mode = 'draft' end
  local inventory = doc.meta['profile-inventory'] or {}
  local inventory_profile_id = text(inventory['profile-id'])
  if inventory_profile_id == '' then
    add_error('STO-AI-GATE', 'profile inventory has no profile-id')
  elseif inventory_profile_id ~= text(doc.meta['active-profile-id']) then
    add_error('STO-AI-GATE', 'profile inventory belongs to another active profile')
  end

  if mode == 'strict' then
    local semantic_ids = inventory_set(
      'STO-AI-GATE', 'semantic-rule-ids', inventory['semantic-rule-ids'])
    local external_ids = inventory_set(
      'STO-EXT-GATE', 'external-item-ids', inventory['external-item-ids'])
    local review = doc.meta['semantic-review'] or {}
    exact_record_set('STO-AI-GATE', 'semantic-review.rules', review.rules, semantic_ids)
    if next(semantic_ids) ~= nil then
      if lower(review.status) ~= 'pass' then
        add_error('STO-AI-GATE', 'семантический аудит отсутствует либо имеет status != pass')
      end
      if text(review['content-hash']) ~= text(doc.meta['content-hash']) then
        add_error('STO-AI-GATE', 'семантический аудит относится к другой версии содержания')
      end
      required('STO-AI-GATE', 'рецензент семантического аудита', review.reviewer)
      required('STO-AI-GATE', 'дата семантического аудита', review['reviewed-at'])
      for _, rule in ipairs(review.rules or {}) do
        local status = lower(rule.status)
        local id = text(rule.id)
        if status ~= 'pass' and status ~= 'not-applicable' then
          add_error('STO-AI-GATE', id .. ': status должен быть pass или обоснованным not-applicable')
        end
        if is_placeholder(rule.evidence) then
          add_error('STO-AI-GATE', id .. ': отсутствует проверяемое evidence')
        end
        if status == 'not-applicable' and is_placeholder(rule.note) then
          add_error('STO-AI-GATE', id .. ': неприменимость не обоснована')
        end
      end
    end

    local external = doc.meta['external-acceptance'] or {}
    exact_record_set('STO-EXT-GATE', 'external-acceptance.items', external.items, external_ids)
    if next(external_ids) ~= nil then
      if text(external['profile-id']) ~= inventory_profile_id then
        add_error('STO-EXT-GATE', 'external acceptance belongs to another profile')
      end
      if lower(external.status) ~= 'accepted' then
        add_error('STO-EXT-GATE', 'внешние реквизиты и исключения не подтверждены')
      end
      required('STO-EXT-GATE', 'лицо, принявшее внешние решения', external['accepted-by'])
      required('STO-EXT-GATE', 'дата принятия внешних решений', external['accepted-at'])
      for _, item in ipairs(external.items or {}) do
        local status = lower(item.status)
        local id = text(item.id)
        if status ~= 'accepted' and status ~= 'not-applicable' then
          add_error('STO-EXT-GATE', id .. ': внешнее решение не закрыто')
        end
        if is_placeholder(item.evidence) or is_placeholder(item.decision) then
          add_error('STO-EXT-GATE', id .. ': отсутствует evidence/decision')
        end
      end
    end
  end

  if #errors > 0 then error('\n' .. table.concat(errors, '\n')) end
  return doc
end
