-- Engine-owned interpreter for declarative document structure requirements.
-- Profiles provide only stable element IDs, ordering edges and diagnostics in
-- effective-requirements.yaml; this filter never branches on a profile ID.
--
-- STO-6, STO17-4.2.1: required semantic parts and their relative order are
-- enforced by the same algorithm while retaining profile-specific rule IDs.

local errors = {}

local function text(value)
  if value == nil then return '' end
  return pandoc.utils.stringify(value)
end

local function lower(value)
  return pandoc.text.lower(value)
end

local function has_class(element, class_name)
  for _, class in ipairs(element.classes or {}) do
    if class == class_name then return true end
  end
  return false
end

local function diagnostic_map(doc)
  local result = {}
  for _, diagnostic in ipairs(doc.meta['profile-diagnostics'] or {}) do
    local code = text(diagnostic.code)
    if code ~= '' then
      result[code] = {
        message = text(diagnostic.message),
        hint = text(diagnostic.hint),
      }
    end
  end
  return result
end

local function add_contract_error(diagnostics, code, detail)
  local diagnostic = diagnostics[code]
  if diagnostic == nil then
    errors[#errors + 1] = code .. ': ' .. detail
    return
  end
  errors[#errors + 1] = code .. ': ' .. diagnostic.message .. ': ' .. detail ..
    '. Подсказка: ' .. diagnostic.hint
end

local function locate_elements(doc)
  local introduction = nil
  local conclusion = nil
  local bibliography = nil
  local main_headers = {}

  for index, block in ipairs(doc.blocks) do
    if block.t == 'Header' and block.level == 1 then
      local value = lower(text(block.content))
      if value == 'введение' then
        introduction = index
      elseif value == 'заключение' then
        conclusion = index
      elseif not has_class(block, 'unnumbered') then
        main_headers[#main_headers + 1] = index
      end
    elseif block.t == 'Div' and has_class(block, 'bibliography') then
      bibliography = index
    end
  end

  return {
    introduction = introduction and {first=introduction, last=introduction} or nil,
    ['main-matter'] = #main_headers > 0 and {
      first=main_headers[1], last=main_headers[#main_headers],
    } or nil,
    conclusion = conclusion and {first=conclusion, last=conclusion} or nil,
    bibliography = bibliography and {first=bibliography, last=bibliography} or nil,
  }
end

function Pandoc(doc)
  errors = {}
  local structure = doc.meta['profile-structure'] or {}
  local diagnostics = diagnostic_map(doc)
  local positions = locate_elements(doc)

  for _, required in ipairs(structure['required-elements'] or {}) do
    local element_id = text(required.id)
    if positions[element_id] == nil then
      add_contract_error(diagnostics, text(required.diagnostic),
        'отсутствует элемент «' .. element_id .. '»')
    end
  end

  for _, edge in ipairs(structure['element-order'] or {}) do
    local first = text(edge.first)
    local then_element = text(edge['then'])
    local first_position = positions[first]
    local then_position = positions[then_element]
    if first_position and then_position and first_position.last > then_position.first then
      add_contract_error(diagnostics, text(edge.diagnostic),
        '«' .. first .. '» должно находиться перед «' .. then_element .. '»')
    end
  end

  if #errors > 0 then error('\n' .. table.concat(errors, '\n')) end
  return doc
end
