-- Trusted semantic renderer for the referat profile.

local function has_class(element, class_name)
  for _, class in ipairs(element.classes or {}) do
    if class == class_name then return true end
  end
  return false
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
      local id = inline.citations[1].id
      local kind = reference_kind(id)
      if kind then
        if #output > 0 and output[#output].t == 'Space' then output:remove(#output) end
        local command = kind == 'eq' and '\\eqref{' .. id .. '}' or '\\ref{' .. id .. '}'
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

local function render_header(header)
  if header.level == 1 then
    for _, inline in ipairs(header.content) do
      if inline.t == 'Str' then inline.text = pandoc.text.upper(inline.text) end
    end
    -- Top-level parts are visually independent document sections. Keeping
    -- the page break in the renderer prevents authors from adding raw TeX.
    return {
      pandoc.RawBlock('latex', '\\clearpage'),
      header,
    }
  end
  return header
end

local function render_div(div)
  if has_class(div, 'bibliography') then
    -- STO17-4.2.2.8, STO17-4.3.12.
    return pandoc.RawBlock('latex',
      '\\clearpage\\printbibliography[heading=bibintoc,title={БИБЛИОГРАФИЧЕСКИЙ СПИСОК}]')
  end
  if has_class(div, 'susu-appendix') then
    local letter = div.attributes.letter or 'А'
    local title = div.attributes.title or 'Приложение'
    local blocks = pandoc.List({})
    blocks:insert(pandoc.RawBlock('latex',
      '\\begin{SUSUReferatAppendix}{' .. letter .. '}{' .. title .. '}{' .. div.identifier .. '}'))
    blocks:extend(div.content)
    blocks:insert(pandoc.RawBlock('latex', '\\end{SUSUReferatAppendix}'))
    return blocks
  end
  return nil
end

return {
  {Inlines = transform_references, Header = render_header},
  {Div = render_div},
}
