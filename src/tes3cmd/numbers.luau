--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Numbers as text for people (jess-omwaddon's `text::float_text`): the shortest spelling that reads
back as the same value, always with a decimal point, in scientific notation outside 1e-4 to 1e16.
A value that is exactly an f32 (every float a plugin stores) is spelled as that f32, so a stored
0.1 reads `0.1`, not `0.10000000149011612`.
]]

local Scratch = buffer.create(4)

local function f32(value: number): number
  buffer.writef32(Scratch, 0, value)
  return buffer.readf32(Scratch, 0)
end

--- The shortest decimal digits that read back as `value` (as an f32 when `single`): the digits
--- without a point, and the decimal exponent of the first one.
local function shortest(value: number, single: boolean): (string, number)
  for precision = 1, 17 do
    local text = string.format(`%.{precision - 1}e`, value)
    local back = tonumber(text) :: number
    if (if single then f32(back) else back) == value then
      local mantissa, exponent = string.match(text, '^%-?(%d[%.%d]*)e([%+%-]%d+)$')
      local digits = string.gsub(mantissa :: string, '%.', '')
      digits = string.gsub(digits, '0+$', '')
      if digits == '' then digits = '0' end

      return digits, tonumber(exponent) :: number
    end
  end

  return string.format('%.17g', value), 0
end

--- `value` as Rust's `{}` and `{:e}` spell it, plus the decimal point jess always shows.
local function floatText(value: number): string
  if value ~= value then return 'NaN' end

  if value == math.huge then return 'inf' end

  if value == -math.huge then return '-inf' end

  local sign = if value < 0 or (value == 0 and 1 / value < 0) then '-' else ''
  if value == 0 then return sign .. '0.0' end

  local magnitude = math.abs(value)
  local digits, exponent = shortest(magnitude, f32(magnitude) == magnitude)
  if magnitude < 1e-4 or magnitude >= 1e16 then
    local head, tail = string.sub(digits, 1, 1), string.sub(digits, 2)
    return `{sign}{head}.{if tail == '' then '0' else tail}e{exponent}`
  end

  local text
  if exponent < 0 then
    text = '0.' .. string.rep('0', -exponent - 1) .. digits
  elseif #digits <= exponent + 1 then
    text = digits .. string.rep('0', exponent + 1 - #digits) .. '.0'
  else
    text = string.sub(digits, 1, exponent + 1) .. '.' .. string.sub(digits, exponent + 2)
  end

  return sign .. text
end

return table.freeze { floatText = floatText }
