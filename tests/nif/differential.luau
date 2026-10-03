--!strict
-- SPDX-License-Identifier: MIT OR Apache-2.0
-- jess-nif, through `jess.nif`, is this package's oracle while it exists: every record must
-- decode to what it decodes to, a file saved untouched must be the bytes it came from, and a file
-- whose records were all decoded must save as jess-nif saves it. Run through
-- `cargo test -p jess-lua --test nif_experiment`.
local Array = require '../../src/nif/internal/array'
local port = require '../../src/nif/init'

--- Where the port's shapes differ from jess-nif's tables on purpose: array views for its lists,
--- vectors for its lists of two or three numbers, three row vectors for a matrix's nine numbers,
--- and -1 or false for a null slot in a list.
--- jess-nif's own defects the differential found and set aside, by kind.
local Known = { lossyEnums = 0 }

local function isNull(value: unknown): boolean
  return value == nil or value == jess.null or value == false or value == -1
end

local function differ(a: number, b: number): boolean return a ~= b and not (a ~= a and b ~= b) end

local function compare(rust: unknown, mine: unknown, path: string, problems: { string })
  if #problems >= 20 then return end

  if Array.isArray(mine) then mine = (mine :: Array.Array):toTable() end

  if type(rust) == 'table' and typeof(mine) == 'vector' then
    local list, v = rust :: { number }, mine :: vector
    if differ(list[1], v.x) or differ(list[2], v.y) or (#list == 3 and differ(list[3], v.z)) then
      table.insert(problems, `{path}: {v} where jess-nif has \{ {table.concat(list, ', ')} }`)
    end

    return
  end

  if type(rust) == 'table' and type(mine) == 'buffer' then
    local list, bytes = rust :: { number }, mine :: buffer
    if buffer.len(bytes) ~= #list then
      table.insert(problems, `{path}: {buffer.len(bytes)} bytes where jess-nif has {#list}`)
      return
    end

    for i, byte in list do
      if buffer.readu8(bytes, i - 1) ~= byte then
        table.insert(problems, `{path}: byte {i} differs`)
        return
      end
    end

    return
  end

  if type(rust) == 'table' and type(mine) == 'table' then
    local list, rows = rust :: { number }, mine :: { vector }
    if #list == 9 and #rows == 3 and typeof(rows[1]) == 'vector' then
      for row = 1, 3 do
        local values = rows[row]
        for column, value in { values.x, values.y, values.z } do
          if differ(list[(row - 1) * 3 + column], value) then
            table.insert(problems, `{path}: matrix row {row} differs`)
            return
          end
        end
      end

      return
    end

    local keys = {}
    for key in rust :: { [unknown]: unknown } do
      keys[key] = true
    end

    for key in mine :: { [unknown]: unknown } do
      keys[key] = true
    end

    for key in keys do
      compare(
        (rust :: { [unknown]: unknown })[key],
        (mine :: { [unknown]: unknown })[key],
        `{path}.{key}`,
        problems
      )
    end

    return
  end

  if isNull(rust) and isNull(mine) then return end

  -- jess-nif loads an enum value it has no name for as the enum's default (and saves that), where
  -- the port keeps the number the file holds: a jess-nif defect, counted, not a difference.
  if type(rust) == 'string' and type(mine) == 'number' then
    Known.lossyEnums += 1
    return
  end

  if
    type(rust) == 'number'
    and type(mine) == 'number'
    and not differ(rust :: number, mine :: number)
  then
    return
  end

  if rust ~= mine then table.insert(problems, `{path}: {mine} where jess-nif has {rust}`) end
end

--- Whether two of the port's values hold the same: arrays as the same view of the same bytes,
--- tables field by field, NaN equal to NaN.
local function identical(a: unknown, b: unknown): boolean
  if Array.isArray(a) and Array.isArray(b) then
    local left, right = a :: Array.ArrayFields, b :: Array.ArrayFields
    return left.buffer == right.buffer and left.offset == right.offset and left.count == right.count
  end

  if type(a) == 'table' and type(b) == 'table' then
    local left, right = a :: { [unknown]: unknown }, b :: { [unknown]: unknown }
    for key, value in left do
      if not identical(value, right[key]) then return false end
    end

    for key in right do
      if left[key] == nil then return false end
    end

    return true
  end

  return a == b or (a ~= a and b ~= b)
end

--- What differs between the port and jess-nif on one file, as readable lines.
local function check(bytes: buffer): { string }
  local problems = {}
  local rust = jess.nif.openBytes(bytes)
  local mine = port.open(bytes)
  if buffer.tostring(mine:save()) ~= buffer.tostring(bytes) then
    table.insert(problems, 'an untouched save differs from the input')
  end

  local lossyBefore = Known.lossyEnums
  local index = 0
  for record in rust:records() do
    local ours = mine:record(index) :: port.Record
    local fields = {}
    for key, value in ours do
      fields[key] = value
    end

    compare(record:decode(), fields, `#{index} {ours.type}`, problems)
    index += 1
  end

  -- `read` into one reused table per type holds what `record` decoded, arrays as the same views.
  local scratches: { [string]: { [string]: unknown } } = {}
  for i = 0, mine.count - 1 do
    local name = mine:typeOf(i) :: string
    local scratch = scratches[name] or {}
    scratches[name] = scratch
    local read = mine:read(i, scratch) :: { [string]: unknown }
    local decoded = mine:record(i) :: { [string]: unknown }
    if not identical(decoded, read) then
      table.insert(problems, `read #{i} differs from record #{i}`)
    end
  end

  if index ~= mine.count then
    table.insert(problems, `{mine.count} records where jess-nif has {index}`)
  end

  -- Where jess-nif lost an enum value, its save writes the default, and the port's save is held
  -- to the file instead: it writes back every value it read.
  if Known.lossyEnums > lossyBefore then
    if buffer.tostring(mine:save()) ~= buffer.tostring(bytes) then
      table.insert(problems, 'a save with every record decoded differs from the input')
    end
  elseif buffer.tostring(mine:save()) ~= buffer.tostring(rust:bytes()) then
    table.insert(problems, 'a save with every record decoded differs from jess-nif')
  end

  return problems
end

return table.freeze { check = check, known = Known }
