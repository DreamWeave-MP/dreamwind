--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
The legacy code pages TES3 text is written in (jess-io's `LegacyEncoding`).

Every byte means something in these code pages, so decoding never fails, and leading bytes that
look like a byte order mark are text, not a switch to UTF-8: OpenMW translates every byte through
its table (`StatelessUtf8Encoder::getUtf8` in `components/toutf8/toutf8.cpp`). Text that is ASCII
is the same bytes in UTF-8, so it never leaves Luau; only text with a byte over 0x7f goes through
`@dream/bytes`.
]]

local bytes = require '@dream/bytes'

export type Encoding = 'win1250' | 'win1251' | 'win1252'

local Labels: { [string]: string } =
  { win1250 = 'windows-1250', win1251 = 'windows-1251', win1252 = 'windows-1252' }

local Names: { [string]: string } =
  { win1250 = 'Windows-1250', win1251 = 'Windows-1251', win1252 = 'Windows-1252' }

local function label(encoding: string): string
  return Labels[encoding]
    or error(`unknown encoding '{encoding}': expected win1250, win1251, or win1252`)
end

--- The code page's name as people know it: `Windows-1252`.
local function name(encoding: string): string
  return Names[encoding] or error(`unknown encoding '{encoding}'`)
end

--- Where the first byte in `[from, to)` that is a NUL or over 0x7f is, or `to`: four bytes at a
--- time, a word with neither going by in a handful of native instructions.
local function plainUntil(source: buffer, from: number, to: number): number
  local i = from
  while i + 4 <= to do
    local word = buffer.readu32(source, i)
    -- A high bit set, or a zero byte (the classic `(x - 0x01010101) & ~x & 0x80808080`).
    if
      bit32.btest(bit32.bor(word, bit32.band(word - 0x01010101, bit32.bnot(word))), 0x80808080)
    then
      break
    end

    i += 4
  end

  while i < to do
    local byte = buffer.readu8(source, i)
    if byte == 0 or byte >= 0x80 then return i end

    i += 1
  end

  return to
end

--- `length` bytes of `source` at `offset`, cut at the first NUL, as UTF-8 text.
local function decode(source: buffer, offset: number, length: number, encoding: string): string
  local finish = offset + length
  -- Most strings end in their one NUL; leave it out before looking.
  if length > 0 and buffer.readu8(source, finish - 1) == 0 then
    finish -= 1
  end

  local at = plainUntil(source, offset, finish)
  if at == finish then return buffer.readstring(source, offset, finish - offset) end

  if buffer.readu8(source, at) == 0 then return buffer.readstring(source, offset, at - offset) end

  local text = buffer.readstring(source, offset, finish - offset)
  local nul = string.find(text, '\0', at - offset + 1, true)
  if nul then text = string.sub(text, 1, nul - 1) end
  return bytes.decode(text, label(encoding))
end

--- Whether `[from, to)` is all ASCII.
local function ascii(source: buffer, from: number, to: number): boolean
  local i = from
  while i + 4 <= to do
    if bit32.btest(buffer.readu32(source, i), 0x80808080) then return false end

    i += 4
  end

  while i < to do
    if buffer.readu8(source, i) >= 0x80 then return false end

    i += 1
  end

  return true
end

--- Like `decode`, keeping every byte: NUL is text like any other.
local function decodeExact(source: buffer, offset: number, length: number, encoding: string): string
  local text = buffer.readstring(source, offset, length)
  if ascii(source, offset, offset + length) then return text end

  return bytes.decode(text, label(encoding))
end

--- A string's bytes as UTF-8 text, cut at the first NUL.
local function decodeString(text: string, encoding: string): string
  local at = string.find(text, '[%z\128-\255]')
  if not at then return text end

  if string.byte(text, at) == 0 then return string.sub(text, 1, at - 1) end

  local nul = string.find(text, '\0', at, true)
  if nul then text = string.sub(text, 1, nul - 1) end
  return bytes.decode(text, label(encoding))
end

--- The first character `text` has that `encoding` lacks, or nil.
local function unencodable(text: string, encoding: string): string?
  local code = label(encoding)
  for _, codepoint in utf8.codes(text) do
    if codepoint < 0x80 then continue end

    local character = utf8.char(codepoint)
    if not pcall(bytes.encode, character, code) then return character end
  end

  return nil
end

--- `text` in the code page, or nil and the character it lacks. NUL is the caller's to refuse.
local function encode(text: string, encoding: string): (string?, string?)
  if not string.find(text, '[\128-\255]') then return text, nil end

  -- bytes.encode throws on a character the code page lacks.
  local ok, encoded = pcall(bytes.encode, text, label(encoding))
  if ok then return buffer.tostring(encoded :: buffer), nil end

  return nil, unencodable(text, encoding)
end

--- `snake_case` (or `kebab-case`) as camelCase, the way jess-omwaddon's `symbol::camel_case`
--- spells field names for scripts: a `_` or `-` before a lowercase letter becomes that letter
--- uppercased (not at the start), and every other one stays, so `bonus_0` stays `bonus_0`.
local function camelCase(name: string): string
  if not string.find(name, '[_%-]') then return name end

  local out = {}
  local i = 1
  while i <= #name do
    local character = string.sub(name, i, i)
    local after = string.sub(name, i + 1, i + 1)
    if (character == '_' or character == '-') and #out > 0 and string.find(after, '^%l') then
      table.insert(out, string.upper(after))
      i += 2
    else
      table.insert(out, character)
      i += 1
    end
  end

  return table.concat(out)
end

--- A character as an error names it: `'Ж' (U+0416)`.
local function describe(character: string): string
  return string.format('\'%s\' (U+%04X)', character, utf8.codepoint(character))
end

return table.freeze {
  camelCase = camelCase,
  decode = decode,
  decodeExact = decodeExact,
  decodeString = decodeString,
  describe = describe,
  encode = encode,
  label = label,
  name = name,
  unencodable = unencodable,
}
