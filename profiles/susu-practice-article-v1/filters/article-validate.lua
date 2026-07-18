-- Минимальная валидация метаданных восстановленной статьи.

local required_metadata = {
  "title",
  "author",
  "organization",
  "abstract",
  "keywords"
}

function Pandoc(document)
  local compliance_mode = pandoc.utils.stringify(
    document.meta["compliance-mode"] or "draft"
  ):lower()

  if compliance_mode == "strict" then
    error(
      "ARTICLE-STRICT-UNSUPPORTED: профиль статьи пока поддерживает только Draft; " ..
      "нормативный Strict-контракт не реализован."
    )
  end

  for _, key in ipairs(required_metadata) do
    local value = document.meta[key]

    if value == nil or pandoc.utils.stringify(value) == "" then
      error("Article metadata field is required: " .. key)
    end
  end

  if #document.blocks == 0 then
    error("Article body must not be empty.")
  end

  return document
end
