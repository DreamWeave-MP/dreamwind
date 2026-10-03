--!strict
-- A value as one line of JSON that two equal values always spell the same way: object keys
-- sorted, every number with the digits that round-trip it (`%.17g`; NaN and the infinities as the
-- strings `"NaN"`, `"inf"`, `"-inf"`), a table with keys 1 to n and nothing else as an array, and an
-- empty table as `[]`, since a Luau table can't tell an empty list from an empty object.

local function quote(text: string): string
  local escaped = string.gsub(text, '[%c"\\\128-\255]', function(c: string): string
    local byte = string.byte(c)
    if c == '"' then return '\\"' end

    if c == '\\' then return '\\\\' end

    if c == '\n' then return '\\n' end

    if c == '\r' then return '\\r' end

    if c == '\t' then return '\\t' end

    if byte < 0x20 or byte == 0x7f then return string.format('\\u%04x', byte) end

    return c
  end)
  return `"{escaped}"`
end

local function number(value: number): string
  if value ~= value then return '"NaN"' end

  if value == math.huge then return '"inf"' end

  if value == -math.huge then return '"-inf"' end

  if value == 0 and 1 / value < 0 then return '-0' end

  if value % 1 == 0 and math.abs(value) < 2 ^ 53 then return string.format('%d', value) end

  return string.format('%.17g', value)
end

local function encode(value: unknown): string
  local kind = type(value)
  if kind == 'number' then return number(value :: number) end

  if kind == 'string' then return quote(value :: string) end

  if kind == 'boolean' then return tostring(value) end

  if kind == 'nil' then return 'null' end

  if kind ~= 'table' then return quote(`<{kind}>`) end

  local t = value :: { [unknown]: unknown }
  local count = 0
  for _ in t do
    count += 1
  end

  if count == 0 then return '[]' end

  if count == #t then
    local parts = table.create(count)
    for i = 1, count do
      parts[i] = encode(t[i])
    end

    return `[{table.concat(parts, ',')}]`
  end

  local keys: { string } = {}
  for key in t do
    table.insert(keys, tostring(key))
  end

  table.sort(keys)
  local parts = table.create(#keys)
  for i, key in keys do
    parts[i] = `{quote(key)}:{encode(t[key])}`
  end

  return `\{{table.concat(parts, ',')}\}`
end

return encode
