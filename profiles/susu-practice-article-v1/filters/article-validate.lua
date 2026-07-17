-- Минимальная валидация метаданных восстановленной статьи.

local required_metadata = {
  "title",
  "author",
  "organization",
  "abstract",
  "keywords"
}

function Pandoc(document)
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
